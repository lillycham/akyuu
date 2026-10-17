-- | Levels of summaries on top of a log.
--
-- The archive keeps everything: a summary is written beside the episodes, and
-- never in place of them. Only what a reader is shown changes.
--
-- A log @me/log@ is level 0. Level 1 is the log @me/log.l1@: each of its
-- memories is a summary, with a @derived_from@ edge to each episode that it
-- covers, and a @follows@ edge to the summary before it. Level 2 is
-- @me/log.l2@, and its summaries cover level-1 summaries, and so on. The
-- chain of a level keeps every summary alive, and a summary keeps its sources.
--
-- Summaries are written in order: a new summary covers the oldest memories of
-- the level below that no summary covers yet ('checkSources'). So the covered
-- part of a level is always its oldest part, and a reader needs no index.
--
-- akyuu runs no model. 'todo' says what needs a summary, an agent writes it,
-- and 'Akyuu.Ops.summarise' records it.
--
-- Everything here is pure: the caller reads the chains ('Akyuu.Ops.readLevels').
module Akyuu.Levels
  ( -- * Names
    levelRef,

    -- * Chains
    Chain,
    sources,
    uncovered,
    chainOrder,

    -- * What needs a summary
    Run (..),
    todo,
    checkSources,

    -- * Views of a log
    LogView (..),
    defaultSize,
    defaultKeep,

    -- * Reading at a resolution
    Item (..),
    resolution,
    fit,
  )
where

import Akyuu.Episode (previous)
import Akyuu.Graph (Edge (kind, target), EdgeType (DerivedFrom))
import Akyuu.Id (Id)
import Akyuu.Id qualified as Id
import Akyuu.Memory (Memory (memCreated, memEdges))
import Akyuu.Refs (Name, NameError, mkName, nameText)
import Data.List (sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Ord (Down (Down))
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime)

-- Names ----------------------------------------------------------------

-- | The ref of a level of a log: @me/log@ and 2 give @me/log.l2@. Level 0 is
-- the log itself. The level is a suffix of the last part, because a part of a
-- name is a directory, and @me/log@ is a file.
levelRef :: Name -> Int -> Either NameError Name
levelRef n 0 = Right n
levelRef n k = mkName (nameText n <> ".l" <> T.pack (show k))

-- Chains ---------------------------------------------------------------

-- | The memories of one level, oldest first.
type Chain = [(Id, Memory)]

-- | The memories that a summary covers: the targets of its @derived_from@
-- edges, in ascending order.
sources :: Memory -> [Id]
sources m = [target e | e <- Set.toAscList (memEdges m), kind e == DerivedFrom]

-- | The memories of a level that no summary of the level above covers, oldest
-- first. The first argument is the level above.
uncovered :: Chain -> Chain -> Chain
uncovered above below = filter ((`Set.notMember` covered) . fst) below
  where
    covered = Set.fromList (concatMap (sources . snd) above)

-- | Memories of one chain, newest first: the newest is the one that no other
-- of them follows ('Akyuu.Episode.previous'), then the one before it, and so
-- on. Memories that this does not reach come last, newest first by time.
chainOrder :: Chain -> Chain
chainOrder ms = walked <> rest
  where
    byId = Map.fromList ms
    prevOf (_, m) = previous (Set.toAscList (memEdges m))
    pointedAt = Set.fromList [p | x <- ms, Just p <- [prevOf x]]
    heads = [x | x@(i, _) <- ms, i `Set.notMember` pointedAt]
    walked = case heads of
      [h] -> go Set.empty h
      _ -> []
    go seen x@(i, _)
      | i `Set.member` seen = []
      | otherwise = x : maybe [] (go (Set.insert i seen)) (prevOf x >>= \p -> (,) p <$> Map.lookup p byId)
    done = Set.fromList (map fst walked)
    rest = sortOn (\(i, m) -> (Down (memCreated m), Down i)) [x | x@(i, _) <- ms, i `Set.notMember` done]

-- What needs a summary ---------------------------------------------------

-- | A stretch to summarise: the level that the summary goes to, and the
-- memories of the level below that it covers, oldest first.
data Run = Run
  { runLevel :: Int,
    runMemories :: Chain,
    runFrom :: UTCTime,
    runTo :: UTCTime
  }
  deriving (Eq, Show)

-- | The stretches that need a summary, lowest level first. The chains are the
-- levels of one log, from level 0. A run has exactly @size@ memories, the
-- oldest that are not covered. The newest @keep@ episodes of level 0 get no
-- summary: a reader sees them as they are. One more level is offered when
-- the top level has @size@ summaries.
todo :: Int -> Int -> [Chain] -> [Run]
todo size keep chains =
  concat
    [ map (run k) (chunks (candidates k below above))
    | (k, below, above) <- zip3 [1 ..] chains (drop 1 chains <> [[]])
    ]
  where
    candidates k below above =
      let open = uncovered above below
       in if k == 1 then take (length open - keep) open else open
    chunks xs
      | length xs >= size = take size xs : chunks (drop size xs)
      | otherwise = []
    -- The span is the time of the episodes under the run, also for a run of
    -- summaries, which were written later.
    run k xs =
      let times = map memCreated (concatMap (episodesUnder chains . fst) xs)
       in Run
            { runLevel = k,
              runMemories = xs,
              runFrom = minimum times,
              runTo = maximum times
            }

