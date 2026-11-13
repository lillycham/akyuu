{-# LANGUAGE OverloadedStrings #-}

module ArchiveTests (archiveTests, archiveCrashWorker) where

import Akyuu.Fs (AtomicStep (DirectorySynced, FileSynced, Renamed, TemporaryWritten))
import Akyuu.Graph (Edge (Edge), EdgeType (About))
import Akyuu.Id (Id)
import Akyuu.Id qualified as Id
import Akyuu.Memory (Memory (memBody), renderMemory)
import Akyuu.Ops (NewMemory (newEdges))
import Akyuu.Refs (mkName)
import Akyuu.Sync.Checkpoint (CheckpointId (CheckpointId), activeObjects, checkpointEvents, checkpointId, checkpointObjects, evictedObjects, pendingEvents, pendingObjects, renderCheckpoint, withEvicted)
import Akyuu.Sync.Event (mkEvent)
import Akyuu.Sync.Logs qualified as Logs
import Akyuu.Sync.Repository (Boundary (EvictionsSynced, MemoryEvicted, WriteBoundary), CollectionPlan (collectionCandidates, collectionCheckpoint, collectionEvicted, collectionRetained), FaultHook, Repository, RepositoryError (ArchiveNotAccepted, CollectionIncomplete, InvalidResidency, RepositoryBusy, StaleCheckpoint, UnacceptedObject), Snapshot, WriteTarget (ArchiveCheckpointFile, ArchiveEventFile, ArchiveMemoryFile, CurrentFile), acknowledgePublished, acknowledgePublishedWith, archiveSnapshot, archiveSnapshotWith, collect, collectWith, importState, loadSnapshot, openRepository, planCollection, readMemory, snapshotCheckpoint, snapshotId, snapshotState, verifyRepository)
import Akyuu.Sync.Resources (writeResource)
import Akyuu.Sync.Search (SearchReport (SearchReport), searchTopics)
import Akyuu.Sync.State qualified as State
import Akyuu.Sync.Topics (LocalReplica, TopicHead (headEvent, headMemory, headMemoryId),TopicView (viewVersion), changeResource, createTopic, readTopic, replaceTopic)
import Akyuu.Sync.Topics qualified as Topics
import Akyuu.Sync.Types (Action (ClearPin, ClearReview, RegisterReplica, SetPin, SetReview, SetTopic),EventId, Nonce (Nonce), ReplicaId (ReplicaId), Resource (PinResource, RegistryResource, ReviewResource), ReviewValue (ReviewValue), mkIdentifier)
import Control.Concurrent (forkFinally, forkIO, newEmptyMVar, putMVar, takeMVar)
import Control.Exception (finally, throwIO)
import Control.Monad (foldM, forM_, void, when)
import Data.ByteString qualified as BS
import Data.IORef (atomicModifyIORef', newIORef)
import Data.List (sortOn)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Text.Encoding (encodeUtf8)
import Data.Time (addUTCTime)
import Support (right)
import System.Directory (doesFileExist, getModificationTime, listDirectory, removeFile, setModificationTime)
import System.Environment (getExecutablePath)
import System.Exit (ExitCode (ExitFailure))
import System.FilePath ((</>))
import System.Posix.Process (exitImmediately)
import System.Process (CreateProcess (close_fds), proc, readCreateProcessWithExitCode)
import System.Timeout (timeout)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))
import TopicsTests (forkTopic, newTopic, onlyHead, topicName, withLocal)

withRepository :: (FilePath -> LocalReplica -> Repository -> IO a) -> IO a
withRepository action = withLocal $ \root local -> openRepository root >>= right >>= action root local

versions :: LocalReplica -> IO [TopicHead]
versions local = do
  first <- createTopic local topicName (newTopic "first fossil") >>= right
  (entries, _) <- foldM step ([], first) ["second fossil", "current living"]
  pure (reverse entries)
  where
    step (entries, previous) body = do
      old <- onlyHead previous
      next <- replaceTopic local topicName (viewVersion previous) (newTopic body) >>= right
      pure (old : entries, next)

-- Tests simulate the transport's verified-success boundary. No remote exists.
publish :: Repository -> IO Snapshot
publish repo = do
  snapshot <- loadSnapshot repo >>= right
  key <- archiveSnapshot repo snapshot >>= right
  acknowledgePublished repo key >>= right

