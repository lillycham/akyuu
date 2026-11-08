{-# LANGUAGE OverloadedStrings #-}

module RepositoryTests (repositoryTests) where

import Akyuu.Fs (AtomicStep (DirectorySynced, FileSynced, Renamed, TemporaryWritten))
import Akyuu.Graph (Edge (Edge), EdgeType (About, Supersedes))
import Akyuu.Id (Id)
import Akyuu.Id qualified as Id
import Akyuu.Memory (Memory, memoryId, mkMemory, renderMemory)
import Akyuu.Refs (Name, mkName)
import Akyuu.Sync.Checkpoint (CheckpointId (CheckpointId), checkpointEvents, checkpointObjects, evictedObjects, pendingEvents, pendingObjects)
import Akyuu.Sync.Checkpoint qualified as Checkpoint
import Akyuu.Sync.Event (Event, eventId, mkEvent, renderEvent)
import Akyuu.Sync.Event qualified as Event
import Akyuu.Sync.Repository (Boundary (DirectoryCreated, SnapshotValidated, WriteBoundary), Repository, RepositoryError (CorruptData, IdentityMismatch, InvalidPointer, InvalidState, MissingCurrent, MissingPayload, MissingRetainedTarget, NotRepository, PublicationUncertain, RepositoryBusy, RepositoryIO, UnacceptedObject), Snapshot, WriteTarget (CheckpointFile, CurrentFile, EventFile, IdentityFile, MemoryFile), acknowledgePublished, archiveSnapshot, collect, commitLocal, commitLocalWith, importState, initialise, initialiseWith, loadSnapshot, openRepository, readMemory, snapshotCheckpoint, snapshotId, snapshotState)
import Akyuu.Sync.Repository qualified as Repository
import Akyuu.Sync.State (StateError (StaleVersion))
import Akyuu.Sync.State qualified as State
import Akyuu.Sync.Types (Action (RegisterReplica, SetTopic), EventId (EventId), Nonce (Nonce), ReplicaId (ReplicaId), Resource (RefResource, RegistryResource), StoreId (StoreId), mkIdentifier)
import Control.Concurrent (forkIO, newEmptyMVar, putMVar, takeMVar)
import Control.Monad (void, when)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime (UTCTime), fromGregorian)
import Support (right, withTempDir)
import System.Directory (canonicalizePath, createDirectory, doesFileExist, listDirectory, removeFile)
import System.Exit (ExitCode (ExitFailure))
import System.FilePath ((</>))
import System.Posix.Files (setFileSize)
import System.Posix.Process (ProcessStatus (Exited), exitImmediately, forkProcess, getProcessStatus)
import System.Posix.Signals (sigKILL, signalProcess)
import System.Timeout (timeout)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

repositoryTests :: TestTree
repositoryTests = testGroup "Akyuu.Sync.Repository" [basicTests, validationTests, oversizedTests, publicationTests, preflightTests, crashTests, initialisationCrashTests]

oversizedTests :: TestTree
oversizedTests =
  testGroup
    "bounded inventory reads"
    [ testCase directory $ withRepository $ \root repo before -> do
        accepted <- writeFirst repo before >>= right
        let CheckpointId checkpoint = snapshotId accepted
            EventId registrationId = eventId registration
            (digest, limit) = case directory of
              "objects" -> (memoryId (memory "first"), Repository.maxPayloadBytes)
              "events" -> (registrationId, Event.maxEventBytes)
              _ -> (checkpoint, Checkpoint.maxCheckpointBytes)
            path = root </> directory </> digestName digest
        setFileSize path (fromIntegral limit + 100)
        canonical <- canonicalizePath path
        loadSnapshot repo >>= (@?= Left (Repository.OversizedData canonical))
    | directory <- ["objects", "events", "checkpoints"]
    ]

must :: (Show e) => Either e a -> a
must = either (error . show) id

store :: StoreId
store = StoreId (must (mkIdentifier (BS.replicate 16 0)))

replica :: ReplicaId
replica = ReplicaId (must (mkIdentifier (BS.replicate 16 1)))

time :: UTCTime
time = UTCTime (fromGregorian 2026 11 1) 0

name :: Name
name = must (mkName "me/topic")

