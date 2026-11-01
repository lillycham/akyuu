-- | Pure, validated causal state. This module never reads or changes a live store.
module Akyuu.Sync.State
  ( State,
    StateError (..),
    RefKind (..),
    ResourceState (..),
    Version,
    versionText,
    parseVersion,
    empty,
    fromEvents,
    fromBytes,
    events,
    storeId,
    merge,
    resourceHeads,
    interpret,
    version,
    applyLocal,
  )
where

import Akyuu.Id (Id, IdParseError)
import Akyuu.Id qualified as Id
import Akyuu.Refs (nameText)
import Akyuu.Sync.Event (Event, EventError, eventAction, eventId, eventNonce, eventParents, eventReplica, eventStore, eventTime, mkEvent, parseEvent, renderEvent)
import Akyuu.Sync.Types (Action (AppendLog, RegisterReplica, ResolveLog, ResolveTopic, SetPin, SetReview, SetTopic), EventId (EventId), ReplicaId, Resource (PinResource, RefResource, RegistryResource, ReviewResource), ReviewValue, StoreId (StoreId), renderIdentifier, resourceOf)
import Control.Monad (foldM, unless, when)
import Data.Aeson (encode)
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as BL
import Data.Foldable (traverse_)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)

data State = State StoreId (Map EventId Event) deriving (Eq, Show)

data StateError
  = InvalidEvent EventError
  | WrongEventId EventId EventId
  | DifferentEventBytes EventId
  | WrongStore EventId
  | IncompatibleStores
  | MissingParent EventId EventId
  | ParentResourceMismatch EventId EventId
  | UnknownReplica EventId ReplicaId
  | InvalidRegistration EventId
  | InvalidRefTransition EventId
  | EventCycle
  | StaleVersion
  | StaleDependency Resource
  | WrongParents
  | NeedsResolution
  deriving (Eq, Show)

data RefKind = TopicKind | LogKind deriving (Eq, Ord, Show)

data ResourceState
  = Absent
  | TopicHeads (Map EventId Id)
  | LogHeads (Map EventId Id)
  | RefTypeConflict (Map EventId (RefKind, Id))
  | PinState Bool
  | ReviewState (Map EventId ReviewValue)
  | Registered (Map ReplicaId (Set Text))
  deriving (Eq, Show)

-- | Includes store, resource, and the complete causal head set.
newtype Version = Version Id deriving (Eq, Ord, Show)

versionText :: Version -> Text
versionText (Version digest) = Id.render digest

parseVersion :: Text -> Either IdParseError Version
parseVersion = fmap Version . Id.parse

empty :: StoreId -> State
empty store = State store Map.empty

events :: State -> Map EventId Event
events (State _ es) = es

storeId :: State -> StoreId
storeId (State store _) = store

fromEvents :: StoreId -> [Event] -> Either StateError State
fromEvents store es = do
  pairs <- traverse canonical es
  table <- foldM insert Map.empty pairs
  validate store table
  pure (State store table)
  where
    canonical event = do
      checked <- first InvalidEvent (mkEvent (eventStore event) (eventReplica event) (eventNonce event) (eventParents event) (eventAction event) (eventTime event))
      pure (eventId checked, checked)
    insert table (key, event) = case Map.lookup key table of
      Just old | renderEvent old /= renderEvent event -> Left (DifferentEventBytes key)
      _ -> Right (Map.insert key event table)

-- | Imports check each claimed ID before any event can enter validated state.
fromBytes :: StoreId -> [(EventId, ByteString)] -> Either StateError State
fromBytes store entries = traverse decode entries >>= fromEvents store
  where
    decode (expected, bytes) = do
      event <- first InvalidEvent (parseEvent bytes)
      let actual = eventId event
      unless (expected == actual) (Left (WrongEventId expected actual))
      pure event

merge :: State -> State -> Either StateError State
merge (State a left) (State b right)
  | a /= b = Left IncompatibleStores
  | otherwise = fromEvents a (Map.elems left <> Map.elems right)

validate :: StoreId -> Map EventId Event -> Either StateError ()
validate store table = do
  traverse_ check (Map.toAscList table)
  checkAcyclic table
  where
    registered = Set.fromList [replica | event <- Map.elems table, RegisterReplica replica _ <- [eventAction event]]
    check (key, event) = do
      unless (eventStore event == store) (Left (WrongStore key))
      case eventAction event of
        RegisterReplica replica _ -> unless (replica == eventReplica event) (Left (InvalidRegistration key))
        _ -> unless (eventReplica event `Set.member` registered) (Left (UnknownReplica key (eventReplica event)))
      parents <- traverse (parent key event) (Set.toAscList (eventParents event))
      let allKind kind = all ((== Just kind) . refKind . eventAction) parents
          invalid = Left (InvalidRefTransition key)
      case eventAction event of
        SetTopic _ _ -> unless (length parents <= 1 && allKind TopicKind) invalid
        AppendLog _ _ -> unless (allKind LogKind) invalid
        ResolveTopic _ _ -> when (null parents) invalid
        ResolveLog _ _ -> when (null parents) invalid
        _ -> Right ()
    parent key event parentId = do
      previous <- maybe (Left (MissingParent key parentId)) Right (Map.lookup parentId table)
      unless (resourceOf (eventAction event) == resourceOf (eventAction previous)) (Left (ParentResourceMismatch key parentId))
      pure previous