objectPath :: FilePath -> Id -> FilePath
objectPath root digest = root </> "objects" </> T.unpack (Id.render digest)

archivePath :: FilePath -> Id -> FilePath
archivePath root digest = root </> "archive" </> "objects" </> T.unpack (Id.render digest)

archiveTests :: TestTree
archiveTests = testGroup "replica archive and GC" [storageTests, concurrencyTests, retentionTests, removalTests, resourceTests, crashTests]

-- Pause just once, with bounded waits and exception propagation from the worker.
whilePaused :: (Boundary -> Bool) -> (FaultHook -> IO a) -> IO () -> IO a
whilePaused matches action during = do
  ready <- newEmptyMVar
  release <- newEmptyMVar
  done <- newEmptyMVar
  waiting <- newIORef True
  let hook boundary = when (matches boundary) $ do
        first <- atomicModifyIORef' waiting (\value -> (False, value))
        when first (putMVar ready () >> takeMVar release)
  _ <- forkFinally (action hook) (putMVar done)
  (timeout 5000000 (takeMVar ready) >>= (@?= Just ()) >> during)
    `finally` putMVar release ()
  result <- timeout 5000000 (takeMVar done)
  case result of
    Just outcome -> either throwIO pure outcome
    Nothing -> assertFailure "The paused archive operation did not finish."

concurrencyTests :: TestTree
concurrencyTests =
  testGroup
    "archive concurrency"
    [ testCase "a writer finishes while archive payload preparation is paused" $ withRepository $ \_ local repo -> do
        _ <- versions local
        captured <- loadSnapshot repo >>= right
        let copying (WriteBoundary (ArchiveMemoryFile _) TemporaryWritten) = True
            copying _ = False
        key <- whilePaused copying (\hook -> archiveSnapshotWith hook repo captured) $ do
          before <- readTopic local topicName >>= right
          void (replaceTopic local topicName (viewVersion before) (newTopic "written during archive") >>= right)
        key @?= Right (snapshotId captured)
        after <- acknowledgePublished repo (snapshotId captured) >>= right
        Set.size (pendingObjects (snapshotCheckpoint after)) @?= 1
        Set.size (pendingEvents (snapshotCheckpoint after)) @?= 1,
      testCase "concurrent preparers save the same complete archive" $ withRepository $ \_ local repo -> do
        _ <- versions local
        captured <- loadSnapshot repo >>= right
        let copying (WriteBoundary (ArchiveMemoryFile _) TemporaryWritten) = True
            copying _ = False
        first <-
          whilePaused copying (\hook -> archiveSnapshotWith hook repo captured) $
            archiveSnapshot repo captured >>= (@?= Right (snapshotId captured))
        first @?= Right (snapshotId captured)
        void (acknowledgePublished repo (snapshotId captured) >>= right),
      testCase "GC can evict while an older archive manifest is prepared" $ withRepository $ \root local repo -> do
        old <- versions local
        captured <- publish repo
        let marker = WriteBoundary (ArchiveCheckpointFile (snapshotId captured)) TemporaryWritten
        archived <- whilePaused (== marker) (\hook -> archiveSnapshotWith hook repo captured) $ do
          void (collect repo (snapshotId captured) 1 >>= right)
          forM_ old (\entry -> doesFileExist (objectPath root (headMemoryId entry)) >>= (@?= False))
        archived @?= Right (snapshotId captured)
        forM_ old (\entry -> readMemory captured (headMemoryId entry) >>= (@?= Right (headMemory entry)))
        void (acknowledgePublished repo (snapshotId captured) >>= right),
      testCase "a write during GC archive preparation invalidates the plan" $ withRepository $ \root local repo -> do
        old <- versions local
        captured <- publish repo
        let marker = WriteBoundary (ArchiveCheckpointFile (snapshotId captured)) TemporaryWritten
        result <- whilePaused (== marker) (\hook -> collectWith hook repo (snapshotId captured) 1) $ do
          before <- readTopic local topicName >>= right
          void (replaceTopic local topicName (viewVersion before) (newTopic "new pending value") >>= right)
        result @?= Left StaleCheckpoint
        forM_ old (\entry -> doesFileExist (objectPath root (headMemoryId entry)) >>= (@?= True))
        after <- readTopic local topicName >>= right >>= onlyHead
        memBody (headMemory after) @?= "new pending value",
      testCase "archive refuses a snapshot from another repository" $ withRepository $ \_ _ repo ->
        withRepository $ \_ _ other -> do
          captured <- loadSnapshot other >>= right
          archiveSnapshot repo captured >>= (@?= Left ArchiveNotAccepted)
    ]