event :: Int -> [Event] -> Action -> Event
event nonce parents action = must (mkEvent store replica (Nonce (must (mkIdentifier (BS.replicate 16 (fromIntegral nonce))))) (Set.fromList (map eventId parents)) action time)

registration :: Event
registration = event 1 [] (RegisterReplica replica "test")

memory :: Text -> Memory
memory body = must (mkMemory "fact" time "test" Set.empty body)

payload :: Memory -> (Id, ByteString)
payload value = (memoryId value, renderMemory value)

topicEvent :: Event
topicEvent = event 2 [] (SetTopic name (memoryId (memory "first")))

withRepository :: (FilePath -> Repository -> Snapshot -> IO a) -> IO a
withRepository action = withTempDir $ \root -> do
  repo <- initialise root store >>= right
  start <- loadSnapshot repo >>= right
  registered <- commitLocal repo (State.version (snapshotState start) RegistryResource) registration [] >>= right
  action root repo registered

writeFirst :: Repository -> Snapshot -> IO (Either RepositoryError Snapshot)
writeFirst repo before = commitLocal repo (State.version (snapshotState before) (RefResource name)) topicEvent [payload (memory "first")]

basicTests :: TestTree
basicTests =
  testGroup
    "publication and outbox"
    [ testCase "empty initialisation is repeatable" $ withTempDir $ \root -> do
        repo <- initialise root store >>= right
        before <- loadSnapshot repo >>= right
        initialise root store >>= (@?= Right repo)
        reopen <- openRepository root >>= right
        after <- loadSnapshot reopen >>= right
        snapshotId before @?= snapshotId after,
      testCase "accepted payload and event survive reopening" $ withRepository $ \root repo before -> do
        accepted <- writeFirst repo before >>= right
        reopened <- openRepository root >>= right
        recovered <- loadSnapshot reopened >>= right
        recovered @?= accepted
        readMemory recovered (memoryId (memory "first")) >>= (@?= Right (memory "first"))
        pendingEvents (snapshotCheckpoint recovered) @?= Set.fromList [eventId registration, eventId topicEvent]
        pendingObjects (snapshotCheckpoint recovered) @?= Set.singleton (memoryId (memory "first")),
      testCase "old captured snapshot cannot see a later object" $ withRepository $ \_ repo before -> do
        _ <- writeFirst repo before >>= right
        readMemory before (memoryId (memory "first")) >>= (@?= Left (UnacceptedObject (memoryId (memory "first")))),
      testCase "intermediate versions stay in the outbox" $ withRepository $ \_ repo before -> do
        first <- writeFirst repo before >>= right
        let next = event 3 [topicEvent] (SetTopic name (memoryId (memory "second")))
        second <- commitLocal repo (State.version (snapshotState first) (RefResource name)) next [payload (memory "second")] >>= right
        pendingObjects (snapshotCheckpoint second) @?= Set.fromList [memoryId (memory "first"), memoryId (memory "second")]
        pendingEvents (snapshotCheckpoint second) @?= Set.fromList [eventId registration, eventId topicEvent, eventId next],
      testCase "import merges with the latest local state" $ withRepository $ \_ repo before -> do
        let remoteName = must (mkName "me/remote")
            remote = event 5 [] (SetTopic remoteName (memoryId (memory "remote")))
            incoming = must (State.fromEvents store [registration, remote])
        first <- writeFirst repo before >>= right
        imported <- importState repo incoming [payload (memory "remote")] >>= right
        Map.keysSet (State.events (snapshotState imported)) @?= Set.insert (eventId remote) (Map.keysSet (State.events (snapshotState first)))
        pendingEvents (snapshotCheckpoint imported) @?= checkpointEvents (snapshotCheckpoint imported),
      testCase "orphan directories and files never become accepted state" $ withRepository $ \root repo before -> do
        BS.writeFile (root </> "objects" </> digestName (memoryId (memory "orphan"))) (renderMemory (memory "orphan"))
        BS.writeFile (root </> "events" </> eventName topicEvent) (renderEvent topicEvent)
        BS.writeFile (root </> "CURRENT.tmp") "incomplete"
        after <- loadSnapshot repo >>= right
        after @?= before
        readMemory after (memoryId (memory "orphan")) >>= (@?= Left (UnacceptedObject (memoryId (memory "orphan"))))
    ]

