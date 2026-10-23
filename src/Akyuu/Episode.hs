-- | Episodes: a log that agents append to, as a chain of memories.
--
-- An episode is a small memory of something that happened or was said. A log
-- is a ref that names the newest episode. Each episode has a @follows@ edge
-- to the one before it, so the ref keeps the whole chain alive: GC follows the
-- edges from the ref, and every episode is reachable.
--
-- Logs written before the @follows@ edge link an episode to the one before it
-- with its one @derived_from@ edge. 'previous' reads both, so an old log goes
-- on where a new episode follows it. An episode is never rewritten.
--
-- This is different from 'Akyuu.Supersede.supersede'. A @supersedes@ edge
-- does not keep the old memory alive, so a superseded memory is garbage.
-- Episodes are not replaced, they pile up, so the link keeps its target alive.
--
-- To read an old stretch cheaply, write a summary beside it ("Akyuu.Levels"):
-- the episodes stay. To forget, replace the whole log with a summary:
-- 'Akyuu.Supersede.supersede' the ref with a memory that holds the summary. The summary has a @supersedes@
-- edge to the newest episode, so the chain is not kept by it, and GC collects
-- the chain once the ref generations that name it are past.
module Akyuu.Episode
  ( append,
    appendWith,
    previous,
    Walk (..),
    WalkEnd (..),
    walk,
  )
where

import Akyuu.Graph (Edge (Edge, kind, target), EdgeType (DerivedFrom, Follows))
import Akyuu.Id (Id)
import Akyuu.Memory (Memory (memEdges))
import Akyuu.Mutation (Mutation, checkMutation, withMutation)
import Akyuu.Refs (Expected (MustBe, MustBeAbsent), Name, Ref (current), RefError (Locked, NoSuchRef, RefIO), Refs, getRef, updateRef)
import Akyuu.Store (Store, StoreError, storeRoot)
import Akyuu.Store qualified as Store
import Akyuu.Supersede (SupersedeError (SupersedeRef, SupersedeStore))
import Data.Bifunctor (first)
import Data.Set qualified as Set

-- | Add an episode to the log that a ref names, and move the ref to it.
--
-- If the ref does not exist, the log starts with this episode. Otherwise the
-- episode gets a @follows@ edge to the current newest episode. The ref
-- moves while holding the shared store mutation lock. Concurrent appends
-- read the head in turn, so every successful append belongs to the chain
-- and no unsuccessful attempt publishes a spare episode.
--
-- The memory must not have a @follows@ edge of its own: that edge is the link
-- in the chain, and the function adds it. 'Akyuu.Ops.appendEpisode' checks this.
append :: Store -> Refs -> Name -> Memory -> IO (Either SupersedeError Id)
append st rs n m =
  withMutation (storeRoot st) (SupersedeRef Locked) (SupersedeRef . RefIO) $ \held ->
    appendWith held st rs n m

-- | Append inside an existing mutation operation.
appendWith :: Mutation -> Store -> Refs -> Name -> Memory -> IO (Either SupersedeError Id)
appendWith held st rs n m = do
  checkMutation held (storeRoot st)
  cur <- getRef rs n
  case cur of
    Left (NoSuchRef _) -> publish MustBeAbsent m
    Left e -> pure (Left (SupersedeRef e))
    Right ref ->
      publish (MustBe (current ref)) m {memEdges = Set.insert (Edge Follows (current ref)) (memEdges m)}
  where
    publish expected episode =
      fmap current <$> updateRef held rs n expected SupersedeRef (fmap (first SupersedeStore) (Store.addWith held st episode))

-- | The episode before this one in its log, from its edges. This function is
-- pure.
--
-- A @follows@ edge comes first: a log that 'append' wrote has one. With no
-- @follows@ edge, a memory with exactly one @derived_from@ edge is an
-- episode of an older log, and that edge is the link. A memory with neither
-- is the first episode. The lowest 'Id' wins if there is more than one
-- @follows@ edge.
previous :: [Edge] -> Maybe Id
previous es = case [target e | e <- es, kind e == Follows] of
  (p : _) -> Just p
  [] -> case [target e | e <- es, kind e == DerivedFrom] of
    [p] -> Just p
    _ -> Nothing

-- | The episodes of a log, newest first.
data Walk = Walk
  { -- | The episodes that were read, with their ids.
    walkEntries :: [(Id, Memory)],
    -- | Whether the chain ended, reached the limit, or could not be read.
    walkEnd :: WalkEnd
  }
  deriving (Eq, Show)

-- | Why traversal stopped. An interruption retains the failed id and cause;
-- 'walkEntries' still holds every readable episode before it.
data WalkEnd
  = Complete
  | Limited Id
  | Interrupted Id StoreError
  deriving (Eq, Show)

-- | Read a log: from the newest episode, go to the one before it ('previous'),
-- up to a limit.
--
-- An unreadable memory interrupts the walk without discarding its prefix.
walk :: Store -> Int -> Id -> IO Walk
walk st limit = go [] limit
  where
    go acc k i
      | k <= 0 = pure (Walk (reverse acc) (Limited i))
      | otherwise = do
          r <- Store.getVerified st i
          case r of
            Left e -> pure (Walk (reverse acc) (Interrupted i e))
            Right m -> case previous (Set.toAscList (memEdges m)) of
              Nothing -> pure (Walk (reverse ((i, m) : acc)) Complete)
              Just next -> go ((i, m) : acc) (k - 1) next