storageTests :: TestTree
storageTests =
  testGroup
    "archive and publication"
    [ testCase "archive contains only accepted data and does not acknowledge publication" $ withRepository $ \root local repo -> do
        _ <- versions local
        before <- loadSnapshot repo >>= right
        BS.writeFile (objectPath root (Id.hashBytes "orphan")) "orphan"
        key <- archiveSnapshot repo before >>= right
        key @?= snapshotId before
        loadSnapshot repo >>= (@?= Right before)
        files <- listDirectory (root </> "archive" </> "objects")
        Set.fromList files @?= Set.map (T.unpack . Id.render) (checkpointObjects (snapshotCheckpoint before))
        assertBool "local archive cleared pending work" (not (Set.null (pendingObjects (snapshotCheckpoint before)))),
      testCase "an old publication acknowledgement preserves later local obligations" $ withRepository $ \_ local repo -> do
        _ <- createTopic local topicName (newTopic "first") >>= right
        captured <- loadSnapshot repo >>= right
        key <- archiveSnapshot repo captured >>= right
        before <- readTopic local topicName >>= right
        newer <- replaceTopic local topicName (viewVersion before) (newTopic "later") >>= right
        newest <- onlyHead newer
        acknowledged <- acknowledgePublished repo key >>= right
        pendingObjects (snapshotCheckpoint acknowledged) @?= Set.singleton (headMemoryId newest)
        Set.size (pendingEvents (snapshotCheckpoint acknowledged)) @?= 1
        acknowledgePublished repo key >>= (@?= Right acknowledged),
      testCase "acknowledgement removes older archive markers and keeps newer ones" $ withRepository $ \root local repo -> do
        _ <- createTopic local topicName (newTopic "first") >>= right
        old <- loadSnapshot repo >>= right >>= \captured -> archiveSnapshot repo captured >>= right
        before <- readTopic local topicName >>= right
        _ <- replaceTopic local topicName (viewVersion before) (newTopic "later") >>= right
        new <- loadSnapshot repo >>= right >>= \captured -> archiveSnapshot repo captured >>= right
        let directory = root </> "archive" </> "checkpoints"
            marker (CheckpointId digest) = T.unpack (Id.render digest)
            markers = Set.fromList <$> listDirectory directory
        -- Do not depend on the timestamp resolution of the file system.
        written <- getModificationTime (directory </> marker new)
        setModificationTime (directory </> marker old) (addUTCTime (-60) written)
        _ <- acknowledgePublished repo old >>= right
        markers >>= (@?= Set.fromList [marker old, marker new])
        _ <- acknowledgePublished repo new >>= right
        markers >>= (@?= Set.singleton (marker new)),
      testCase "acknowledgement requires a complete verified archive" $ withRepository $ \root local repo -> do
        old <- versions local
        captured <- loadSnapshot repo >>= right
        key <- archiveSnapshot repo captured >>= right
        let digest = headMemoryId (head old)
        removeFile (archivePath root digest)
        acknowledgePublished repo key >>= assertLeft
        loadSnapshot repo >>= (@?= Right captured),
      testCase "corrupt archive bytes block acknowledgement and collection" $ withRepository $ \root local repo -> do
        old <- versions local
        let target = archivePath root (headMemoryId (head old))
        unpublished <- loadSnapshot repo >>= right
        _ <- archiveSnapshot repo unpublished >>= right
        BS.writeFile target "corrupt"
        acknowledgePublished repo (snapshotId unpublished) >>= assertLeft
        loadSnapshot repo >>= (@?= Right unpublished)
        removeFile target
        before <- publish repo
        BS.writeFile target "corrupt"
        collect repo (snapshotId before) 1 >>= assertLeft
        loadSnapshot repo >>= (@?= Right before)
        forM_ old (\entry -> doesFileExist (objectPath root (headMemoryId entry)) >>= (@?= True)),
      testCase "an existing corrupt local copy never hides behind archive fallback" $ withRepository $ \root local repo -> do
        old <- versions local
        snapshot <- publish repo
        let digest = headMemoryId (head old)
        BS.writeFile (objectPath root digest) "corrupt"
        readMemory snapshot digest >>= assertLeft,
      testCase "archive preparations cannot make an unaccepted memory readable" $ withRepository $ \root local repo -> do
        _ <- versions local
        snapshot <- loadSnapshot repo >>= right
        _ <- archiveSnapshot repo snapshot >>= right
        BS.writeFile (archivePath root (Id.hashBytes "unaccepted")) "unaccepted"
        readMemory snapshot (Id.hashBytes "unaccepted") >>= (@?= Left (UnacceptedObject (Id.hashBytes "unaccepted"))),
      testCase "a canonical checkpoint cannot mark a live head as evicted" $ withRepository $ \root local repo -> do
        _ <- versions local
        ready <- publish repo
        current <- readTopic local topicName >>= right >>= onlyHead
        invalid <- right (withEvicted (Set.singleton (headMemoryId current)) (snapshotCheckpoint ready))
        let CheckpointId key = checkpointId invalid
        BS.writeFile (root </> "checkpoints" </> T.unpack (Id.render key)) (renderCheckpoint invalid)
        BS.writeFile (root </> "CURRENT") (encodeUtf8 (Id.render key <> "\n"))
        verifyRepository repo >>= (@?= Left InvalidResidency)
    ]

