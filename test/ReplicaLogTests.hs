{-# LANGUAGE OverloadedStrings #-}

module ReplicaLogTests (replicaLogTests) where

import Akyuu.Graph (Edge (Edge), EdgeType (DerivedFrom, Follows))
import Akyuu.Id (Id)
import Akyuu.Id qualified as Id
import Akyuu.Memory (Memory (memEdges), memoryId, renderMemory)
import Akyuu.Ops (NewMemory (newEdges), buildMemory)
import Akyuu.Refs (Name, mkName)
import Akyuu.Sync.Event (mkEvent)
import Akyuu.Sync.Logs (LogItem (itemId, itemLevel, itemSources), LogLevels (levelsChecks, levelsReads, levelsToken), LogRead (logEntries, logFailures, logFrontier), appendLog, levelsAt, logAt, orderEntries, predecessors, readLevels, readLog, resolution, summarise, todo, unfold)
import Akyuu.Sync.Repository (RepositoryError (MissingLogPredecessor), importState, loadSnapshot, openRepository, snapshotState)
import Akyuu.Sync.State qualified as State
import Akyuu.Sync.Topics (LocalReplica, TopicError (InvalidInput, NeedsResolution, StaleTopic), TopicHead (headEvent, headMemory, headMemoryId, headTime), TopicStatus (LogTopic), TopicView (viewHeads, viewStatus, viewVersion), appendLogChecked, captureSnapshot, createTopic, readTopic)
import Akyuu.Sync.Types (Action (AppendLog, RegisterReplica), EventId, Nonce (Nonce), ReplicaId (ReplicaId), Resource (RegistryResource), mkIdentifier)
import Data.ByteString qualified as BS
import Data.List (sort)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (addUTCTime)
import Support (right)
import System.FilePath ((</>))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))
import Test.Tasty.QuickCheck (NonEmptyList (NonEmpty), Property, conjoin, counterexample, shuffle, testProperty, (===))
import TopicsTests (newTopic, onlyHead, withLocal)

logName :: Name
logName = either (error . show) id (mkName "me/log")

append :: LocalReplica -> Text -> IO Id
append local body = do
  view <- readTopic local logName >>= right
  result <- appendLog local logName (viewVersion view) (newTopic body) >>= right
  headMemoryId <$> onlyHead result

-- A remote event observes only the shared ancestor, although it arrives after
-- the local child. Its timestamp is intentionally earlier than that ancestor.
forkLog :: FilePath -> LocalReplica -> IO (Id, Id, Id)
forkLog root local = do
  base <- append local "base"
  original <- readTopic local logName >>= right
  baseHead <- onlyHead original
  child <- append local "local child"
  repo <- openRepository root >>= right
  snapshot <- loadSnapshot repo >>= right
  let state = snapshotState snapshot
      ident byte = either (error . show) id (mkIdentifier (BS.replicate 16 byte))
      remote = ReplicaId (ident 71)
      registration = either (error . show) id (mkEvent (State.storeId state) remote (Nonce (ident 72)) (Map.keysSet (State.resourceHeads state RegistryResource)) (RegisterReplica remote "remote") (headTime baseHead))
      memory = (either (error . show) id (buildMemory (addUTCTime (-1000) (headTime baseHead)) (newTopic "remote child"))) {memEdges = Set.singleton (Edge Follows base)}
      branch = either (error . show) id (mkEvent (State.storeId state) remote (Nonce (ident 73)) (Set.singleton (headEvent baseHead)) (AppendLog logName (memoryId memory)) (headTime baseHead))
      incoming = either (error . show) id (State.fromEvents (State.storeId state) (registration : branch : Map.elems (State.events state)))
  _ <- importState repo incoming [(memoryId memory, renderMemory memory)] >>= right
  pure (base, child, memoryId memory)

summary :: LocalReplica -> Int -> [Id] -> Text -> IO Id
summary local level ids body = do
  levels <- readLevels local logName >>= right
  view <- summarise local logName (levelsToken levels) level ids (newTopic body) >>= right
  headMemoryId <$> onlyHead view

remoteAppend :: FilePath -> Name -> Set.Set EventId -> Memory -> IO (Either RepositoryError ())
remoteAppend root ref parents memory = do
  repo <- openRepository root >>= right
  snapshot <- loadSnapshot repo >>= right
  let state = snapshotState snapshot
      ident byte = either (error . show) id (mkIdentifier (BS.replicate 16 byte))
      remote = ReplicaId (ident 81)
      time = read "2026-11-03 00:00:00 UTC"
      registration = either (error . show) id (mkEvent (State.storeId state) remote (Nonce (ident 82)) (Map.keysSet (State.resourceHeads state RegistryResource)) (RegisterReplica remote "summary-peer") time)
      branch = either (error . show) id (mkEvent (State.storeId state) remote (Nonce (ident 83)) parents (AppendLog ref (memoryId memory)) time)
      incoming = either (error . show) id (State.fromEvents (State.storeId state) (registration : branch : Map.elems (State.events state)))
  fmap (const ()) <$> importState repo incoming [(memoryId memory, renderMemory memory)]

