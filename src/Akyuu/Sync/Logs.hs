-- | DAG logs and summary coverage in one captured checkpoint. Legacy chain
-- readers remain separate. No timestamp can put an ancestor before a child.
module Akyuu.Sync.Logs
  ( LogRead (..),
    LogLevels (..),
    LogItem (..),
    LogPageOptions (..),
    LogPage (..),
    defaultPageOptions,
    validatePageOptions,
    validatePageRange,
    pageAt,
    pageUnchecked,
    pagesToken,
    pageJSON,
    renderPage,
    levelsAtBounded,
    predecessors,
    orderEntries,
    readLog,
    logAt,
    appendLog,
    readLevels,
    levelsAt,
    summarise,
    unfold,
    resolution,
    todo,
    logJSON,
    levelsJSON,
    itemsJSON,
    entriesJSON,
    renderLog,
  )
where

import Akyuu.Episode qualified as Episode
import Akyuu.Error (describeName)
import Akyuu.Graph (Edge (Edge, kind, target), EdgeType (DerivedFrom, Follows))
import Akyuu.Id (Id)
import Akyuu.Id qualified as Id
import Akyuu.Levels qualified as Levels
import Akyuu.Memory (Memory (memBody, memCreated, memEdges))
import Akyuu.Ops (NewMemory (newEdges))
import Akyuu.Refs (Name, nameText)
import Akyuu.Sync.Checkpoint (CheckpointId (CheckpointId))
import Akyuu.Sync.Repository (RepositoryError, Snapshot, readMemory)
import Akyuu.Sync.State (Version, versionText)
import Akyuu.Sync.Topics (LocalReplica, TopicError (InvalidInput, LogChanged, MissingTopic, NeedsResolution, StorageError), TopicHead (headMemoryId), TopicStatus (LogTopic, Missing), TopicView (viewCheckpoint, viewHeads, viewName, viewStatus, viewVersion), appendLogChecked, captureSnapshot, describeError, topicViewAt, viewJSON)
import Akyuu.Sync.Types (Resource (RefResource))
import Control.Monad (unless, when)
import Control.Monad.Trans.Except (ExceptT (ExceptT), runExceptT, throwE)
import Data.Aeson (Value, object, (.=))
import Data.Bifunctor (first)
import Data.List (sortOn)
import Data.Map.Strict qualified as Map
import Data.Ord (Down (Down))
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (encodeUtf8)

data LogRead = LogRead
  { logTopic :: TopicView,
    logEntries :: [(Id, Memory)],
    logFrontier :: Set Id,
    logFailures :: [(Id, RepositoryError)]
  }
  deriving (Eq, Show)

-- | All levels, newest first within each level. The token also names the
-- absent next level, so its concurrent creation invalidates a summary write.
data LogLevels = LogLevels
  { levelsBase :: Name,
    levelsReads :: [LogRead],
    levelsToken :: Id,
    levelsChecks :: [(Resource, Version)]
  }
  deriving (Eq, Show)

data LogItem = LogItem
  { itemId :: Id,
    itemMemory :: Memory,
    itemLevel :: Int,
    itemSources :: Set Id
  }
  deriving (Eq, Show)

data LogPageOptions = LogPageOptions
  { pageNumber :: Int,
    pageSize :: Int,
    recentWhole :: Int,
    -- | The log version of page one. A later page must give it. It names
    -- the log and its summary levels, not the whole repository, so a write
    -- to another topic does not end a paged read.
    pageToken :: Maybe Id
  }
  deriving (Eq, Show)

defaultPageOptions :: LogPageOptions
defaultPageOptions = LogPageOptions 1 20 10 Nothing

data LogPage = LogPage
  { pageTopic :: TopicView,
    pageVersion :: Id,
    pageItems :: [LogItem],
    pageOptions :: LogPageOptions,
    pageHasMore :: Bool,
    pageTotal :: Int
  }
  deriving (Eq, Show)

validatePageOptions :: LogPageOptions -> Either TopicError ()
validatePageOptions options = do
  validatePageRange options
  when
    (pageNumber options > 1 && pageToken options == Nothing)
    (Left (InvalidInput "Further log pages require the log version from the first response."))