retentionTests :: TestTree
retentionTests =
  testGroup
    "causal roots"
    [ testCase "pending intermediate versions remain active despite a local archive" $ withRepository $ \root local repo -> do
        old <- versions local
        captured <- loadSnapshot repo >>= right
        _ <- archiveSnapshot repo captured >>= right
        plan <- planCollection repo 1 >>= right
        collectionCandidates plan @?= Set.empty
        _ <- collect repo (snapshotId captured) 1 >>= right
        forM_ old (\entry -> doesFileExist (objectPath root (headMemoryId entry)) >>= (@?= True)),
      testCase "generations retain ancestry along both conflict branches" $ withRepository $ \root local repo -> do
        _ <- forkTopic False root local
        ready <- publish repo
        shallow <- planCollection repo 1 >>= right
        Set.size (collectionCandidates shallow) @?= 1
        deep <- planCollection repo 2 >>= right
        collectionCandidates deep @?= Set.empty
        collectionRetained deep @?= checkpointObjects (snapshotCheckpoint ready),
      testCase "log and summary roots retain every follows and evidence dependency" $ withRepository $ \_ local repo -> do
        name <- right (mkName "me/log")
        let append body = do
              before <- readTopic local name >>= right
              Logs.appendLog local name (viewVersion before) (newTopic body) >>= right >>= onlyHead
        a <- append "episode a"
        b <- append "episode b"
        levels <- Logs.readLevels local name >>= right
        _ <- Logs.summarise local name (Logs.levelsToken levels) 1 [headMemoryId a, headMemoryId b] (newTopic "summary") >>= right
        _ <- publish repo
        plan <- planCollection repo 1 >>= right
        collectionCandidates plan @?= Set.empty,
      testCase "retaining edges protect dependencies while supersession permits eviction" $ withRepository $ \_ local repo -> do
        old <- versions local
        other <- right (mkName "me/evidence")
        let dependency = headMemoryId (head old)
        _ <- createTopic local other ((newTopic "retains evidence") {newEdges = Set.singleton (Edge About dependency)}) >>= right
        _ <- publish repo
        plan <- planCollection repo 1 >>= right
        assertBool "retaining edge ignored" (dependency `Set.member` collectionRetained plan)
        collectionCandidates plan @?= Set.singleton (headMemoryId (old !! 1)),
      testCase "GC preserves review records without pinning their published endpoints" $ withRepository $ \_ local repo -> do
        old <- versions local
        before <- loadSnapshot repo >>= right
        let a = headMemoryId (head old); b = headMemoryId (old !! 1); resource = ReviewResource a b
        _ <- writeResource local (State.version (snapshotState before) resource) (SetReview a b (ReviewValue "test" "distinct")) >>= right
        ready <- publish repo
        let reviewed = State.interpret (snapshotState ready) resource
        _ <- collect repo (snapshotId ready) 1 >>= right
        after <- loadSnapshot repo >>= right
        State.interpret (snapshotState after) resource @?= reviewed
        State.events (snapshotState after) @?= State.events (snapshotState ready)
        evictedObjects (snapshotCheckpoint after) @?= Set.fromList [a, b]
    ]

