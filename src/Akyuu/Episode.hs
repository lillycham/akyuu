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
-- To forget, replace the whole log with a summary: 'Akyuu.Supersede.supersede'
-- the ref with a memory that holds the summary. The summary has a @supersedes@
-- edge to the newest episode, so the chain is not kept by it, and GC collects
-- the chain once the ref generations that name it are past.
module Akyuu.Episode
  ( append,
    previous,
    Walk (..),
    walk,
  )
where

import Akyuu.Graph (Edge (Edge, kind, target), EdgeType (DerivedFrom, Follows))
import Akyuu.Id (Id)
import Akyuu.Memory (Memory (memEdges))
import Akyuu.Refs (Expected (MustBe, MustBeAbsent), Name, Ref (current), RefError (NoSuchRef, Stale), Refs, getRef, setRef)
import Akyuu.Store (Store, StoreError (BadMemory, NotFound))
import Akyuu.Store qualified as Store
import Akyuu.Supersede (SupersedeError (SupersedeRef, SupersedeStore))
import Data.Set qualified as Set

-- | Add an episode to the log that a ref names, and move the ref to it.
--
-- If the ref does not exist, the log starts with this episode. Otherwise the
-- episode gets a @follows@ edge to the current newest episode. The ref
-- moves with a compare-and-set. If another agent appended at the same time,
-- the function reads the ref again and builds the episode again, up to 20
-- times, because two appends do not conflict: both belong in the log.
--
-- The memory must not have a @follows@ edge of its own: that edge is the link
-- in the chain, and the function adds it. 'Akyuu.Ops.appendEpisode' checks this.
append :: Store -> Refs -> Name -> Memory -> IO (Either SupersedeError Id)
append st rs n m = go (20 :: Int)
  where
    go k = do
      cur <- getRef rs n
      case cur of
        Left (NoSuchRef _) -> attempt k MustBeAbsent m
        Left e -> pure (Left (SupersedeRef e))
        Right ref ->
          attempt k (MustBe (current ref)) m {memEdges = Set.insert (Edge Follows (current ref)) (memEdges m)}
    attempt k expected episode = do
      added <- Store.add st episode
      case added of
        Left e -> pure (Left (SupersedeStore e))
        Right new -> do
          moved <- setRef rs n expected new
          case moved of
            Right _ -> pure (Right new)
            Left (Stale _ _) | k > 0 -> go (k - 1)
            Left e -> pure (Left (SupersedeRef e))

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
    -- | The next episode, if the walk stopped at its limit before the end of
    -- the chain. 'Nothing' at the end, and when the next episode was deleted by
    -- GC or cannot be read.
    walkMore :: Maybe Id
  }
  deriving (Eq, Show)

-- | Read a log: from the newest episode, go to the one before it ('previous'),
-- up to a limit.
--
-- A memory that GC deleted, or that is not readable, ends the walk.
walk :: Store -> Int -> Id -> IO Walk
walk st limit = go [] limit
  where
    go acc k i
      | k <= 0 = pure (Walk (reverse acc) (Just i))
      | otherwise = do
          r <- Store.getVerified st i
          case r of
            Left (NotFound _) -> pure (Walk (reverse acc) Nothing)
            Left (BadMemory _ _) -> pure (Walk (reverse acc) Nothing)
            Left _ -> pure (Walk (reverse acc) Nothing)
            Right m -> case previous (Set.toAscList (memEdges m)) of
              Nothing -> pure (Walk (reverse ((i, m) : acc)) Nothing)
              Just next -> go ((i, m) : acc) (k - 1) next