-- | The range checks of 'validatePageOptions', without the version rule.
validatePageRange :: LogPageOptions -> Either TopicError ()
validatePageRange options =
  unless
    (pageNumber options >= 1 && pageNumber options <= 4096 && pageSize options >= 1 && pageSize options <= 100 && recentWhole options >= 0 && recentWhole options <= 4096)
    (Left (InvalidInput "Log page must be from 1 to 4096, log limit from 1 to 100, and log keep from 0 to 4096."))

-- | One page of one log. A later page must give the version of page one
-- ('pageVersion'), and fails with 'LogChanged' only if this log or its
-- summary levels changed.
pageAt :: Snapshot -> Name -> LogPageOptions -> IO (Either TopicError LogPage)
pageAt snapshot name options = runExceptT $ do
  ExceptT (pure (validatePageOptions options))
  page <- ExceptT (pageUnchecked snapshot name options)
  when (maybe False (/= pageVersion page) (pageToken options)) (throwE LogChanged)
  pure page

-- | The version of a set of paged logs: each name with its log version. A
-- log that could not be paged counts by its name alone.
pagesToken :: [(Name, Either TopicError LogPage)] -> Id
pagesToken pages =
  Id.hashBytes . encodeUtf8 . T.unlines $
    "akyuu-log-pages-v1" : [nameText name <> " " <> either (const "-") (Id.render . pageVersion) result | (name, result) <- pages]

-- | A page without the version rule. The caller checks the version, or
-- binds the read to its own snapshot.
-- Coverage needs complete histories: do not claim a partial DAG is an ordered
-- prefix. Refuse excessive work before resolution instead of silently omitting
-- ancestors or summary alternatives. The budget is shared across all levels.
pageUnchecked :: Snapshot -> Name -> LogPageOptions -> IO (Either TopicError LogPage)
pageUnchecked snapshot name options = runExceptT $ do
  ExceptT (pure (validatePageRange options))
  view <- ExceptT (topicViewAt snapshot name)
  levels <- ExceptT (levelsAtBounded snapshot name 4096)
  items <- either (throwE . InvalidInput) pure (resolution (recentWhole options) levels)
  let offset = (pageNumber options - 1) * pageSize options
      selected = take (pageSize options) (drop offset items)
  pure (LogPage view (levelsToken levels) selected options (offset + length selected < length items) (length items))

pageJSON :: LogPage -> Value
pageJSON report =
  object
    [ "topic" .= viewJSON (pageTopic report),
      "checkpoint" .= let CheckpointId digest = viewCheckpoint (pageTopic report) in Id.render digest,
      "version" .= Id.render (pageVersion report),
      "page" .= pageNumber (pageOptions report),
      "limit" .= pageSize (pageOptions report),
      "keep" .= recentWhole (pageOptions report),
      "has_more" .= pageHasMore report,
      "total" .= pageTotal report,
      "entries" .= map itemJSON (pageItems report)
    ]

renderPage :: LogPage -> Text
renderPage report =
  T.unlines
    ( ["log: " <> nameText (viewName (pageTopic report)), "page: " <> T.pack (show (pageNumber (pageOptions report))) <> if pageHasMore report then " (more available)" else ""]
        <> concat
          [ ["level: " <> T.pack (show (itemLevel item)), "memory: " <> Id.render (itemId item)]
              <> (if itemLevel item > 0 then ["direct sources: " <> T.intercalate " " (map Id.render (Levels.sources (itemMemory item))), "covered episodes: " <> T.intercalate " " (map Id.render (Set.toAscList (itemSources item)))] else [])
              <> [memBody (itemMemory item)]
          | item <- pageItems report
          ]
    )

-- | All explicit predecessors, or the old one-derived-from chain fallback.
predecessors :: Memory -> Set Id
predecessors memory =
  let edges = Set.toAscList (memEdges memory)
      explicit = Set.fromList [target edge | edge <- edges, kind edge == Follows]
   in if Set.null explicit then maybe Set.empty Set.singleton (Episode.previous edges) else explicit