resourceTests :: TestTree
resourceTests =
  testGroup
    "observed pin and review changes"
    [ testCase "a late concurrent pin survives a clear and protects its payload" $ withRepository $ \_ local repo -> do
        old <- versions local
        before <- loadSnapshot repo >>= right
        let digest = headMemoryId (head old); resource = PinResource digest
        pinned <- changeResource local (State.version (snapshotState before) resource) (SetPin digest) >>= right
        let parents = Map.keysSet (State.resourceHeads (snapshotState pinned) resource)
        _ <- changeResource local (State.version (snapshotState pinned) resource) (ClearPin digest) >>= right
        merged <- importConcurrent repo parents (SetPin digest)
        State.interpret (snapshotState merged) resource @?= State.PinState True
        _ <- publish repo
        plan <- planCollection repo 1 >>= right
        assertBool "concurrent pin lost its root" (digest `Set.member` collectionRetained plan),
      testCase "concurrent review reasons coexist and observed clear consumes both" $ withRepository $ \_ local repo -> do
        old <- versions local
        before <- loadSnapshot repo >>= right
        let a = headMemoryId (head old); b = headMemoryId (old !! 1); resource = ReviewResource a b
        first <- changeResource local (State.version (snapshotState before) resource) (SetReview a b (ReviewValue "first" "initial")) >>= right
        let parents = Map.keysSet (State.resourceHeads (snapshotState first) resource)
        _ <- changeResource local (State.version (snapshotState first) resource) (SetReview a b (ReviewValue "local" "local reason")) >>= right
        merged <- importConcurrent repo parents (SetReview b a (ReviewValue "remote" "remote reason"))
        case State.interpret (snapshotState merged) resource of
          State.ReviewState records -> sortOn show (Map.elems records) @?= [ReviewValue "local" "local reason", ReviewValue "remote" "remote reason"]
          other -> assertFailure (show other)
        cleared <- changeResource local (State.version (snapshotState merged) resource) (ClearReview a b) >>= right
        State.interpret (snapshotState cleared) resource @?= State.ReviewState Map.empty,
      testCase "a late unseen review survives an observed clear" $ withRepository $ \_ local repo -> do
        old <- versions local
        before <- loadSnapshot repo >>= right
        let a = headMemoryId (head old); b = headMemoryId (old !! 1); resource = ReviewResource a b
        first <- changeResource local (State.version (snapshotState before) resource) (SetReview a b (ReviewValue "first" "initial")) >>= right
        let parents = Map.keysSet (State.resourceHeads (snapshotState first) resource)
        _ <- changeResource local (State.version (snapshotState first) resource) (ClearReview a b) >>= right
        merged <- importConcurrent repo parents (SetReview a b (ReviewValue "remote" "late reason"))
        case State.interpret (snapshotState merged) resource of
          State.ReviewState records -> Map.elems records @?= [ReviewValue "remote" "late reason"]
          other -> assertFailure (show other)
    ]

importConcurrent :: Repository -> Set.Set EventId -> Action -> IO Snapshot
importConcurrent repo parents action = do
  before <- loadSnapshot repo >>= right
  let state = snapshotState before
      ident byte = either (error . show) id (mkIdentifier (BS.replicate 16 byte))
      replica = ReplicaId (ident 91)
      time = read "2026-11-03 00:00:00 UTC"
      registration = either (error . show) id (mkEvent (State.storeId state) replica (Nonce (ident 92)) (Map.keysSet (State.resourceHeads state RegistryResource)) (RegisterReplica replica "peer") time)
      concurrent = either (error . show) id (mkEvent (State.storeId state) replica (Nonce (ident 93)) parents action time)
      incoming = either (error . show) id (State.fromEvents (State.storeId state) (registration : concurrent : Map.elems (State.events state)))
  importState repo incoming [] >>= right