validationTests :: TestTree
validationTests =
  testGroup
    "reject invalid publication"
    [ testCase "legacy or unrelated directories are refused" $ withTempDir $ \root -> do
        createDirectory (root </> "store")
        initialise root store >>= (@?= Left NotRepository)
        doesFileExist (root </> "IDENTITY") >>= (@?= False),
      testCase "different identity cannot reinitialise the repository" $ withTempDir $ \root -> do
        _ <- initialise root store >>= right
        let other = StoreId (must (mkIdentifier (BS.replicate 16 9)))
        initialise root other >>= (@?= Left IdentityMismatch),
      testCase "missing direct payload leaves CURRENT unchanged" $ withRepository $ \_ repo before -> do
        commitLocal repo (State.version (snapshotState before) (RefResource name)) topicEvent [] >>= (@?= Left (MissingPayload (memoryId (memory "first"))))
        loadSnapshot repo >>= (@?= Right before),
      testCase "wrong payload hash leaves CURRENT unchanged" $ withRepository $ \_ repo before -> do
        result <- commitLocal repo (State.version (snapshotState before) (RefResource name)) topicEvent [(memoryId (memory "first"), renderMemory (memory "different"))]
        assertBool "corrupt payload accepted" (isLeft result)
        loadSnapshot repo >>= (@?= Right before),
      testCase "a matching hash does not bypass canonical memory validation" $ withRepository $ \_ repo before -> do
        let bytes = "not a memory"; bad = event 9 [] (SetTopic name (Id.hashBytes bytes))
        result <- commitLocal repo (State.version (snapshotState before) (RefResource name)) bad [(Id.hashBytes bytes, bytes)]
        assertBool "invalid memory accepted" (isLeft result)
        loadSnapshot repo >>= (@?= Right before),
      testCase "retaining edges require their payloads" $ withRepository $ \_ repo before -> do
        let dependency = memory "dependency"
            value = must (mkMemory "fact" time "test" (Set.singleton (Edge About (memoryId dependency))) "retains")
            next = event 9 [] (SetTopic name (memoryId value))
        commitLocal repo (State.version (snapshotState before) (RefResource name)) next [payload value] >>= (@?= Left (MissingRetainedTarget (memoryId value) (memoryId dependency)))
        _ <- commitLocal repo (State.version (snapshotState before) (RefResource name)) next [payload value, payload dependency] >>= right
        pure (),
      testCase "supersession can name collected history" $ withRepository $ \_ repo before -> do
        let value = must (mkMemory "fact" time "test" (Set.singleton (Edge Supersedes (Id.hashBytes "collected"))) "new")
            next = event 9 [] (SetTopic name (memoryId value))
        _ <- commitLocal repo (State.version (snapshotState before) (RefResource name)) next [payload value] >>= right
        pure (),
      testCase "stale write creates no preparations" $ withRepository $ \root repo before -> do
        first <- writeFirst repo before >>= right
        let next = event 3 [] (SetTopic name (memoryId (memory "second")))
        commitLocal repo (State.version (snapshotState before) (RefResource name)) next [payload (memory "second")] >>= (@?= Left (InvalidState StaleVersion))
        listDirectory (root </> "objects") >>= (@?= [digestName (memoryId (memory "first"))])
        loadSnapshot repo >>= (@?= Right first),
      testCase "corrupt accepted payload is never silently repaired" $ withRepository $ \root repo before -> do
        canonicalRoot <- canonicalizePath root
        accepted <- writeFirst repo before >>= right
        BS.writeFile (root </> "objects" </> digestName (memoryId (memory "first"))) "corrupt"
        result <- loadSnapshot repo
        assertBool "corruption hidden" (isLeft result)
        readMemory accepted (memoryId (memory "first")) >>= (@?= Left (CorruptData (canonicalRoot </> "objects" </> digestName (memoryId (memory "first")))))
        let next = event 3 [topicEvent] (SetTopic name (memoryId (memory "second")))
        commitLocal repo (State.version (snapshotState accepted) (RefResource name)) next [payload (memory "second")] >>= assertLeft
        importState repo (snapshotState accepted) [payload (memory "first")] >>= assertLeft
        BS.readFile (root </> "objects" </> digestName (memoryId (memory "first"))) >>= (@?= "corrupt"),
      testCase "malformed CURRENT never resets the repository" $ withRepository $ \root repo _ -> do
        BS.writeFile (root </> "CURRENT") "bad\n"
        loadSnapshot repo >>= assertLeft
        initialise root store >>= assertLeft
        BS.readFile (root </> "CURRENT") >>= (@?= "bad\n"),
      testCase "missing CURRENT with accepted data never resets the repository" $ withRepository $ \root repo before -> do
        _ <- writeFirst repo before >>= right
        removeFile (root </> "CURRENT")
        initialise root store >>= (@?= Left MissingCurrent)
        doesFileExist (root </> "CURRENT") >>= (@?= False),
      testCase "corrupt accepted event is refused" $ withRepository $ \root repo before -> do
        BS.writeFile (root </> "events" </> eventName registration) "corrupt"
        loadSnapshot repo >>= assertLeft
        writeFirst repo before >>= assertLeft
        importState repo (snapshotState before) [] >>= assertLeft,
      testCase "corrupt checkpoint is refused" $ withRepository $ \root repo before -> do
        let CheckpointId digest = snapshotId before
        BS.writeFile (root </> "checkpoints" </> digestName digest) "corrupt"
        loadSnapshot repo >>= assertLeft
    ]