-- | Kahn order with a deterministic priority among available successors.
-- Edges outside this set are allowed for unfold and incomplete-history reads.
orderEntries :: [(Id, Memory)] -> Either Text [(Id, Memory)]
orderEntries entries = go counts ready []
  where
    byId = Map.fromList entries
    counts = Map.unionWith (+) (Map.map (const (0 :: Int)) byId) (Map.fromListWith (+) [(p, 1) | memory <- Map.elems byId, p <- Set.toList (predecessors memory), Map.member p byId])
    priority i = (Down (memCreated (byId Map.! i)), i)
    ready = Set.fromList [priority i | (i, count) <- Map.toList counts, count == 0]
    go remaining available acc = case Set.minView available of
      Nothing | Map.null remaining -> Right (reverse acc)
      Nothing -> Left "The log has a cycle in its predecessor graph."
      Just ((_, i), rest) ->
        let next = Set.filter (`Map.member` remaining) (predecessors (byId Map.! i))
            decremented = foldr (Map.adjust (subtract 1)) (Map.delete i remaining) next
            newlyReady = Set.fromList [priority p | p <- Set.toList next, Map.lookup p decremented == Just 0]
         in go decremented (rest <> newlyReady) ((i, byId Map.! i) : acc)

readLog :: LocalReplica -> Name -> Int -> IO (Either TopicError LogRead)
readLog local name limit = runExceptT $ ExceptT (captureSnapshot local) >>= \snapshot -> ExceptT (logAt snapshot name limit)

logAt :: Snapshot -> Name -> Int -> IO (Either TopicError LogRead)
logAt snapshot name limit = fmap fst <$> logAtWithin snapshot name limit maxBound

logAtWithin :: Snapshot -> Name -> Int -> Int -> IO (Either TopicError (LogRead, Int))
logAtWithin snapshot name limit budget = runExceptT $ do
  when (limit < 0) (throwE (InvalidInput "The log limit must be zero or more."))
  view <- ExceptT (topicViewAt snapshot name)
  when (viewStatus view == Missing) (throwE (MissingTopic name))
  unless (viewStatus view == LogTopic) (throwE (NeedsResolution view))
  let heads = Set.fromList (map headMemoryId (viewHeads view))
  (memories, failures) <- ExceptT (collect Map.empty [] heads)
  ordered <- either (throwE . InvalidInput) pure (orderEntries (Map.toList memories))
  let entries = take limit ordered
      emitted = Set.fromList (map fst entries)
      frontier = (heads <> Set.unions (map (predecessors . snd) entries)) `Set.difference` emitted
  pure (LogRead view entries frontier failures, Map.size memories + length failures)
  where
    collect found failures pending = case Set.minView pending of
      Nothing -> pure (Right (found, reverse failures))
      Just (i, rest)
        | Map.member i found || i `elem` map fst failures -> collect found failures rest
        | Map.size found + length failures >= budget -> pure (Left (InvalidInput "The log traversal budget was exceeded. No partial summary coverage was selected."))
        | otherwise -> do
            result <- readMemory snapshot i
            case result of
              Left err -> collect found ((i, err) : failures) rest
              Right memory -> collect (Map.insert i memory found) failures (rest <> predecessors memory)

appendLog :: LocalReplica -> Name -> Version -> NewMemory -> IO (Either TopicError TopicView)
appendLog local name expected input = appendLogChecked local name expected input []

readLevels :: LocalReplica -> Name -> IO (Either TopicError LogLevels)
readLevels local name = runExceptT $ ExceptT (captureSnapshot local) >>= \snapshot -> ExceptT (levelsAt snapshot name)

levelsAt :: Snapshot -> Name -> IO (Either TopicError LogLevels)
levelsAt snapshot name = levelsWithin snapshot name maxBound maxBound

levelsAtBounded :: Snapshot -> Name -> Int -> IO (Either TopicError LogLevels)
levelsAtBounded snapshot name budget = levelsWithin snapshot name budget 32