removalTests :: TestTree
removalTests =
  testGroup
    "eviction and fallback"
    [ testCase "old snapshots survive eviction, reopen and repeated import without resurrection" $ withRepository $ \root local repo -> do
        old <- versions local
        captured <- publish repo
        plan <- planCollection repo 1 >>= right
        collectionCandidates plan @?= Set.fromList (map headMemoryId old)
        result <- collect repo (collectionCheckpoint plan) 1 >>= right
        after <- loadSnapshot repo >>= right
        collectionEvicted result @?= Set.fromList (map headMemoryId old)
        forM_ old $ \entry -> do
          doesFileExist (objectPath root (headMemoryId entry)) >>= (@?= False)
          doesFileExist (archivePath root (headMemoryId entry)) >>= (@?= True)
          readMemory captured (headMemoryId entry) >>= (@?= Right (headMemory entry))
        reopened <- openRepository root >>= right
        loadSnapshot reopened >>= (@?= Right after)
        _ <- importState repo (snapshotState captured) [(headMemoryId entry, renderMemory (headMemory entry)) | entry <- old] >>= right
        forM_ old (\entry -> doesFileExist (objectPath root (headMemoryId entry)) >>= (@?= False))
        SearchReport _ _ hits <- searchTopics local "fossil" 10 >>= right
        hits @?= []
        checkpointObjects (snapshotCheckpoint after) @?= checkpointObjects (snapshotCheckpoint captured),
      testCase "a new live reference restores a locally evicted payload" $ withRepository $ \root local repo -> do
        old <- versions local
        ready <- publish repo
        _ <- collect repo (snapshotId ready) 1 >>= right
        before <- loadSnapshot repo >>= right
        let digest = headMemoryId (head old)
        _ <- changeResource local (State.version (snapshotState before) (PinResource digest)) (SetPin digest) >>= right
        after <- loadSnapshot repo >>= right
        assertBool "live pin did not restore residency" (digest `Set.member` activeObjects (snapshotCheckpoint after))
        doesFileExist (objectPath root digest) >>= (@?= True),
      testCase "a larger generation depth restores required historical copies" $ withRepository $ \root local repo -> do
        old <- versions local
        ready <- publish repo
        _ <- collect repo (snapshotId ready) 1 >>= right
        evicted <- loadSnapshot repo >>= right
        _ <- collect repo (snapshotId evicted) 3 >>= right
        forM_ old (\entry -> doesFileExist (objectPath root (headMemoryId entry)) >>= (@?= True))
        after <- loadSnapshot repo >>= right
        evictedObjects (snapshotCheckpoint after) @?= Set.empty,
      testCase "a branch from an old ancestor restores copies that a deep collection retains" $ withRepository $ \root local repo -> do
        old <- versions local
        ready <- publish repo
        _ <- collect repo (snapshotId ready) 2 >>= right
        let fossil = headMemoryId (head old)
        evicted <- loadSnapshot repo >>= right
        evictedObjects (snapshotCheckpoint evicted) @?= Set.singleton fossil
        -- A peer replaces the first version, concurrent with the later ones.
        -- The first version is now one generation below a head, not two.
        _ <- importConcurrent repo (Set.singleton (headEvent (head old))) (SetTopic topicName (headMemoryId (old !! 1)))
        after <- loadSnapshot repo >>= right
        assertBool "a retained ancestor stayed evicted" (fossil `Set.member` activeObjects (snapshotCheckpoint after))
        doesFileExist (objectPath root fossil) >>= (@?= True)
        plan <- planCollection repo 2 >>= right
        collectionRetained plan `Set.intersection` evictedObjects (snapshotCheckpoint after) @?= Set.empty,
      testCase "a plain write after collection restores no historical copy" $ withRepository $ \_ local repo -> do
        old <- versions local
        ready <- publish repo
        _ <- collect repo (snapshotId ready) 1 >>= right
        current <- readTopic local topicName >>= right
        _ <- replaceTopic local topicName (viewVersion current) (newTopic "after collection") >>= right
        after <- loadSnapshot repo >>= right
        evictedObjects (snapshotCheckpoint after) @?= Set.fromList (map headMemoryId old),
      testCase "a pending intermediate pin protects an already accepted payload" $ withRepository $ \_ local repo -> do
        old <- versions local
        published <- publish repo
        _ <- collect repo (snapshotId published) 1 >>= right
        before <- loadSnapshot repo >>= right
        let digest = headMemoryId (head old); resource = PinResource digest
        pinned <- changeResource local (State.version (snapshotState before) resource) (SetPin digest) >>= right
        cleared <- changeResource local (State.version (snapshotState pinned) resource) (ClearPin digest) >>= right
        pendingObjects (snapshotCheckpoint cleared) @?= Set.empty
        State.interpret (snapshotState cleared) resource @?= State.PinState False
        plan <- planCollection repo 1 >>= right
        assertBool "pending intermediate event lost its payload root" (digest `Set.member` collectionRetained plan),
      testCase "a writer invalidates an old GC checkpoint before any removal" $ withRepository $ \root local repo -> do
        old <- versions local
        ready <- publish repo
        current <- readTopic local topicName >>= right
        _ <- replaceTopic local topicName (viewVersion current) (newTopic "new pending") >>= right
        collect repo (snapshotId ready) 1 >>= (@?= Left StaleCheckpoint)
        forM_ old (\entry -> doesFileExist (objectPath root (headMemoryId entry)) >>= (@?= True)),
      testCase "readers cross the eviction publication boundary without a missing payload" $ withRepository $ \_ local repo -> do
        old <- versions local
        before <- publish repo
        pausedCollection repo before $ do
          during <- loadSnapshot repo >>= right
          forM_ old (\entry -> readMemory during (headMemoryId entry) >>= (@?= Right (headMemory entry)))
        forM_ old (\entry -> readMemory before (headMemoryId entry) >>= (@?= Right (headMemory entry))),
      testCase "collection and writers use the same bounded mutation lock" $ withRepository $ \_ local repo -> do
        _ <- versions local
        before <- publish repo
        view <- readTopic local topicName >>= right
        pausedCollection repo before $ do
          outcome <- replaceTopic local topicName (viewVersion view) (newTopic "concurrent writer")
          case outcome of
            Left (Topics.StorageError RepositoryBusy) -> pure ()
            other -> assertFailure ("Writer bypassed collection lock: " <> show other)
        _ <- replaceTopic local topicName (viewVersion view) (newTopic "retried writer") >>= right
        pure (),
      testCase "a failed unlink reports accepted eviction and permits cleanup retry" $ withRepository $ \_ local repo -> do
        old <- versions local
        ready <- publish repo
        let hook boundary = case boundary of MemoryEvicted _ -> ioError (userError "stop after one unlink"); _ -> pure ()
        outcome <- collectWith hook repo (snapshotId ready) 1
        key <- case outcome of Left (CollectionIncomplete key _) -> pure key; _ -> assertFailure (show outcome)
        after <- loadSnapshot repo >>= right
        snapshotId after @?= key
        _ <- collect repo key 1 >>= right
        forM_ old (\entry -> readMemory ready (headMemoryId entry) >>= (@?= Right (headMemory entry)))
    ]