publicationTests :: TestTree
publicationTests =
  testGroup
    "publication failures and races"
    [ testCase "I/O error after pointer rename reports uncertain publication" $ withRepository $ \_ repo before -> do
        let hook boundary = when (boundary == WriteBoundary CurrentFile Renamed) (ioError (userError "injected"))
        result <- commitLocalWith hook repo (State.version (snapshotState before) (RefResource name)) topicEvent [payload (memory "first")]
        case result of
          Left (PublicationUncertain key _) -> do
            recovered <- loadSnapshot repo >>= right
            snapshotId recovered @?= key
            assertBool "new event lost" (Map.member (eventId topicEvent) (State.events (snapshotState recovered)))
          _ -> assertFailure ("Expected uncertain publication, got " <> show result),
      testCase "pre-publication I/O error keeps accepted state unchanged" $ withRepository $ \_ repo before -> do
        let hook boundary = case boundary of
              WriteBoundary (CheckpointFile _) DirectorySynced -> ioError (userError "injected")
              _ -> pure ()
        commitLocalWith hook repo (State.version (snapshotState before) (RefResource name)) topicEvent [payload (memory "first")] >>= assertLeft
        loadSnapshot repo >>= (@?= Right before)
        retried <- writeFirst repo before >>= right
        readMemory retried (memoryId (memory "first")) >>= (@?= Right (memory "first")),
      testCase "concurrent writes with one version accept exactly one" $ withRepository $ \_ repo before -> do
        ready <- newEmptyMVar
        resultA <- newEmptyMVar
        resultB <- newEmptyMVar
        let token = State.version (snapshotState before) (RefResource name)
            other = event 4 [] (SetTopic name (memoryId (memory "other")))
        void (forkIO (takeMVar ready >> writeFirst repo before >>= putMVar resultA))
        void (forkIO (takeMVar ready >> commitLocal repo token other [payload (memory "other")] >>= putMVar resultB))
        putMVar ready ()
        putMVar ready ()
        results <- timeout 5000000 ((,) <$> takeMVar resultA <*> takeMVar resultB)
        case results of
          Just (Right _, Left (InvalidState StaleVersion)) -> pure ()
          Just (Left (InvalidState StaleVersion), Right _) -> pure ()
          _ -> assertFailure ("Unexpected race outcome: " <> show results)
    ]