replicaLogTests :: TestTree
replicaLogTests =
  testGroup
    "replicated logs"
    [ testCase "a diamond reads both branches and the shared ancestor once" $ withLocal $ \root local -> do
        (base, child, remote) <- forkLog root local
        report <- readLog local logName 100 >>= right
        map fst (logEntries report) @?= [child, remote, base]
        logFrontier report @?= Set.empty
        logFailures report @?= [],
      testCase "append joins every event head and every episode head" $ withLocal $ \root local -> do
        (base, child, remote) <- forkLog root local
        before <- readTopic local logName >>= right
        length (viewHeads before) @?= 2
        viewStatus before @?= LogTopic
        joined <- append local "join"
        entry <- readTopic local logName >>= right >>= onlyHead
        predecessors (headMemory entry) @?= Set.fromList [child, remote]
        report <- readLog local logName 100 >>= right
        map fst (logEntries report) @?= [joined, child, remote, base],
      testCase "limits follow deduplication and retain the unvisited frontier" $ withLocal $ \root local -> do
        (base, child, remote) <- forkLog root local
        zero <- readLog local logName 0 >>= right
        logEntries zero @?= []
        logFrontier zero @?= Set.fromList [child, remote]
        one <- readLog local logName 1 >>= right
        map fst (logEntries one) @?= [child]
        logFrontier one @?= Set.fromList [base, remote]
        two <- readLog local logName 2 >>= right
        logFrontier two @?= Set.singleton base,
      testCase "captured checkpoints do not gain later episodes or levels" $ withLocal $ \_ local -> do
        a <- append local "a"
        b <- append local "b"
        captured <- captureSnapshot local >>= right
        _ <- append local "later"
        _ <- summary local 1 [a, b] "summary"
        old <- logAt captured logName 100 >>= right
        map fst (logEntries old) @?= [b, a]
        oldLevels <- levelsAt captured logName >>= right
        length (levelsReads oldLevels) @?= 1,
      testCase "stale append refuses publication" $ withLocal $ \_ local -> do
        _ <- append local "a"
        before <- readTopic local logName >>= right
        _ <- append local "b"
        now <- readTopic local logName >>= right
        appendLog local logName (viewVersion before) (newTopic "lost") >>= (@?= Left (StaleTopic now)),
      testCase "topics cannot be appended as logs" $ withLocal $ \_ local -> do
        view <- createTopic local logName (newTopic "topic") >>= right
        appendLog local logName (viewVersion view) (newTopic "episode") >>= (@?= Left (NeedsResolution view)),
      testCase "imports refuse an append that drops an observed predecessor" $ withLocal $ \root local -> do
        base <- append local "base"
        original <- readTopic local logName >>= right
        entry <- onlyHead original
        let memory = either (error . show) id (buildMemory (headTime entry) (newTopic "missing link"))
        result <- remoteAppend root logName (Set.singleton (headEvent entry)) memory
        case result of
          Left (MissingLogPredecessor _ digest) -> digest @?= base
          other -> assertFailure ("Unexpected import result: " <> show other)
        readTopic local logName >>= (@?= Right original),
      testCase "corrupt required history is explicit and cannot support summaries" $ withLocal $ \root local -> do
        a <- append local "a"
        _ <- append local "b"
        captured <- captureSnapshot local >>= right
        BS.writeFile (root </> "objects" </> T.unpack (Id.render a)) "damaged"
        partial <- logAt captured logName 100 >>= right
        map fst (logFailures partial) @?= [a]
        logFrontier partial @?= Set.singleton a
        result <- levelsAt captured logName
        assertBool "incomplete source history accepted" (case result of Left _ -> True; _ -> False),
      testCase "overlapping summaries have deterministic disjoint cover and raw fallback" $ withLocal $ \_ local -> do
        ids <- traverse (append local) ["a", "b", "c", "d", "e"]
        first <- summary local 1 (take 3 ids) "abc"
        second <- summary local 1 (take 3 (drop 1 ids)) "bcd"
        levels <- readLevels local logName >>= right
        items <- right (resolution 0 levels)
        map itemId (filter ((> 0) . itemLevel) items) @?= [min first second]
        assertCover ids items
        length items @?= 3
        protected <- right (resolution 5 levels)
        map itemLevel protected @?= replicate 5 0,
      testCase "higher levels flatten overlapping sources without duplicate episodes" $ withLocal $ \_ local -> do
        ids <- traverse (append local) ["a", "b", "c", "d", "e"]
        first <- summary local 1 (take 3 ids) "abc"
        second <- summary local 1 (take 3 (drop 1 ids)) "bcd"
        top <- summary local 2 [first, second] "abcd"
        levels <- readLevels local logName >>= right
        items <- right (resolution 0 levels)
        assertCover ids items
        map itemId items @?= [last ids, top]
        Set.size (itemSources (last items)) @?= 4
        unfolded <- unfold local top >>= right
        sort (map fst unfolded) @?= sort [first, second],
      testCase "concurrent summary heads coexist and the next summary joins both" $ withLocal $ \root local -> do
        ids <- traverse (append local) ["a", "b", "c", "d", "e"]
        first <- summary local 1 (take 3 ids) "abc"
        ref <- right (mkName "me/log.l1")
        let memory = either (error . show) id (buildMemory (read "2026-11-03 00:00:00 UTC") ((newTopic "remote bcd") {newEdges = Set.fromList (map (Edge DerivedFrom) (take 3 (drop 1 ids)))}))
        _ <- remoteAppend root ref Set.empty memory >>= right
        forked <- readTopic local ref >>= right
        length (viewHeads forked) @?= 2
        levels <- readLevels local logName >>= right
        items <- right (resolution 0 levels)
        assertCover ids items
        map itemId (filter ((> 0) . itemLevel) items) @?= [min first (memoryId memory)]
        _ <- summary local 1 (drop 3 ids) "de"
        joined <- readTopic local ref >>= right >>= onlyHead
        predecessors (headMemory joined) @?= Set.fromList [first, memoryId memory],
      testCase "summary source version rejects changed history but permits unrelated writes" $ withLocal $ \_ local -> do
        a <- append local "a"
        b <- append local "b"
        before <- readLevels local logName >>= right
        other <- right (mkName "me/other")
        _ <- createTopic local other (newTopic "unrelated") >>= right
        after <- readLevels local logName >>= right
        levelsToken before @?= levelsToken after
        _ <- append local "c"
        summarise local logName (levelsToken before) 1 [a, b] (newTopic "stale") >>= assertInvalid,
      testCase "publication checks source dependencies under the target mutation lock" $ withLocal $ \_ local -> do
        _ <- append local "a"
        _ <- append local "b"
        old <- readLevels local logName >>= right
        level <- right (mkName "me/log.l1")
        target <- readTopic local level >>= right
        _ <- append local "changed source"
        beforeAttempt <- readTopic local level >>= right
        appendLogChecked local level (viewVersion target) (newTopic "stale summary") (levelsChecks old) >>= assertInvalid
        readTopic local level >>= (@?= Right beforeAttempt),
      testCase "source validation rejects duplicates, foreign IDs and supplied evidence edges" $ withLocal $ \_ local -> do
        a <- append local "a"
        b <- append local "b"
        levels <- readLevels local logName >>= right
        let attempt ids input = summarise local logName (levelsToken levels) 1 ids input >>= assertInvalid
        attempt [a, a] (newTopic "duplicate")
        attempt [a, Id.hashBytes "foreign"] (newTopic "foreign")
        attempt [a, b] ((newTopic "extra") {newEdges = Set.singleton (Edge DerivedFrom a)}),
      testCase "todo uses union coverage and keeps recent episodes whole" $ withLocal $ \_ local -> do
        ids <- traverse (append local) ["a", "b", "c", "d", "e"]
        levels <- readLevels local logName >>= right
        todo 2 1 levels @?= Right [(1, take 2 ids), (1, take 2 (drop 2 ids))]
        _ <- summary local 1 (take 3 ids) "abc"
        _ <- summary local 1 (take 3 (drop 1 ids)) "bcd"
        after <- readLevels local logName >>= right
        todo 2 1 after @?= Right [(2, reverse (map fst (logEntries (levelsReads after !! 1))))],
      testProperty "DAG order is independent of input order and respects every edge" $ \(NonEmpty clocks) ->
        let fixture = generated (take 30 clocks)
         in do
              shuffled <- shuffle fixture
              pure (checkOrder fixture shuffled)
    ]
  where
    assertInvalid (Left (InvalidInput _)) = pure ()
    assertInvalid result = assertFailure ("Expected invalid input: " <> show result)