pausedCollection :: Repository -> Snapshot -> IO () -> IO ()
pausedCollection repo before during = do
  ready <- newEmptyMVar
  release <- newEmptyMVar
  done <- newEmptyMVar
  let hook boundary = when (boundary == WriteBoundary CurrentFile Renamed) (putMVar ready () >> takeMVar release)
  _ <- forkIO (collectWith hook repo (snapshotId before) 1 >>= putMVar done)
  ( do
      reached <- timeout 5000000 (takeMVar ready)
      reached @?= Just ()
      during
    )
    `finally` putMVar release ()
  finished <- timeout 5000000 (takeMVar done)
  case finished of
    Just result -> void (right result)
    Nothing -> assertFailure "Collection did not finish after release."

crashTests :: TestTree
crashTests =
  testGroup
    "process death"
    [ testGroup
        "archive dependencies and manifest"
        [ testCase (label <> " / " <> show step) $ withRepository $ \root local repo -> do
            old <- versions local
            before <- loadSnapshot repo >>= right
            dies root "archive" label (show step)
            after <- loadSnapshot repo >>= right
            after @?= before
            _ <- archiveSnapshot repo after >>= right
            forM_ old (\entry -> readMemory after (headMemoryId entry) >>= (@?= Right (headMemory entry)))
        | label <- ["payload", "event", "manifest"],
          step <- [TemporaryWritten, FileSynced, Renamed, DirectorySynced]
        ],
      testGroup
        "collection pointer and unlink"
        [ testCase label $ withRepository $ \root local repo -> do
            old <- versions local
            before <- publish repo
            dies root "collect" target step
            reopened <- openRepository root >>= right
            after <- loadSnapshot reopened >>= right
            let gone = evictedObjects (snapshotCheckpoint after)
            assertBool "partial eviction manifest" (Set.null gone || gone == Set.fromList (map headMemoryId old))
            checkpointEvents (snapshotCheckpoint after) @?= checkpointEvents (snapshotCheckpoint before)
            forM_ old (\entry -> readMemory before (headMemoryId entry) >>= (@?= Right (headMemory entry)))
            _ <- collect reopened (snapshotId after) 1 >>= right
            pure ()
        | (label, target, step) <-
            [(show step, "current", show step) | step <- [TemporaryWritten, FileSynced, Renamed, DirectorySynced]]
              <> [("unlink", "unlink", ""), ("directory flush", "flush", "")]
        ],
      testGroup
        "acknowledgement pointer"
        [ testCase (show step) $ withRepository $ \root local repo -> do
            _ <- versions local
            before <- loadSnapshot repo >>= right
            key <- archiveSnapshot repo before >>= right
            dies root "acknowledge" "current" (show step)
            after <- loadSnapshot repo >>= right
            let pending = pendingObjects (snapshotCheckpoint after)
            assertBool "partial acknowledgement" (Set.null pending || pending == pendingObjects (snapshotCheckpoint before))
            _ <- acknowledgePublished repo key >>= right
            pure ()
        | step <- [TemporaryWritten, FileSynced, Renamed, DirectorySynced]
        ]
    ]