preflightTests :: TestTree
preflightTests =
  testGroup "optimistic inventory validation" $
    [ testCase "retry handles a checkpoint with a smaller event inventory" $ withRepository $ \root repo before -> do
        original <- BS.readFile (root </> "CURRENT")
        _ <- writeFirst repo before >>= right
        attempts <- newIORef (0 :: Int)
        let otherName = must (mkName "me/independent")
            proposal = event 4 [] (SetTopic otherName (memoryId (memory "independent")))
            hook (SnapshotValidated _) = do
              n <- atomicModifyIORef' attempts (\n -> (n + 1, n + 1))
              when (n == 1) (BS.writeFile (root </> "CURRENT") original)
            hook _ = pure ()
        after <- commitLocalWith hook repo (State.version (snapshotState before) (RefResource otherName)) proposal [payload (memory "independent")] >>= right
        readIORef attempts >>= (@?= 2)
        Map.keysSet (State.events (snapshotState after)) @?= Set.fromList [eventId registration, eventId proposal]
        checkpointObjects (snapshotCheckpoint after) @?= Set.singleton (memoryId (memory "independent")),
      testCase "an independent writer between validation and locking survives retry" $ withRepository $ \_ repo before -> do
        attempts <- newIORef (0 :: Int)
        let otherName = must (mkName "me/independent")
            other = event 4 [] (SetTopic otherName (memoryId (memory "independent")))
            hook (SnapshotValidated _) = do
              n <- atomicModifyIORef' attempts (\n -> (n + 1, n + 1))
              when (n == 1) (void (commitLocal repo (State.version (snapshotState before) (RefResource otherName)) other [payload (memory "independent")] >>= right))
            hook _ = pure ()
        after <- commitLocalWith hook repo (State.version (snapshotState before) (RefResource name)) topicEvent [payload (memory "first")] >>= right
        readIORef attempts >>= (@?= 2)
        assertBool "the retry lost an independent write" (all (\key -> Map.member key (State.events (snapshotState after))) [eventId other, eventId topicEvent]),
      testCase "a competing target write still rejects the stale version" $ withRepository $ \root repo before -> do
        attempts <- newIORef (0 :: Int)
        let proposal = event 4 [] (SetTopic name (memoryId (memory "rejected")))
            hook (SnapshotValidated _) = do
              n <- atomicModifyIORef' attempts (\n -> (n + 1, n + 1))
              when (n == 1) (void (writeFirst repo before >>= right))
            hook _ = pure ()
        commitLocalWith hook repo (State.version (snapshotState before) (RefResource name)) proposal [payload (memory "rejected")] >>= (@?= Left (InvalidState StaleVersion))
        readIORef attempts >>= (@?= 2)
        doesFileExist (root </> "objects" </> digestName (memoryId (memory "rejected"))) >>= (@?= False),
      testCase "continuous checkpoint changes stop after three validations" $ withRepository $ \root repo before -> do
        attempts <- newIORef (0 :: Int)
        let otherName = must (mkName "me/independent")
            resource = RefResource otherName
            hook (SnapshotValidated _) = do
              n <- atomicModifyIORef' attempts (\n -> (n + 1, n + 1))
              current <- loadSnapshot repo >>= right
              let state = snapshotState current
                  value = memory ("independent " <> T.pack (show n))
                  next = event (20 + n) (Map.elems (State.resourceHeads state resource)) (SetTopic otherName (memoryId value))
              void (commitLocal repo (State.version state resource) next [payload value] >>= right)
            hook _ = pure ()
        commitLocalWith hook repo (State.version (snapshotState before) (RefResource name)) topicEvent [payload (memory "first")] >>= (@?= Left RepositoryBusy)
        readIORef attempts >>= (@?= 3)
        doesFileExist (root </> "objects" </> digestName (memoryId (memory "first"))) >>= (@?= False)
        after <- loadSnapshot repo >>= right
        Map.size (State.events (snapshotState after)) @?= 4,
      testCase "GC between validation and locking preserves eviction on retry" $ withRepository $ \_ repo before -> do
        first <- writeFirst repo before >>= right
        let secondEvent = event 3 [topicEvent] (SetTopic name (memoryId (memory "second")))
        second <- commitLocal repo (State.version (snapshotState first) (RefResource name)) secondEvent [payload (memory "second")] >>= right
        key <- archiveSnapshot repo second >>= right
        published <- acknowledgePublished repo key >>= right
        attempts <- newIORef (0 :: Int)
        let otherName = must (mkName "me/independent")
            proposal = event 4 [] (SetTopic otherName (memoryId (memory "third")))
            hook (SnapshotValidated _) = do
              n <- atomicModifyIORef' attempts (\n -> (n + 1, n + 1))
              when (n == 1) (void (collect repo (snapshotId published) 1 >>= right))
            hook _ = pure ()
        after <- commitLocalWith hook repo (State.version (snapshotState published) (RefResource otherName)) proposal [payload (memory "third")] >>= right
        readIORef attempts >>= (@?= 2)
        evictedObjects (snapshotCheckpoint after) @?= Set.singleton (memoryId (memory "first"))
        readMemory after (memoryId (memory "first")) >>= (@?= Right (memory "first")),
      testCase "acknowledgement between validation and locking stays acknowledged" $ withRepository $ \_ repo before -> do
        first <- writeFirst repo before >>= right
        key <- archiveSnapshot repo first >>= right
        attempts <- newIORef (0 :: Int)
        let otherName = must (mkName "me/independent")
            proposal = event 4 [] (SetTopic otherName (memoryId (memory "second")))
            hook (SnapshotValidated _) = do
              n <- atomicModifyIORef' attempts (\n -> (n + 1, n + 1))
              when (n == 1) (void (acknowledgePublished repo key >>= right))
            hook _ = pure ()
        after <- commitLocalWith hook repo (State.version (snapshotState first) (RefResource otherName)) proposal [payload (memory "second")] >>= right
        readIORef attempts >>= (@?= 2)
        pendingEvents (snapshotCheckpoint after) @?= Set.singleton (eventId proposal)
        pendingObjects (snapshotCheckpoint after) @?= Set.singleton (memoryId (memory "second"))
    ]
      <> [ testGroup
             "retry disk integrity"
             [ testCase (directory <> if delete then " missing" else " corrupt") $ withRepository $ \root repo before -> do
                 first <- writeFirst repo before >>= right
                 attempts <- newIORef (0 :: Int)
                 let otherName = must (mkName "me/independent")
                     other = event 4 [] (SetTopic otherName (memoryId (memory "independent")))
                     proposal = event 5 [topicEvent] (SetTopic name (memoryId (memory "proposal")))
                     path = root </> directory </> filename
                     hook (SnapshotValidated _) = do
                       n <- atomicModifyIORef' attempts (\n -> (n + 1, n + 1))
                       when (n == 1) $ do
                         _ <- commitLocal repo (State.version (snapshotState first) (RefResource otherName)) other [payload (memory "independent")] >>= right
                         if delete then removeFile path else BS.writeFile path "corrupt"
                     hook _ = pure ()
                 result <- commitLocalWith hook repo (State.version (snapshotState first) (RefResource name)) proposal [payload (memory "proposal")]
                 case result of
                   Left (RepositoryIO _) | delete -> pure ()
                   Left (CorruptData actual) | not delete -> canonicalizePath path >>= (@?= actual)
                   _ -> assertFailure ("retry hid damaged inventory: " <> show result)
                 readIORef attempts >>= (@?= 1)
                 doesFileExist (root </> "objects" </> digestName (memoryId (memory "proposal"))) >>= (@?= False)
             | (directory, filename) <- [("objects", digestName (memoryId (memory "first"))), ("events", let EventId digest = eventId topicEvent in digestName digest)],
               delete <- [False, True]
             ],
           testGroup
             "publication marker rechecks"
             [ testCase marker $ withRepository $ \root repo before -> do
                 current <- BS.readFile (root </> "CURRENT")
                 let hook (SnapshotValidated _) = BS.writeFile (root </> marker) "invalid\n"
                     hook _ = pure ()
                 commitLocalWith hook repo (State.version (snapshotState before) (RefResource name)) topicEvent [payload (memory "first")] >>= (@?= Left expected)
                 doesFileExist (root </> "objects" </> digestName (memoryId (memory "first"))) >>= (@?= False)
                 when (marker == "IDENTITY") (BS.readFile (root </> "CURRENT") >>= (@?= current))
             | (marker, expected) <- [("IDENTITY", IdentityMismatch), ("CURRENT", InvalidPointer)]
             ]
         ]