levelsWithin :: Snapshot -> Name -> Int -> Int -> IO (Either TopicError LogLevels)
levelsWithin snapshot name budget maxLevels = runExceptT $ do
  when (budget < 1) (throwE (InvalidInput "The log traversal budget must be positive."))
  (reports, checks) <- go 0 budget
  let token = Id.hashBytes (encodeUtf8 (T.unlines (nameText name : [nameText n <> " " <> versionText v | (RefResource n, v) <- checks])))
      levels = LogLevels name reports token checks
  -- Validate every source against the immediately lower level, including
  -- unused overlapping summaries. A partial history cannot justify coverage.
  _ <- either (throwE . InvalidInput) pure (candidates levels)
  pure levels
  where
    go k available = do
      ref <- either (throwE . InvalidInput . describeName (nameText name)) pure (Levels.levelRef name k)
      view <- ExceptT (topicViewAt snapshot ref)
      let check = (RefResource ref, viewVersion view)
      if k > 0 && viewStatus view == Missing
        then pure ([], [check])
        else do
          when (k >= maxLevels) (throwE (InvalidInput "The log summary level budget was exceeded."))
          (result, used) <- ExceptT (logAtWithin snapshot ref maxBound available)
          unless
            ( Set.null (logFrontier result)
                && null (logFailures result)
            )
            (throwE (InvalidInput "The log history is incomplete. Restore the required episodes before a summary operation."))
          (rest, checks) <- go (k + 1) (available - used)
          pure (result : rest, check : checks)

-- | Sources are exact IDs from the level below. Overlap with earlier summaries
-- is valid. All source and target resource versions are checked at publication.
summarise :: LocalReplica -> Name -> Id -> Int -> [Id] -> NewMemory -> IO (Either TopicError TopicView)
summarise local name expected level ids input = runExceptT $ do
  levels <- ExceptT (readLevels local name)
  unless (levelsToken levels == expected) (throwE (InvalidInput "The summary sources changed. Read the log levels before another summary."))
  let reports = levelsReads levels
      given = Set.fromList ids
  unless (level >= 1 && level <= length reports) (throwE (InvalidInput "The summary level must have a complete source level below it."))
  unless (length ids >= 2 && Set.size given == length ids) (throwE (InvalidInput "Give two or more distinct summary sources."))
  let below = Set.fromList (map fst (logEntries (reports !! (level - 1))))
  unless (given `Set.isSubsetOf` below) (throwE (InvalidInput "Every summary source must belong to the immediately lower log level."))
  when (any (\edge -> kind edge `elem` [DerivedFrom, Follows]) (Set.toList (newEdges input))) (throwE (InvalidInput "Summary publication supplies derived_from and follows edges."))
  targetName <- either (throwE . InvalidInput . describeName (nameText name)) pure (Levels.levelRef name level)
  targetVersion <- maybe (throwE (InvalidInput "The target summary level has no version.")) pure (lookup (RefResource targetName) (levelsChecks levels))
  ExceptT (appendLogChecked local targetName targetVersion input {newEdges = newEdges input <> Set.map (Edge DerivedFrom) given} (levelsChecks levels))

-- | Exact direct sources of one accepted summary, in DAG order. This never
-- walks their ancestors or substitutes other summaries for the evidence.
unfold :: LocalReplica -> Id -> IO (Either TopicError [(Id, Memory)])
unfold local digest = runExceptT $ do
  snapshot <- ExceptT (captureSnapshot local)
  memory <- ExceptT (first StorageError <$> readMemory snapshot digest)
  let ids = Levels.sources memory
  when (null ids) (throwE (InvalidInput "This memory has no summary sources."))
  entries <- traverse (\i -> (i,) <$> ExceptT (first StorageError <$> readMemory snapshot i)) ids
  either (throwE . InvalidInput) pure (orderEntries entries)

-- | Flatten each candidate to exact base episodes. A candidate's source count
-- is its base coverage, so the priority is meaningful across different levels.
candidates :: LogLevels -> Either Text [LogItem]
candidates levels = foldLevels 0 Map.empty [] (levelsReads levels)
  where
    foldLevels _ _ acc [] = Right acc
    foldLevels k below acc (report : rest) = do
      items <- traverse (makeItem k below) (logEntries report)
      let coverage = Map.fromList [(itemId item, itemSources item) | item <- items]
      foldLevels (k + 1) coverage (acc <> if k == 0 then [] else items) rest
    makeItem 0 _ (i, memory) = Right (LogItem i memory 0 (Set.singleton i))
    makeItem k below (i, memory) = do
      let sources = Levels.sources memory
      unless (length sources >= 2) (Left "A summary must retain at least two sources from the level below.")
      covered <- traverse (\s -> maybe (Left "A summary source is outside the immediately lower log level.") Right (Map.lookup s below)) sources
      pure (LogItem i memory k (Set.unions covered))