-- Start a fresh runtime: fork-only workers can inherit Haskell runtime locks
-- or crash on macOS after the parent has used concurrent I/O.
dies :: FilePath -> String -> String -> String -> IO ()
dies root operation target step = do
  executable <- getExecutablePath
  result <- timeout 15000000 (readCreateProcessWithExitCode (proc executable ["--archive-crash", root, operation, target, step]) {close_fds = True} "")
  case result of
    Just (code, out, err) -> assertBool ("Crash worker: " <> show code <> "\n" <> out <> err) (code == ExitFailure 77)
    Nothing -> assertFailure "The archive crash worker exceeded its deadline."

archiveCrashWorker :: FilePath -> String -> String -> String -> IO ()
archiveCrashWorker root operation target step = do
  repo <- openRepository root >>= right
  captured <- loadSnapshot repo >>= right
  let hook boundary = when (matches boundary) (exitImmediately (ExitFailure 77))
      matches boundary = case boundary of
        WriteBoundary (ArchiveMemoryFile _) actual -> target == "payload" && show actual == step
        WriteBoundary (ArchiveEventFile _) actual -> target == "event" && show actual == step
        WriteBoundary (ArchiveCheckpointFile _) actual -> target == "manifest" && show actual == step
        WriteBoundary CurrentFile actual -> target == "current" && show actual == step
        MemoryEvicted _ -> target == "unlink"
        EvictionsSynced -> target == "flush"
        _ -> False
  case operation of
    "archive" -> void (archiveSnapshotWith hook repo captured >>= right)
    "collect" -> void (collectWith hook repo (snapshotId captured) 1 >>= right)
    "acknowledge" -> void (acknowledgePublishedWith hook repo (snapshotId captured) >>= right)
    _ -> assertFailure "Unknown archive crash operation."
  exitImmediately (ExitFailure 78)

assertLeft :: (Show a, Show e) => Either e a -> IO ()
assertLeft (Left _) = pure ()
assertLeft result = assertFailure ("Expected refusal: " <> show result)
