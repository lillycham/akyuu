{-# LANGUAGE GHC2021 #-}
{-# LANGUAGE OverloadedStrings #-}

-- Compile with cabal exec -- ghc -O2 -threaded -rtsopts -package akyuu
-- -outputdir /tmp/akyuu-sync-bench-build -o /tmp/akyuu-sync-bench bench/SyncV1.hs.
-- Fixtures are synthetic, deterministic, and confined to a new destination.
module Main (main) where

import Akyuu.Fs (AtomicStep (TemporaryWritten))
import Akyuu.Graph (Edge (Edge), EdgeType (DerivedFrom, Follows))
import Akyuu.Id qualified as Id
import Akyuu.Memory (memoryId, mkMemory, renderMemory)
import Akyuu.Ops (NewMemory (NewMemory))
import Akyuu.Refs (Name, mkName)
import Akyuu.Sync.Checkpoint (CheckpointId (CheckpointId), checkpointObjects, pendingEvents, pendingObjects)
import Akyuu.Sync.Context qualified as Context
import Akyuu.Sync.Event (Event, eventId, mkEvent)
import Akyuu.Sync.Logs qualified as Logs
import Akyuu.Sync.Repository qualified as Repo
import Akyuu.Sync.Search qualified as Search
import Akyuu.Sync.State qualified as State
import Akyuu.Sync.Topics qualified as Topics
import Akyuu.Sync.Types (Action (AppendLog, RegisterReplica, SetTopic), Identifier, Nonce (Nonce), ReplicaId (ReplicaId), Resource, StoreId (StoreId), mkIdentifier, resourceOf)
import Control.Concurrent (forkFinally, newEmptyMVar, putMVar, readMVar, takeMVar)
import Control.Exception (evaluate, throwIO)
import Control.Monad (forM, unless)
import Data.Aeson (Value, encode, object, (.=))
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BL
import Data.IORef (atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.List (sort)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (encodeUtf8)
import Data.Time (UTCTime, addUTCTime)
import GHC.Clock (getMonotonicTimeNSec)
import System.Directory (doesPathExist)
import System.Environment (getArgs)
import System.FilePath ((</>))
import System.IO (hPutStrLn, stderr)
import System.Timeout (timeout)

checked :: (Show e) => Either e a -> IO a
checked = either (ioError . userError . show) pure

name :: Text -> Name
name = either (error . show) id . mkName

stamp :: UTCTime
stamp = read "2026-01-01 00:00:00 UTC"

identifier :: Int -> Identifier
identifier n = either (error . T.unpack) id (mkIdentifier (BS.take 16 (Id.toBytes (Id.hashBytes (encodeUtf8 (T.pack (show n)))))))

data Build = Build [Event] [(Id.Id, BS.ByteString)] (Map.Map Resource Event) (Map.Map Name Id.Id)

requireFixture :: FilePath -> IO ()
requireFixture root = do
  marker <- BS.readFile (root </> ".tmp.benchmark")
  unless (marker == "akyuu-sync-benchmark-v1\n") (ioError (userError "This is not a disposable benchmark fixture."))

seed :: FilePath -> Int -> Text -> IO Value
seed root count profile = do
  exists <- doesPathExist root
  unless (not exists && count >= 40 && count <= 10000) (ioError (userError "Use a new destination and a size from 40 to 10000."))
  unless (profile `elem` ["compressible", "varied"]) (ioError (userError "Use the compressible or varied body profile."))
  let store = StoreId (identifier 0)
      replica = ReplicaId (identifier 1)
      registration = either (error . show) id (mkEvent store replica (Nonce (identifier 2)) Set.empty (RegisterReplica replica "Synthetic fixture") stamp)
      add k ref kind text edges action (Build priorEvents priorPayloads heads memories) =
        let memory = either (error . show) id (mkMemory kind (addUTCTime (fromIntegral k) stamp) "benchmark" edges text)
            digest = memoryId memory
            value = action ref digest
            resource = resourceOf value
            parents = maybe Set.empty (Set.singleton . eventId) (Map.lookup resource heads)
            event = either (error . show) id (mkEvent store replica (Nonce (identifier (k + 100))) parents value (addUTCTime (fromIntegral k) stamp))
         in Build (event : priorEvents) ((digest, renderMemory memory) : priorPayloads) (Map.insert resource event heads) (Map.insert ref digest memories)
      topicCount = count `div` 4
      body k =
        "benchmark marker "
          <> T.pack (show k)
          <> "\n"
          <> if profile == "compressible"
            then T.replicate 1000 "x"
            else T.take 1000 (T.concat [Id.render (Id.hashBytes (encodeUtf8 (T.pack (show (k, block))))) <> " A reproducible record retains its exact history. " | block <- [0 :: Int .. 10]])
      initial = Build [registration] [] Map.empty Map.empty
      controls =
        add
          1
          (name "policy/memory")
          "instruction"
          "Read exact summary evidence."
          Set.empty
          SetTopic
          (add 2 (name "policy/tiers") "config" "always: bench/topic-0 bench/log" Set.empty SetTopic initial)
      topics = foldl (\acc k -> add (k + 10) (name ("bench/topic-" <> T.pack (show (k `mod` 32)))) "fact" (body k) Set.empty SetTopic acc) controls [0 .. topicCount - 1]
      append acc k =
        let Build _ _ _ memories = acc
            edges = maybe Set.empty (Set.singleton . Edge Follows) (Map.lookup (name "bench/log") memories)
         in add (k + count + 10) (name "bench/log") "note" (body (k + count)) edges AppendLog acc
      logged@(Build _ logPayloads _ _) = foldl append topics [0 .. count - topicCount - 1]
      -- Take only episode IDs, in chronological order, before controls/topics.
      episodeIds = reverse (map fst (take (count - topicCount) logPayloads))
      batches xs
        | length xs >= 30 = take 20 xs : batches (drop 20 xs)
        | otherwise = []
      summarise acc (k, sources) =
        let Build _ _ _ memories = acc
            ref = name "bench/log.l1"
            edges = Set.fromList (map (Edge DerivedFrom) sources) <> maybe Set.empty (Set.singleton . Edge Follows) (Map.lookup ref memories)
         in add (3 * count + k + 10) ref "summary" ("Summary batch " <> T.pack (show k)) edges AppendLog acc
      Build events payloads _ _ = foldl summarise logged (zip [0 ..] (batches episodeIds))
      state = either (error . show) id (State.fromEvents store events)
  repo <- Repo.initialise root store >>= checked
  snapshot <- Repo.importState repo state payloads >>= checked
  _ <- Topics.initialiseLocal root "Benchmark writer" >>= checked
  BS.writeFile (root </> ".tmp.benchmark") "akyuu-sync-benchmark-v1\n"
  pure (object ["seed_entries" .= count, "body_profile" .= profile, "fixture_checkpoint" .= let CheckpointId digest = Repo.snapshotId snapshot in Id.render digest, "events" .= Map.size (State.events state), "objects" .= Set.size (checkpointObjects (Repo.snapshotCheckpoint snapshot)), "payload_bytes" .= sum (map (BS.length . snd) payloads)])

timed :: IO Value -> IO Double
timed action = do
  start <- getMonotonicTimeNSec
  value <- action
  _ <- evaluate (BL.length (encode value))
  end <- getMonotonicTimeNSec
  pure (fromIntegral (end - start) / 1000000)

measure :: FilePath -> Int -> Maybe Text -> IO Value
measure root samples wanted = do
  requireFixture root
  unless (samples >= 1 && samples <= 20) (ioError (userError "Use from 1 to 20 samples."))
  unless (maybe True (`elem` ["snapshot", "context", "search", "topic_replace", "archive", "commit_uncontended"]) wanted) (ioError (userError "Unknown benchmark operation."))
  local <- Topics.openLocal root >>= checked
  repo <- Repo.openRepository root >>= checked
  let options = Context.ContextOptions (name "policy/memory") (name "policy/tiers") "always" Nothing [] Logs.defaultPageOptions
      summary label values@(first : _) =
        let ordered = sort values
         in object ["operation" .= (label :: Text), "samples_ms" .= values, "first_ms" .= first, "median_ms" .= (ordered !! (length ordered `div` 2)), "max_ms" .= maximum values]
      summary _ [] = error "The validated sample count is positive."
      metric label action = do
        hPutStrLn stderr ("Measure " <> T.unpack label)
        values <- forM [1 .. samples] (\_ -> timed action)
        pure (summary label values)
      snapshot = do
        captured <- Repo.loadSnapshot repo >>= checked
        pure (object ["objects" .= Set.size (checkpointObjects (Repo.snapshotCheckpoint captured))])
      context = do
        report <- Context.configuredContext local options >>= checked
        unless (Context.contextReady report) (ioError (userError "The fixture context is not ready."))
        pure (Context.reportJSON report)
      search = Search.searchTopics local "benchmark" 20 >>= checked >>= pure . Search.searchJSON
      write = do
        before <- Topics.readTopic local (name "bench/topic-0") >>= checked
        view <- Topics.replaceTopic local (name "bench/topic-0") (Topics.viewVersion before) (NewMemory "fact" "benchmark" Set.empty ("benchmark marker changed\n" <> T.replicate 1000 "x") Set.empty) >>= checked
        pure (Topics.viewJSON view)
      archive = do
        captured <- Repo.loadSnapshot repo >>= checked
        _ <- Repo.archiveSnapshot repo captured >>= checked
        pure (object ["archived" .= True])
  let selected label = maybe True (== label) wanted
  results <- traverse (uncurry metric) (filter (selected . fst) [("snapshot", snapshot), ("context", context), ("search", search), ("topic_replace", write), ("archive", archive)])
  -- Prepare the event outside the clock. The transaction includes inventory
  -- validation outside the mutation lock, acquisition, retries and publication.
  -- This measures operation latency, not the lock's held duration.
  commits <- forM (if selected "commit_uncontended" then [1 .. samples] else []) $ \_ -> do
    captured <- Repo.loadSnapshot repo >>= checked
    let state = Repo.snapshotState captured
        memory = either (error . show) id (mkMemory "fact" stamp "benchmark" Set.empty ("benchmark commit " <> T.pack (show (Map.size (State.events state))) <> "\n" <> T.replicate 1000 "x"))
        action = SetTopic (name "bench/commit") (memoryId memory)
        resource = resourceOf action
        event = either (error . show) id (mkEvent (State.storeId state) (ReplicaId (identifier 1)) (Nonce (identifier (100000 + Map.size (State.events state)))) (Map.keysSet (State.resourceHeads state resource)) action stamp)
    timed $ do
      _ <- Repo.commitLocal repo (State.version state resource) event [(memoryId memory, renderMemory memory)] >>= checked
      pure (object ["committed" .= True])
  pure (object ["samples" .= samples, "metrics" .= (results <> if null commits then [] else [summary "commit_uncontended" commits])])

-- Two independent resources start at a shared barrier. A successful first
-- commit must not invalidate the other resource's optimistic version.
race :: FilePath -> IO Value
race root = do
  requireFixture root
  repo <- Repo.openRepository root >>= checked
  captured <- Repo.loadSnapshot repo >>= checked
  let state = Repo.snapshotState captured
      prepare k =
        let ref = name ("bench/race-" <> T.pack (show k))
            memory = either (error . show) id (mkMemory "fact" stamp "benchmark" Set.empty ("race " <> T.pack (show k) <> "\n" <> T.replicate 1000 "x"))
            action = SetTopic ref (memoryId memory)
            resource = resourceOf action
            event = either (error . show) id (mkEvent (State.storeId state) (ReplicaId (identifier 1)) (Nonce (identifier (200000 + 4 * Map.size (State.events state) + k))) (Map.keysSet (State.resourceHeads state resource)) action stamp)
         in (resource, event, memory)
  gate <- newEmptyMVar
  workers <- forM [1, 2] $ \k -> do
    ready <- newEmptyMVar
    done <- newEmptyMVar
    let (resource, event, memory) = prepare k
    _ <- evaluate (BS.length (renderMemory memory))
    _ <-
      forkFinally
        ( do
            putMVar ready ()
            _ <- readMVar gate
            start <- getMonotonicTimeNSec
            result <- Repo.commitLocal repo (State.version state resource) event [(memoryId memory, renderMemory memory)]
            end <- getMonotonicTimeNSec
            pure (event, result, fromIntegral (end - start) / 1000000 :: Double)
        )
        (putMVar done)
    pure (ready, done)
  mapM_ (takeMVar . fst) workers
  putMVar gate ()
  results <- traverse (\(_, done) -> takeMVar done >>= either throwIO pure) workers
  after <- Repo.loadSnapshot repo >>= checked
  attempts <- forM results $ \(event, result, ms) -> do
    success <- case result of
      Right _ -> pure True
      Left Repo.RepositoryBusy -> pure False
      Left err -> ioError (userError (show err))
    unless (Map.member (eventId event) (State.events (Repo.snapshotState after)) == success) (ioError (userError "The concurrent commit result disagrees with accepted state."))
    pure (object ["success" .= success, "ms" .= ms, "busy" .= not success])
  pure (object ["attempts" .= attempts])

-- Hold archive preparation at its first payload write while an ordinary topic
-- writer runs. The enclosing archive timer intentionally includes that writer.
archiveWriter :: FilePath -> IO Value
archiveWriter root = do
  requireFixture root
  exists <- doesPathExist (root </> "archive")
  unless (not exists) (ioError (userError "Use a fresh fixture without an archive."))
  repo <- Repo.openRepository root >>= checked
  local <- Topics.openLocal root >>= checked
  captured <- Repo.loadSnapshot repo >>= checked
  waiting <- newIORef True
  measured <- newIORef Nothing
  let hook (Repo.WriteBoundary (Repo.ArchiveMemoryFile _) TemporaryWritten) = do
        first <- atomicModifyIORef' waiting (\value -> (False, value))
        if not first
          then pure ()
          else do
            ms <- timed $ do
              before <- Topics.readTopic local (name "bench/topic-0") >>= checked
              after <- Topics.replaceTopic local (name "bench/topic-0") (Topics.viewVersion before) (NewMemory "fact" "benchmark" Set.empty "written while archive preparation is paused" Set.empty) >>= checked
              pure (Topics.viewJSON after)
            writeIORef measured (Just ms)
      hook _ = pure ()
  total <- timed $ do
    key <- Repo.archiveSnapshotWith hook repo captured >>= checked
    pure (object ["checkpoint" .= let CheckpointId digest = key in Id.render digest])
  writer <- readIORef measured >>= maybe (ioError (userError "The archive barrier was not reached.")) pure
  after <- Repo.acknowledgePublished repo (Repo.snapshotId captured) >>= checked
  unless (Set.size (pendingObjects (Repo.snapshotCheckpoint after)) == 1 && Set.size (pendingEvents (Repo.snapshotCheckpoint after)) == 1) (ioError (userError "Archive acknowledgement lost the later write obligation."))
  pure (object ["writer_ms" .= writer, "archive_including_paused_writer_ms" .= total, "later_write_pending" .= True])

main :: IO ()
main = do
  args <- getArgs
  result <- timeout 120000000 $ case args of
    ["seed", root, count] -> seed root (read count) "compressible"
    ["seed", root, count, profile] -> seed root (read count) (T.pack profile)
    ["measure", root, samples] -> measure root (read samples) Nothing
    ["metric", root, operation, samples] -> measure root (read samples) (Just (T.pack operation))
    ["race", root] -> race root
    ["archive-writer", root] -> archiveWriter root
    _ -> ioError (userError "Use seed NEW_ROOT COUNT [BODY], measure ROOT SAMPLES, metric ROOT OPERATION SAMPLES, race ROOT, or archive-writer ROOT.")
  maybe (ioError (userError "The experiment exceeded its 120-second deadline.")) (BL.putStr . (<> "\n") . encode) result