-- exitImmediately bypasses Haskell finalizers. The OS releases the mutation
-- lock, while temporary files and durable preparations can remain on disk.
crashTests :: TestTree
crashTests =
  testGroup
    "process death at every commit boundary"
    [ testCase (label <> " / " <> show step) $ withRepository $ \root repo before -> do
        dies $
          commitLocalWith
            (\boundary -> when (matches boundary) (exitImmediately (ExitFailure 77)))
            repo
            (State.version (snapshotState before) (RefResource name))
            topicEvent
            [payload (memory "first")]
        reopened <- openRepository root >>= right
        recovered <- loadSnapshot reopened >>= right
        if label == "CURRENT" && step `elem` [Renamed, DirectorySynced]
          then do
            checkpointEvents (snapshotCheckpoint recovered) @?= Set.fromList [eventId registration, eventId topicEvent]
            pendingObjects (snapshotCheckpoint recovered) @?= Set.singleton (memoryId (memory "first"))
            readMemory recovered (memoryId (memory "first")) >>= (@?= Right (memory "first"))
          else do
            recovered @?= before
            readMemory recovered (memoryId (memory "first")) >>= (@?= Left (UnacceptedObject (memoryId (memory "first"))))
        -- Both a pre-publication retry and a new write after publication work.
        if snapshotId recovered == snapshotId before
          then void (writeFirst reopened recovered >>= right)
          else do
            let next = event 3 [topicEvent] (SetTopic name (memoryId (memory "second")))
            void (commitLocal reopened (State.version (snapshotState recovered) (RefResource name)) next [payload (memory "second")] >>= right)
    | label <- ["memory", "event", "checkpoint", "CURRENT"],
      step <- [TemporaryWritten, FileSynced, Renamed, DirectorySynced],
      let matches (WriteBoundary target actual) =
            actual == step && case (label, target) of
              ("memory", MemoryFile _) -> True
              ("event", EventFile _) -> True
              ("checkpoint", CheckpointFile _) -> True
              ("CURRENT", CurrentFile) -> True
              _ -> False
          matches _ = False
    ]