-- Kahn's algorithm avoids a recursive walk for each event in a long history.
checkAcyclic :: Map EventId Event -> Either StateError ()
checkAcyclic table = go 0 roots counts
  where
    counts = Map.map (Set.size . eventParents) table
    roots = Map.keysSet (Map.filter (== 0) counts)
    children = Map.fromListWith Set.union [(parent, Set.singleton key) | (key, event) <- Map.toAscList table, parent <- Set.toAscList (eventParents event)]
    go seen ready remaining = case Set.minView ready of
      Nothing -> unless (seen == Map.size table) (Left EventCycle)
      Just (key, rest) ->
        let (next, reduced) = Set.foldl' decrement (rest, remaining) (Map.findWithDefault Set.empty key children)
         in go (seen + 1) next reduced
    decrement (ready, remaining) key =
      let count = Map.findWithDefault 0 key remaining - 1
       in (if count == 0 then Set.insert key ready else ready, Map.insert key count remaining)

refKind :: Action -> Maybe RefKind
refKind action = case action of
  SetTopic _ _ -> Just TopicKind
  ResolveTopic _ _ -> Just TopicKind
  AppendLog _ _ -> Just LogKind
  ResolveLog _ _ -> Just LogKind
  _ -> Nothing

normaliseResource :: Resource -> Resource
normaliseResource (ReviewResource a b) = ReviewResource (min a b) (max a b)
normaliseResource resource = resource

resourceHeads :: State -> Resource -> Map EventId Event
resourceHeads (State _ table) resource = Map.withoutKeys relevant consumed
  where
    relevant = Map.filter ((== normaliseResource resource) . resourceOf . eventAction) table
    consumed = Set.unions (map eventParents (Map.elems relevant))

interpret :: State -> Resource -> ResourceState
interpret state resource
  | Map.null heads = Absent
  | otherwise = case resource of
      RefResource _ ->
        let refs = Map.mapMaybe (refValue . eventAction) heads
         in if all ((== TopicKind) . fst) refs
              then TopicHeads (Map.map snd refs)
              else
                if all ((== LogKind) . fst) refs
                  then LogHeads (Map.map snd refs)
                  else RefTypeConflict refs
      PinResource _ -> PinState (any isSetPin (Map.elems heads))
      ReviewResource _ _ -> ReviewState (Map.mapMaybe (reviewValue . eventAction) heads)
      RegistryResource -> Registered (Map.fromListWith Set.union [(replica, Set.singleton label) | event <- Map.elems (events state), RegisterReplica replica label <- [eventAction event]])
  where
    heads = resourceHeads state resource
    refValue action = case action of
      SetTopic _ memory -> Just (TopicKind, memory)
      ResolveTopic _ memory -> Just (TopicKind, memory)
      AppendLog _ memory -> Just (LogKind, memory)
      ResolveLog _ memory -> Just (LogKind, memory)
      _ -> Nothing
    isSetPin event = case eventAction event of SetPin _ -> True; _ -> False
    reviewValue action = case action of SetReview _ _ value -> Just value; _ -> Nothing

version :: State -> Resource -> Version
version state@(State (StoreId store) _) resource = Version (Id.hashBytes bytes)
  where
    bytes = "akyuu-sync-version-v1\n" <> BL.toStrict (encode fields)
    fields = [renderIdentifier store] <> resourceFields (normaliseResource resource) <> [Id.render digest | EventId digest <- Map.keys (resourceHeads state resource)]
    resourceFields target = case target of
      RefResource name -> ["ref", nameText name]
      PinResource memory -> ["pin", Id.render memory]
      ReviewResource a b -> ["review", Id.render a, Id.render b]
      RegistryResource -> ["registry"]

-- | The future writer calls this under the mutation lock. Remote merge does
-- not require an up-to-date token: unseen concurrent events are legitimate.
applyLocal :: Version -> Event -> State -> Either StateError State
applyLocal expected event state@(State store table) = do
  let resource = resourceOf (eventAction event)
      heads = resourceHeads state resource
  unless (version state resource == expected) (Left StaleVersion)
  unless (eventParents event == Map.keysSet heads) (Left WrongParents)
  case (eventAction event, interpret state resource) of
    (SetTopic _ _, TopicHeads values) | Map.size values > 1 -> Left NeedsResolution
    (SetTopic _ _, RefTypeConflict _) -> Left NeedsResolution
    (AppendLog _ _, RefTypeConflict _) -> Left NeedsResolution
    _ -> Right ()
  fromEvents store (event : Map.elems table)
