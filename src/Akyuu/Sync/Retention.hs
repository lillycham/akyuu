-- | Roots from accepted causal state. Local eviction never removes an event,
-- archive payload or review record. Generations follow every causal branch.
module Akyuu.Sync.Retention (retained, actionPayloads) where

import Akyuu.GC (retains)
import Akyuu.Graph (Edge (kind, target))
import Akyuu.Id (Id)
import Akyuu.Memory (Memory (memEdges))
import Akyuu.Sync.Checkpoint (Checkpoint, pendingEvents, pendingObjects)
import Akyuu.Sync.Event (eventAction, eventParents)
import Akyuu.Sync.State (ResourceState (PinState), State, events, interpret, resourceHeads)
import Akyuu.Sync.Types (Action (AppendLog, ResolveLog, ResolveTopic, SetPin, SetReview, SetTopic), EventId, Resource (PinResource, RefResource), resourceOf)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set

actionPayloads :: Action -> [Id]
actionPayloads action = case action of
  SetTopic _ digest -> [digest]
  ResolveTopic _ digest -> [digest]
  AppendLog _ digest -> [digest]
  ResolveLog _ digest -> [digest]
  SetPin digest -> [digest]
  SetReview a b _ -> [a, b]
  _ -> []

-- | Depth includes the current generation. Pending event payloads also root
-- intermediate versions, even if no current ref names them. The caller has
-- already validated payload closure; no absent retaining target is ignored.
retained :: Int -> Checkpoint -> State -> Map Id Memory -> Set Id
retained depth checkpoint state memories = closure roots Set.empty
  where
    table = events state
    resources = Set.fromList (map (resourceOf . eventAction) (Map.elems table))
    refs = [resource | resource@(RefResource _) <- Set.toList resources]
    current = Set.unions [Map.keysSet (resourceHeads state resource) | resource <- refs]
    generations = ancestry (max 1 depth) current
    pinRoots = Set.fromList [digest | resource@(PinResource digest) <- Set.toList resources, interpret state resource == PinState True]
    eventRoots ids = Set.fromList [digest | key <- Set.toList ids, Just event <- [Map.lookup key table], digest <- actionPayloads (eventAction event)]
    roots = pinRoots <> pendingObjects checkpoint <> eventRoots (pendingEvents checkpoint <> generations)
    ancestry :: Int -> Set EventId -> Set EventId
    ancestry k frontier
      | k <= 0 = Set.empty
      | otherwise = frontier <> ancestry (k - 1) (Set.unions [eventParents event | key <- Set.toList frontier, Just event <- [Map.lookup key table]])
    closure pending seen = case Set.minView pending of
      Nothing -> seen
      Just (i, rest)
        | i `Set.member` seen -> closure rest seen
        | otherwise ->
            let children = maybe Set.empty (Set.fromList . map target . filter (retains . kind) . Set.toList . memEdges) (Map.lookup i memories)
             in closure (rest <> children) (Set.insert i seen)
