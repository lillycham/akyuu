-- | Canonical publication manifests. A manifest is authoritative only when
-- CURRENT names its hash and every dependency passes repository validation.
module Akyuu.Sync.Checkpoint
  ( Checkpoint,
    CheckpointId (..),
    checkpointStore,
    checkpointEvents,
    checkpointObjects,
    evictedObjects,
    activeObjects,
    withEvicted,
    pendingEvents,
    pendingObjects,
    checkpointId,
    mkCheckpoint,
    renderCheckpoint,
    parseCheckpoint,
    CheckpointError (..),
    maxCheckpointBytes,
  )
where

import Akyuu.Id (Id)
import Akyuu.Id qualified as Id
import Akyuu.Sync.Types (EventId (EventId), StoreId (StoreId), parseIdentifier, renderIdentifier)
import Control.Monad (foldM, unless, when)
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (decodeUtf8', encodeUtf8)

newtype CheckpointId = CheckpointId Id deriving (Eq, Ord, Show)

-- | A validated manifest. The fields are positional and the getters below are
-- plain functions, so no record update can change one. The last two fields
-- are the canonical bytes and their hash. They are lazy and each value
-- computes them at most once: a manifest names the whole inventory, so a
-- second render or hash costs as much as the first.
data Checkpoint = Checkpoint StoreId (Set EventId) (Set Id) (Set Id) (Set EventId) (Set Id) ByteString CheckpointId

instance Eq Checkpoint where
  a == b = fields a == fields b

instance Show Checkpoint where
  showsPrec depth checkpoint = showParen (depth > 10) (showString "Checkpoint " . showsPrec 11 (fields checkpoint))

fields :: Checkpoint -> (StoreId, Set EventId, Set Id, Set Id, Set EventId, Set Id)
fields (Checkpoint store es objects evicted waitingEvents waitingObjects _ _) = (store, es, objects, evicted, waitingEvents, waitingObjects)

checkpointStore :: Checkpoint -> StoreId
checkpointStore (Checkpoint store _ _ _ _ _ _ _) = store

checkpointEvents :: Checkpoint -> Set EventId
checkpointEvents (Checkpoint _ es _ _ _ _ _ _) = es

checkpointObjects :: Checkpoint -> Set Id
checkpointObjects (Checkpoint _ _ objects _ _ _ _ _) = objects

evictedObjects :: Checkpoint -> Set Id
evictedObjects (Checkpoint _ _ _ evicted _ _ _ _) = evicted

pendingEvents :: Checkpoint -> Set EventId
pendingEvents (Checkpoint _ _ _ _ waitingEvents _ _ _) = waitingEvents

pendingObjects :: Checkpoint -> Set Id
pendingObjects (Checkpoint _ _ _ _ _ waitingObjects _ _) = waitingObjects

data CheckpointError
  = BadCheckpoint Text
  | NonCanonicalCheckpoint
  | CheckpointTooLarge
  | UnknownPendingEvent
  | UnknownPendingObject
  | UnknownEvictedObject
  | PendingObjectEvicted
  deriving (Eq, Show)

maxCheckpointBytes :: Int
maxCheckpointBytes = 64 * 1024 * 1024

mkCheckpoint :: StoreId -> Set EventId -> Set Id -> Set EventId -> Set Id -> Either CheckpointError Checkpoint
mkCheckpoint store es objects = build store es objects Set.empty

-- The single constructor of a checkpoint. It checks every relation between
-- the sets and the size limit.
build :: StoreId -> Set EventId -> Set Id -> Set Id -> Set EventId -> Set Id -> Either CheckpointError Checkpoint
build store es objects evicted waitingEvents waitingObjects = do
  unless (waitingEvents `Set.isSubsetOf` es) (Left UnknownPendingEvent)
  unless (waitingObjects `Set.isSubsetOf` objects) (Left UnknownPendingObject)
  unless (evicted `Set.isSubsetOf` objects) (Left UnknownEvictedObject)
  unless (Set.null (evicted `Set.intersection` waitingObjects)) (Left PendingObjectEvicted)
  let bytes = render store es objects evicted waitingEvents waitingObjects
      checkpoint = Checkpoint store es objects evicted waitingEvents waitingObjects bytes (CheckpointId (Id.hashBytes bytes))
  when (BS.length bytes > maxCheckpointBytes) (Left CheckpointTooLarge)
  pure checkpoint

activeObjects :: Checkpoint -> Set Id
activeObjects checkpoint = checkpointObjects checkpoint `Set.difference` evictedObjects checkpoint

-- | Eviction changes local residency, never accepted history or export duties.
withEvicted :: Set Id -> Checkpoint -> Either CheckpointError Checkpoint
withEvicted gone checkpoint@(Checkpoint store es objects evicted waitingEvents waitingObjects _ _)
  | gone == evicted = Right checkpoint
  | otherwise = build store es objects gone waitingEvents waitingObjects

checkpointId :: Checkpoint -> CheckpointId
checkpointId (Checkpoint _ _ _ _ _ _ _ key) = key

renderCheckpoint :: Checkpoint -> ByteString
renderCheckpoint (Checkpoint _ _ _ _ _ _ bytes _) = bytes

render :: StoreId -> Set EventId -> Set Id -> Set Id -> Set EventId -> Set Id -> ByteString
render (StoreId store) es objects evicted waitingEvents waitingObjects = encodeUtf8 (T.unlines entries)
  where
    entries =
      ["akyuu-sync-checkpoint-v1", "store: " <> renderIdentifier store]
        <> ["event: " <> Id.render digest | EventId digest <- Set.toAscList es]
        <> ["object: " <> Id.render digest | digest <- Set.toAscList objects]
        <> ["evicted-object: " <> Id.render digest | digest <- Set.toAscList evicted]
        <> ["pending-event: " <> Id.render digest | EventId digest <- Set.toAscList waitingEvents]
        <> ["pending-object: " <> Id.render digest | digest <- Set.toAscList waitingObjects]

-- The parsed sets, in the order of the manifest fields.
data Parsed = Parsed (Set EventId) (Set Id) (Set Id) (Set EventId) (Set Id)

parseCheckpoint :: ByteString -> Either CheckpointError Checkpoint
parseCheckpoint bytes = do
  when (BS.length bytes > maxCheckpointBytes) (Left CheckpointTooLarge)
  text <- first (const (BadCheckpoint "Checkpoint is not UTF-8.")) (decodeUtf8' bytes)
  checkpoint <- case T.lines text of
    "akyuu-sync-checkpoint-v1" : storeLine : entries -> do
      storeText <- maybe (Left (BadCheckpoint "Missing store identity.")) Right (T.stripPrefix "store: " storeLine)
      store <- StoreId <$> first BadCheckpoint (parseIdentifier storeText)
      Parsed es objects evicted waitingEvents waitingObjects <- foldM entry (Parsed Set.empty Set.empty Set.empty Set.empty Set.empty) entries
      build store es objects evicted waitingEvents waitingObjects
    _ -> Left (BadCheckpoint "Unknown or incomplete checkpoint header.")
  unless (renderCheckpoint checkpoint == bytes) (Left NonCanonicalCheckpoint)
  pure checkpoint
  where
    entry (Parsed es objects evicted waitingEvents waitingObjects) line = do
      let (key, suffix) = T.breakOn ": " line
      digest <- first (BadCheckpoint . T.pack . show) (Id.parse (T.drop 2 suffix))
      case key of
        "event" -> Right (Parsed (Set.insert (EventId digest) es) objects evicted waitingEvents waitingObjects)
        "object" -> Right (Parsed es (Set.insert digest objects) evicted waitingEvents waitingObjects)
        "evicted-object" -> Right (Parsed es objects (Set.insert digest evicted) waitingEvents waitingObjects)
        "pending-event" -> Right (Parsed es objects evicted (Set.insert (EventId digest) waitingEvents) waitingObjects)
        "pending-object" -> Right (Parsed es objects evicted waitingEvents (Set.insert digest waitingObjects))
        _ -> Left (BadCheckpoint "Unknown checkpoint field.")