initialisationCrashTests :: TestTree
initialisationCrashTests =
  testGroup
    "initialisation recovery"
    ( [ testCase (show target <> " / " <> show step) $ withTempDir $ \parent -> do
          let root = parent </> "nested" </> "repository"
              hook boundary = when (boundary == WriteBoundary target step) (exitImmediately (ExitFailure 77))
          dies (initialiseWith hook root store)
          repo <- initialise root store >>= right
          recovered <- loadSnapshot repo >>= right
          checkpointEvents (snapshotCheckpoint recovered) @?= Set.empty
          checkpointObjects (snapshotCheckpoint recovered) @?= Set.empty
      | target <- [IdentityFile, CurrentFile],
        step <- [TemporaryWritten, FileSynced, Renamed, DirectorySynced]
      ]
        <> [ testCase "resume after mkdir before parent flush" $ withTempDir $ \parent -> do
               let root = parent </> "nested" </> "repository"
                   hook (DirectoryCreated _) = exitImmediately (ExitFailure 77)
                   hook _ = pure ()
               dies (initialiseWith hook root store)
               _ <- initialise root store >>= right
               pure ()
           ]
    )

dies :: IO a -> IO ()
dies action = do
  pid <- forkProcess (void action >> exitImmediately (ExitFailure 78))
  result <- timeout 5000000 (getProcessStatus True False pid)
  case result of
    Just (Just (Exited (ExitFailure 77))) -> pure ()
    Nothing -> do
      signalProcess sigKILL pid
      _ <- getProcessStatus True False pid
      assertFailure "Child did not reach the fault boundary within five seconds."
    _ -> assertFailure ("Unexpected child exit: " <> show result)

digestName :: Id -> FilePath
digestName = T.unpack . Id.render

eventName :: Event -> FilePath
eventName value = let EventId digest = eventId value in digestName digest

assertLeft :: (Show b) => Either a b -> IO ()
assertLeft (Left _) = pure ()
assertLeft (Right value) = assertFailure ("Unexpected success: " <> show value)

isLeft :: Either a b -> Bool
isLeft (Left _) = True
isLeft _ = False