-- | Highest levels first, then greatest base coverage, then ascending ID.
-- A skipped overlapping summary leaves its other sources visible as episodes.
resolution :: Int -> LogLevels -> Either Text [LogItem]
resolution keep levels = do
  summaries <- candidates levels
  let episodes = case levelsReads levels of [] -> []; base : _ -> logEntries base
      recent = Set.fromList (map fst (take (max 0 keep) episodes))
      ranked = sortOn (\item -> (Down (itemLevel item), Down (Set.size (itemSources item)), itemId item)) summaries
      select (covered, chosen) item
        | Set.null (Set.intersection (covered <> recent) (itemSources item)) = (covered <> itemSources item, item : chosen)
        | otherwise = (covered, chosen)
      (_, selected) = foldl select (Set.empty, []) ranked
      owners = Map.fromList [(s, item) | item <- selected, s <- Set.toList (itemSources item)]
      emit (seen, items) (i, memory) = case Map.lookup i owners of
        Nothing -> (seen, LogItem i memory 0 (Set.singleton i) : items)
        Just item | itemId item `Set.member` seen -> (seen, items)
        Just item -> (Set.insert (itemId item) seen, item : items)
  pure (reverse (snd (foldl emit (Set.empty, []) episodes)))

-- | Deterministic oldest-first batches. Coverage is the union of all summaries
-- at the next level, even when a view chooses a different disjoint cover.
todo :: Int -> Int -> LogLevels -> Either Text [(Int, [Id])]
todo size keep levels
  | size < 2 || keep < 0 = Left "The summary batch size must be at least two, and keep must be zero or more."
  | otherwise = Right (concat [runs k below above | (k, below, above) <- zip3 [1 ..] entries (drop 1 entries <> [[]])])
  where
    entries = map logEntries (levelsReads levels)
    runs k below above =
      let covered = Set.fromList (concatMap (Levels.sources . snd) above)
          eligible = if k == 1 then drop keep below else below
          open = reverse [i | (i, _) <- eligible, i `Set.notMember` covered]
       in map (k,) (chunks open)
    chunks xs | length xs >= size = take size xs : chunks (drop size xs)
    chunks _ = []

entriesJSON :: [(Id, Memory)] -> Value
entriesJSON entries = itemsJSON [LogItem i memory 0 (Set.singleton i) | (i, memory) <- entries]

itemsJSON :: [LogItem] -> Value
itemsJSON items = object ["entries" .= map itemJSON items]

itemJSON :: LogItem -> Value
itemJSON item =
  object
    [ "memory" .= Id.render (itemId item),
      "body" .= memBody (itemMemory item),
      "created" .= memCreated (itemMemory item),
      "level" .= itemLevel item,
      "sources" .= map Id.render (Set.toAscList (itemSources item)),
      "direct_sources" .= (if itemLevel item > 0 then map Id.render (Levels.sources (itemMemory item)) else [])
    ]

logJSON :: LogRead -> Value
logJSON report =
  object
    [ "topic" .= viewJSON (logTopic report),
      "entries" .= [itemJSON (LogItem i m 0 (Set.singleton i)) | (i, m) <- logEntries report],
      "complete" .= (Set.null (logFrontier report) && null (logFailures report)),
      "frontier" .= map Id.render (Set.toAscList (logFrontier report)),
      "failures" .= [object ["memory" .= Id.render i, "message" .= describeError (StorageError err)] | (i, err) <- logFailures report]
    ]

levelsJSON :: LogLevels -> Value
levelsJSON levels = object ["ref" .= nameText (levelsBase levels), "version" .= Id.render (levelsToken levels), "levels" .= map logJSON (levelsReads levels)]

renderLog :: LogRead -> Text
renderLog report =
  T.unlines
    ( ["log: " <> nameText (viewName (logTopic report)), "version: " <> versionText (viewVersion (logTopic report))]
        <> concat [[Id.render i, memBody memory] | (i, memory) <- logEntries report]
        <> ["History is incomplete. Frontier: " <> T.intercalate ", " (map Id.render (Set.toAscList (logFrontier report))) | not (Set.null (logFrontier report)) || not (null (logFailures report))]
    )