assertCover :: [Id] -> [LogItem] -> IO ()
assertCover ids items = do
  let allSources = concatMap (Set.toList . itemSources) items
  sort allSources @?= sort ids
  Set.size (Set.fromList allSources) @?= length allSources

generated :: [Int] -> [(Id, Memory)]
generated clocks = reverse (snd (foldl step ([], []) (zip [0 :: Int ..] clocks)))
  where
    epoch = read "2026-01-01 00:00:00 UTC"
    step (prior, entries) (n, clock) =
      let parents = take (n `mod` 4) prior
          memory = either (error . show) id (buildMemory (addUTCTime (fromIntegral (clock `mod` 200)) epoch) ((newTopic (T.pack (show n))) {newEdges = Set.fromList (map (Edge Follows) parents)}))
          i = memoryId memory
       in (i : prior, (i, memory) : entries)

checkOrder :: [(Id, Memory)] -> [(Id, Memory)] -> Property
checkOrder original shuffled = case (orderEntries original, orderEntries shuffled) of
  (Right first, Right second) ->
    let positions = Map.fromList (zip (map fst first) [0 :: Int ..])
     in conjoin [first === second, sort (map fst first) === sort (map fst original), counterexample "ancestor precedes descendant" (and [positions Map.! i < positions Map.! p | (i, m) <- original, p <- Set.toList (predecessors m)])]
  other -> counterexample (show other) False