-- | Check the sources of a new summary at level @k@: they must be the oldest
-- memories of level @k - 1@ that no summary covers, in any order, and at least
-- two. The chains are the levels of one log, from level 0. 'Left' is a
-- sentence for the person or the agent.
checkSources :: Int -> [Id] -> [Chain] -> Either Text ()
checkSources k ids chains
  | k < 1 = Left "The level of a summary is 1 or more. Level 0 is the log."
  | k > length chains = Left ("There is no level " <> T.pack (show (k - 1)) <> " to summarise yet. Summarise level " <> T.pack (show (length chains)) <> " first.")
  | Set.size given < 2 = Left "A summary covers two memories or more."
  | Set.size given /= length ids = Left "A source is given twice."
  | given == Set.fromList (map fst next) = Right ()
  | otherwise = case open of
      [] -> Left ("Every memory of level " <> T.pack (show (k - 1)) <> " has a summary.")
      ((first, _) : _) ->
        Left
          ( "The sources must be the "
              <> T.pack (show (Set.size given))
              <> " oldest memories of level "
              <> T.pack (show (k - 1))
              <> " that no summary covers. They start at "
              <> Id.render first
              <> ". See log --todo."
          )
  where
    given = Set.fromList ids
    below = chains !! (k - 1)
    above = if k < length chains then chains !! k else []
    open = uncovered above below
    next = take (Set.size given) open

-- Views of a log ---------------------------------------------------------

-- | How to show a log: its episodes as they are, what needs a summary, or the
-- log at a resolution.
data LogView
  = Plain
  | -- | 'todo' with the size of a run and the number of recent episodes to
    -- leave out.
    Todo Int Int
  | -- | 'resolution' with the number of recent episodes to show whole, and a
    -- budget of characters ('fit').
    Resolution Int (Maybe Int)
  deriving (Eq, Show)

-- | A summary covers 8 memories of the level below.
defaultSize :: Int
defaultSize = 8

-- | The 10 newest episodes are shown whole, and get no summary yet.
defaultKeep :: Int
defaultKeep = 10

-- Reading at a resolution ------------------------------------------------

-- | One part of a log at a resolution.
data Item
  = -- | An episode, shown whole.
    Episode Id Memory
  | -- | An older episode that no summary covers, shown as its first line, when
    -- the whole text does not fit a budget ('fit').
    Brief Id Memory
  | -- | A summary at a level, the number of episodes that it stands for, and
    -- the time of the first and the last of them.
    Summary Int Id Memory Int UTCTime UTCTime
  deriving (Eq, Show)

-- | A log at a resolution, newest first: the newest @keep@ episodes whole,
-- then each older stretch as the highest summary that covers it. An older
-- episode that no summary covers is whole with 'True', and one line with
-- 'False'. So nothing is left out, and only a summary makes the text shorter.
-- The chains are the levels of one log, from level 0.
resolution :: Bool -> Int -> [Chain] -> [Item]
resolution _ _ [] = []
resolution whole keep chains@(episodes : _) =
  [Episode i m | (i, m) <- reverse recent] <> reverse (map item (dedupe (map older old)))
  where
    (old, recent) = splitAt (length episodes - max 0 keep) episodes
    -- For each memory, the summary of the level above that covers it.
    coverOf :: Map Id (Int, Id)
    coverOf =
      Map.fromList
        [ (s, (k, i))
        | (k, chain) <- zip [1 ..] (drop 1 chains),
          (i, m) <- chain,
          s <- sources m
        ]
    memories :: Map Id Memory
    memories = Map.fromList (concat chains)
    top i = case Map.lookup i coverOf of
      Just (k, s) -> Just (fromMaybe (k, s) (top s))
      Nothing -> Nothing
    older (i, m) = case top i of
      Nothing -> Left (i, m)
      Just (k, s) -> Right (k, s)
    dedupe (Right a : rest@(Right b : _)) | a == b = dedupe rest
    dedupe (x : rest) = x : dedupe rest
    dedupe [] = []
    item (Left (i, m)) = if whole then Episode i m else Brief i m
    item (Right (k, s)) =
      let m = memories Map.! s
          eps = episodesUnder chains s
          times = map memCreated eps
       in Summary k s m (length eps) (minimum times) (maximum times)

-- | The episodes (level 0) that a memory of one of the levels stands for: an
-- episode itself, or the episodes under the sources of a summary. The chains
-- are the levels of one log, from level 0.
episodesUnder :: [Chain] -> Id -> [Memory]
episodesUnder [] = const []
episodesUnder chains@(episodes : _) = go
  where
    memories = Map.fromList (concat chains)
    episodeIds = Set.fromList (map fst episodes)
    go s = case Map.lookup s memories of
      Nothing -> []
      Just m
        | s `Set.member` episodeIds -> [m]
        | otherwise -> concatMap go (sources m)

-- | The resolution that fits a budget of characters, with a function that
-- renders it. First every episode is whole. If that is too long, an older
-- episode with no summary is one line, and then fewer recent episodes are
-- whole, from @keep@ down to none. If even that is too long, 'Left' gives the
-- length it needs: the caller says so, and drops nothing in silence.
fit :: ([Item] -> Text) -> Int -> Int -> [Chain] -> Either Int Text
fit render budget keep chains
  | T.length full <= budget = Right full
  | otherwise = go keep
  where
    full = render (resolution True keep chains)
    go k
      | T.length t <= budget = Right t
      | k <= 0 = Left (T.length t)
      | otherwise = go (k - 1)
      where
        t = render (resolution False k chains)
