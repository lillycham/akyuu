-- | Experimental checkpoint storage, separate from the live v1 store. Only
-- CURRENT publishes state. Immutable preparations never count as accepted data.
module Akyuu.Sync.Repository
  ( Repository,
    Snapshot,
    RepositoryError (..),
    WriteTarget (..),
    Boundary (..),
    FaultHook,
    initialise,
    initialiseWith,
    openRepository,
    readStoreIdentity,
    loadSnapshot,
    verifyRepository,
    commitLocal,
    commitLocalChecked,
    commitLocalWith,
    importState,
    importStateWith,
    snapshotId,
    snapshotState,
    snapshotCheckpoint,
    readMemory,
    archiveSnapshot,
    archiveSnapshotWith,
    acknowledgePublished,
    acknowledgePublishedWith,
    CollectionPlan (..),
    planCollection,
    collect,
    collectWith,
    maxPayloadBytes,
    verifyIncoming,
    archiveIncoming,
  )
where

import Akyuu.Fs (AtomicStep (Renamed), atomicWriteWith, hGetBounded, ifMissing, ignoreIO, syncDir, tryWith)
import Akyuu.GC (retains)
import Akyuu.Graph (Edge (kind, target), EdgeType (Follows))
import Akyuu.Id (Id)
import Akyuu.Id qualified as Id
import Akyuu.Memory (Memory (memEdges), MemoryParseError, parseMemory)
import Akyuu.Mutation (withMutation)
import Akyuu.Sync.Checkpoint (Checkpoint, CheckpointError, CheckpointId (CheckpointId), activeObjects, checkpointEvents, checkpointId, checkpointObjects, checkpointStore, evictedObjects, maxCheckpointBytes, mkCheckpoint, parseCheckpoint, pendingEvents, pendingObjects, renderCheckpoint, withEvicted)
import Akyuu.Sync.Event (Event, maxEventBytes, renderEvent)
import Akyuu.Sync.Event qualified as Event
import Akyuu.Sync.Retention (actionPayloads, retained)
import Akyuu.Sync.State (State, StateError (StaleDependency), Version)
import Akyuu.Sync.State qualified as State
import Akyuu.Sync.Types (Action (AppendLog), EventId (EventId), Resource, StoreId (StoreId), parseIdentifier, renderIdentifier)
import Control.Exception (IOException)
import Control.Monad (forM_, join, unless, when)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Trans.Except (ExceptT (ExceptT), runExceptT, throwE)
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Foldable (traverse_)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Text.Encoding (decodeUtf8', encodeUtf8)
import System.Directory (canonicalizePath, createDirectory, doesDirectoryExist, getModificationTime, listDirectory, removeFile)
import System.FilePath (takeDirectory, (</>))
import System.IO (IOMode (ReadMode), hFileSize, withBinaryFile)
import System.IO.Error (isAlreadyExistsError)

data Repository = Repository FilePath StoreId deriving (Eq, Show)

data Snapshot = Snapshot FilePath Checkpoint State deriving (Eq, Show)

snapshotRoot :: Snapshot -> FilePath
snapshotRoot (Snapshot root _ _) = root

snapshotCheckpoint :: Snapshot -> Checkpoint
snapshotCheckpoint (Snapshot _ checkpoint _) = checkpoint

snapshotState :: Snapshot -> State
snapshotState (Snapshot _ _ state) = state

data RepositoryError
  = RepositoryIO IOException
  | RepositoryBusy
  | NotRepository
  | IdentityMismatch
  | InvalidPointer
  | MissingCurrent
  | MissingCheckpoint CheckpointId
  | InvalidCheckpoint CheckpointError
  | InvalidState StateError
  | CorruptData FilePath
  | OversizedData FilePath
  | InvalidMemory Id MemoryParseError
  | MissingPayload Id
  | MissingRetainedTarget Id Id
  | UnacceptedObject Id
  | MissingLogPredecessor EventId Id
  | StaleCheckpoint
  | InvalidRetentionDepth
  | ArchiveNotAccepted
  | CollectionIncomplete CheckpointId IOException
  | InvalidResidency
  | PublicationUncertain CheckpointId IOException
  deriving (Eq, Show)

data WriteTarget
  = IdentityFile
  | MemoryFile Id
  | EventFile EventId
  | CheckpointFile CheckpointId
  | CurrentFile
  | ArchiveMemoryFile Id
  | ArchiveEventFile EventId
  | ArchiveCheckpointFile CheckpointId
  deriving (Eq, Show)

data Boundary
  = DirectoryCreated FilePath
  | SnapshotValidated CheckpointId
  | WriteBoundary WriteTarget AtomicStep
  | MemoryEvicted Id
  | EvictionsSynced
  deriving (Eq, Show)

type FaultHook = Boundary -> IO ()

maxPayloadBytes :: Int
maxPayloadBytes = 16 * 1024 * 1024

snapshotId :: Snapshot -> CheckpointId
snapshotId = checkpointId . snapshotCheckpoint

initialise :: FilePath -> StoreId -> IO (Either RepositoryError Repository)
initialise = initialiseWith (const (pure ()))

-- | Initialisation can resume after interruption, but never adopts a nonempty
-- legacy directory or changes an existing repository's identity.
initialiseWith :: FaultHook -> FilePath -> StoreId -> IO (Either RepositoryError Repository)
initialiseWith hook path store = fmap join $ tryWith RepositoryIO $ do
  ensureDirectory hook path
  root <- canonicalizePath path
  let repo = Repository root store
  withMutation root RepositoryBusy RepositoryIO $ \_ -> runExceptT $ do
    identity <- liftIO (ifMissing Nothing (Just <$> boundedRead 256 (root </> "IDENTITY")))
    case identity of
      Nothing -> do
        entries <- liftIO (listDirectory root)
        unless (all (\entry -> entry `elem` ["store.lock", "sync.lock"] || ".tmp" `T.isPrefixOf` T.pack entry) entries) (throwE NotRepository)
        liftIO (atomicWriteWith (hook . WriteBoundary IdentityFile) (root </> "IDENTITY") (identityBytes store))
      Just bytes -> unless (bytes == identityBytes store) (throwE IdentityMismatch)
    liftIO (traverse_ (ensureDirectory hook . (root </>)) ["events", "objects", "checkpoints"])
    current <- liftIO (ifMissing Nothing (Just <$> boundedRead 128 (root </> "CURRENT")))
    case current of
      Just _ -> ExceptT (loadSnapshot repo) >> pure repo
      Nothing -> do
        checkpoint <- either (throwE . InvalidCheckpoint) pure (mkCheckpoint store Set.empty Set.empty Set.empty Set.empty)
        let CheckpointId initialId = checkpointId checkpoint
            isTemporary = T.isPrefixOf ".tmp" . T.pack
        objectFiles <- liftIO (listDirectory (root </> "objects"))
        eventFiles <- liftIO (listDirectory (root </> "events"))
        checkpointFiles <- liftIO (listDirectory (root </> "checkpoints"))
        -- Empty initialisation can resume. A missing pointer in a repository
        -- with transaction data is corruption, not permission to reset it.
        unless
          ( all isTemporary (objectFiles <> eventFiles)
              && all (\file -> isTemporary file || file == T.unpack (Id.render initialId)) checkpointFiles
          )
          (throwE MissingCurrent)
        saveCheckpoint hook repo checkpoint
        publishCurrent hook repo checkpoint
        pruneCheckpoints repo [checkpointId checkpoint]
        pure repo

openRepository :: FilePath -> IO (Either RepositoryError Repository)
openRepository path = fmap join $ tryWith RepositoryIO $ runExceptT $ do
  root <- liftIO (canonicalizePath path)
  bytes <- liftIO (boundedRead 256 (root </> "IDENTITY"))
  store <- either throwE pure (parseIdentity bytes)
  let repo = Repository root store
  _ <- ExceptT (loadSnapshot repo)
  pure repo

readStoreIdentity :: FilePath -> IO (Either RepositoryError StoreId)
readStoreIdentity root =
  fmap join $
    tryWith RepositoryIO $
      parseIdentity <$> boundedRead 256 (root </> "IDENTITY")

identityBytes :: StoreId -> ByteString
identityBytes (StoreId store) = "akyuu-sync-repository-v1\n" <> encodeUtf8 (renderIdentifier store) <> "\n"

parseIdentity :: ByteString -> Either RepositoryError StoreId
parseIdentity bytes = do
  text <- first (const NotRepository) (decodeUtf8' bytes)
  store <- case T.lines text of
    ["akyuu-sync-repository-v1", value] -> StoreId <$> first (const NotRepository) (parseIdentifier value)
    _ -> Left NotRepository
  unless (identityBytes store == bytes) (Left NotRepository)
  pure store

-- | Capture the accepted checkpoint. A load reads the manifest and the events,
-- and checks their hashes and the causal graph. It does not read payloads:
-- every payload was checked when it entered the repository, and 'readMemory'
-- checks the hash of each one that it returns. 'verifyRepository' is the
-- complete check of the files on disk.
loadSnapshot :: Repository -> IO (Either RepositoryError Snapshot)
loadSnapshot repo = loadSnapshotReusing repo Nothing

-- A retry keeps the decoded events of its earlier attempt. It still reads and
-- hashes every event file: a missing or corrupt copy must remain an error.
loadSnapshotReusing :: Repository -> Maybe Snapshot -> IO (Either RepositoryError Snapshot)
loadSnapshotReusing repo@(Repository root store) cached = fmap join $ tryWith RepositoryIO $ runExceptT $ do
  identity <- liftIO (boundedRead 256 (root </> "IDENTITY"))
  unless (identity == identityBytes store) (throwE IdentityMismatch)
  bytes <- readCurrentManifest repo (5 :: Int)
  checkpoint <- either (throwE . InvalidCheckpoint) pure (parseCheckpoint bytes)
  unless (checkpointStore checkpoint == store) (throwE IdentityMismatch)
  let previousState = case cached of
        Just old | Map.keysSet (State.events (snapshotState old)) `Set.isSubsetOf` checkpointEvents checkpoint -> snapshotState old
        _ -> State.empty store
  eventBytes <- traverse (\key@(EventId hash) -> (key,) <$> readChecked maxEventBytes (eventPath repo key) hash) (Set.toAscList (checkpointEvents checkpoint))
  let newBytes = filter (\(key, _) -> Map.notMember key (State.events previousState)) eventBytes
  state <- either (throwE . InvalidState) pure (State.extendBytes previousState newBytes)
  pure (Snapshot root checkpoint state)

-- | Read and check every accepted file: each event and payload hash, each
-- memory, each payload link, and the residency of evicted payloads. The cost
-- grows with the inventory. Collection uses it, because eviction acts on the
-- whole payload graph.
verifyRepository :: Repository -> IO (Either RepositoryError Snapshot)
verifyRepository repo = fmap (fmap fst) (loadSnapshotMemories repo)

loadSnapshotMemories :: Repository -> IO (Either RepositoryError (Snapshot, Map Id Memory))
loadSnapshotMemories repo = fmap join $ tryWith RepositoryIO $ runExceptT $ do
  snapshot <- ExceptT (loadSnapshot repo)
  let checkpoint = snapshotCheckpoint snapshot
      state = snapshotState snapshot
  memories <- loadMemories repo (checkpointObjects checkpoint)
  validatePayloads state memories
  unless (Set.null (evictedObjects checkpoint `Set.intersection` retained 1 checkpoint state memories)) (throwE InvalidResidency)
  pure (snapshot, memories)

-- A writer keeps the manifest that it replaced, and prunes older ones. A reader
-- that loses this race sees a missing manifest and a changed pointer: read the
-- pointer again. A missing manifest under an unchanged pointer is damage.
readCurrentManifest :: Repository -> Int -> ExceptT RepositoryError IO ByteString
readCurrentManifest repo@(Repository root _) tries = do
  digest <- pointerNow
  found <- ExceptT (ifMissing (Right Nothing) (fmap Just <$> runExceptT (readChecked maxCheckpointBytes (checkpointPath repo (CheckpointId digest)) digest)))
  case found of
    Just bytes -> pure bytes
    Nothing -> do
      later <- pointerNow
      if later /= digest && tries > 1
        then readCurrentManifest repo (tries - 1)
        else throwE (if later /= digest then RepositoryBusy else MissingCheckpoint (CheckpointId digest))
  where
    pointerNow = liftIO (boundedRead 128 (root </> "CURRENT")) >>= either throwE pure . parsePointer

parsePointer :: ByteString -> Either RepositoryError Id
parsePointer bytes = do
  text <- first (const InvalidPointer) (decodeUtf8' bytes)
  digest <- first (const InvalidPointer) (Id.parse (T.dropEnd 1 text))
  unless (encodeUtf8 (Id.render digest <> "\n") == bytes) (Left InvalidPointer)
  pure digest

commitLocal :: Repository -> Version -> Event -> [(Id, ByteString)] -> IO (Either RepositoryError Snapshot)
commitLocal = commitLocalWith (const (pure ()))

-- | Check read dependencies under the target's mutation lock.
commitLocalChecked :: Repository -> Version -> Event -> [(Id, ByteString)] -> [(Resource, Version)] -> IO (Either RepositoryError Snapshot)
commitLocalChecked repo expected event payloads checks = transact (const (pure ())) repo payloads $ \state -> do
  traverse_ (\(resource, token) -> unless (State.version state resource == token) (Left (InvalidState (StaleDependency resource)))) checks
  first InvalidState (State.applyLocal expected event state)

commitLocalWith :: FaultHook -> Repository -> Version -> Event -> [(Id, ByteString)] -> IO (Either RepositoryError Snapshot)
commitLocalWith hook repo expected event payloads = transact hook repo payloads $ \old ->
  first InvalidState (State.applyLocal expected event old)

-- | Merge into the latest checkpoint under the lock. Until transport supplies
-- verified publication receipts, all newly accepted events and objects stay pending.
importState :: Repository -> State -> [(Id, ByteString)] -> IO (Either RepositoryError Snapshot)
importState = importStateWith (const (pure ()))

importStateWith :: FaultHook -> Repository -> State -> [(Id, ByteString)] -> IO (Either RepositoryError Snapshot)
importStateWith hook repo incoming payloads = transact hook repo payloads (first InvalidState . (`State.merge` incoming))

-- | Load the checkpoint before taking the writer lock. A matching CURRENT and
-- identity bind that snapshot to publication. A changed pointer releases the
-- lock and retries from fresh disk state, at most three times.
-- Resource/dependency versions are still checked by advance under the lock.
-- The accepted inventory was checked when it entered. A transaction checks
-- what it adds: new events, new payloads, and their links into the inventory.
transact :: FaultHook -> Repository -> [(Id, ByteString)] -> (State -> Either RepositoryError State) -> IO (Either RepositoryError Snapshot)
transact hook repo@(Repository root store) payloads advance = fmap join $ tryWith RepositoryIO $ retry (3 :: Int) Nothing
  where
    retry 0 _ = pure (Left RepositoryBusy)
    retry remaining cached = runExceptT $ do
      old <- ExceptT (loadSnapshotReusing repo cached)
      liftIO (hook (SnapshotValidated (snapshotId old)))
      outcome <- ExceptT $ withMutation root RepositoryBusy RepositoryIO $ \_ -> runExceptT $ do
        identity <- liftIO (boundedRead 256 (root </> "IDENTITY"))
        unless (identity == identityBytes store) (throwE IdentityMismatch)
        pointer <- liftIO (boundedRead 128 (root </> "CURRENT"))
        digest <- either throwE pure (parsePointer pointer)
        if CheckpointId digest /= snapshotId old
          then pure Nothing
          else Just <$> persist old
      maybe (ExceptT (retry (remaining - 1) (Just old))) pure outcome
    persist old = do
      state <- either throwE pure (advance (snapshotState old))
      supplied <- Map.fromList <$> traverse verifyPayload payloads
      let previous = snapshotCheckpoint old
          objectIds = checkpointObjects previous <> Map.keysSet supplied
          eventIds = Map.keysSet (State.events state)
          newPayloads = Map.withoutKeys supplied (checkpointObjects previous)
          newEvents = Map.withoutKeys (State.events state) (checkpointEvents previous)
          memoryOf digest = maybe (readParsed repo digest) (pure . snd) (Map.lookup digest supplied)
      validateAdded memoryOf state objectIds newEvents (Map.map snd newPayloads)
      base <-
        either (throwE . InvalidCheckpoint) pure $
          mkCheckpoint
            store
            eventIds
            objectIds
            (pendingEvents previous <> (eventIds `Set.difference` checkpointEvents previous))
            (pendingObjects previous <> (objectIds `Set.difference` checkpointObjects previous))
      -- No evicted payload was retained at the old checkpoint. Only the roots
      -- that this transaction adds can newly retain one, so walk from those.
      let newRoots = Set.fromList (concatMap (actionPayloads . Event.eventAction) (Map.elems newEvents)) <> Map.keysSet newPayloads
      restored <-
        if Set.null (evictedObjects previous)
          then pure Set.empty
          else Set.intersection (evictedObjects previous) <$> reachable memoryOf objectIds newRoots
      let gone = evictedObjects previous `Set.difference` restored
      checkpoint <- either (throwE . InvalidCheckpoint) pure (withEvicted gone base)
      -- Accepted files became durable before their old CURRENT publication.
      -- Only new payloads and restored copies need a save.
      -- Prepared but unaccepted files still pass through saveImmutable and its
      -- directory flush, including retries after a rename interrupted by death.
      traverse_ (\(digest, (bytes, _)) -> saveImmutable hook (MemoryFile digest) (objectPath repo digest) bytes) (Map.toAscList newPayloads)
      traverse_
        ( \digest -> do
            bytes <- readObjectBytes repo digest
            saveImmutable hook (MemoryFile digest) (objectPath repo digest) bytes
        )
        (Set.toAscList restored)
      traverse_ (\(key, event) -> saveImmutable hook (EventFile key) (eventPath repo key) (renderEvent event)) (Map.toAscList newEvents)
      saveCheckpoint hook repo checkpoint
      publishCurrent hook repo checkpoint
      pruneCheckpoints repo [checkpointId checkpoint, snapshotId old]
      pure (Snapshot root checkpoint state)

verifyPayload :: (Id, ByteString) -> ExceptT RepositoryError IO (Id, (ByteString, Memory))
verifyPayload (digest, bytes) = do
  when (BS.length bytes > maxPayloadBytes) (throwE (OversizedData (T.unpack (Id.render digest))))
  unless (Id.hashBytes bytes == digest) (throwE (CorruptData (T.unpack (Id.render digest))))
  memory <- either (throwE . InvalidMemory digest) pure (parseMemory bytes)
  pure (digest, (bytes, memory))

-- | Validate a complete transport inventory before a live import or join.
verifyIncoming :: StoreId -> [(EventId, ByteString)] -> [(Id, ByteString)] -> IO (Either RepositoryError State)
verifyIncoming store eventBytes payloads = runExceptT $ do
  state <- either (throwE . InvalidState) pure (State.fromBytes store eventBytes)
  memories <- Map.fromList <$> traverse verifyPayload payloads
  validatePayloads state (Map.map snd memories)
  pure state

validatePayloads :: State -> Map Id Memory -> ExceptT RepositoryError IO ()
validatePayloads state memories = do
  traverse_ (\digest -> unless (Map.member digest memories) (throwE (MissingPayload digest))) (concatMap (actionPayloads . Event.eventAction) (Map.elems (State.events state)))
  traverse_ checkMemory (Map.toAscList memories)
  traverse_ checkLog (Map.toAscList (State.events state))
  where
    checkLog (eventId, event) = case Event.eventAction event of
      AppendLog _ digest -> case Map.lookup digest memories of
        Nothing -> throwE (MissingPayload digest)
        Just memory -> do
          let linked = Set.fromList [target edge | edge <- Set.toList (memEdges memory), kind edge == Follows]
              parents = [value | parent <- Set.toList (Event.eventParents event), Just previous <- [Map.lookup parent (State.events state)], value <- actionPayloads (Event.eventAction previous)]
          traverse_ (\parent -> unless (parent `Set.member` linked) (throwE (MissingLogPredecessor eventId parent))) parents
      _ -> pure ()
    checkMemory (digest, memory) = traverse_ (checkEdge digest) (Set.toAscList (memEdges memory))
    checkEdge source edge = when (retains (kind edge) && Map.notMember (target edge) memories) (throwE (MissingRetainedTarget source (target edge)))

-- | The checks of 'validatePayloads', for the part that a transaction adds.
-- Old events and payloads keep the checks that they passed at entry, and the
-- inventory only grows, so their links stay satisfied.
validateAdded :: (Id -> ExceptT RepositoryError IO Memory) -> State -> Set.Set Id -> Map EventId Event -> Map Id Memory -> ExceptT RepositoryError IO ()
validateAdded memoryOf state objects newEvents newPayloads = do
  traverse_ (\digest -> unless (digest `Set.member` objects) (throwE (MissingPayload digest))) (concatMap (actionPayloads . Event.eventAction) (Map.elems newEvents))
  traverse_ (\(digest, memory) -> traverse_ (checkEdge digest) (Set.toAscList (memEdges memory))) (Map.toAscList newPayloads)
  traverse_ checkLog (Map.toAscList newEvents)
  where
    checkEdge source edge = when (retains (kind edge) && Set.notMember (target edge) objects) (throwE (MissingRetainedTarget source (target edge)))
    checkLog (eventId, event) = case Event.eventAction event of
      AppendLog _ digest -> do
        memory <- memoryOf digest
        let linked = Set.fromList [target edge | edge <- Set.toList (memEdges memory), kind edge == Follows]
            parents = [value | parent <- Set.toList (Event.eventParents event), Just previous <- [Map.lookup parent (State.events state)], value <- actionPayloads (Event.eventAction previous)]
        traverse_ (\parent -> unless (parent `Set.member` linked) (throwE (MissingLogPredecessor eventId parent))) parents
      _ -> pure ()

-- | Every accepted payload that the roots retain, through retaining edges.
-- It reads only the memories on the way.
reachable :: (Id -> ExceptT RepositoryError IO Memory) -> Set.Set Id -> Set.Set Id -> ExceptT RepositoryError IO (Set.Set Id)
reachable memoryOf objects = go Set.empty
  where
    go seen pending = case Set.minView pending of
      Nothing -> pure seen
      Just (digest, rest)
        | digest `Set.member` seen || digest `Set.notMember` objects -> go seen rest
        | otherwise -> do
            memory <- memoryOf digest
            let children = Set.fromList [target edge | edge <- Set.toList (memEdges memory), retains (kind edge)]
            go (Set.insert digest seen) (rest <> children)

loadMemories :: Repository -> Set.Set Id -> ExceptT RepositoryError IO (Map Id Memory)
loadMemories repo ids = Map.fromList <$> traverse (\digest -> (digest,) <$> readParsed repo digest) (Set.toAscList ids)

readParsed :: Repository -> Id -> ExceptT RepositoryError IO Memory
readParsed repo digest = readObjectBytes repo digest >>= either (throwE . InvalidMemory digest) pure . parseMemory

-- | Explicit reads are scoped to the captured checkpoint, never directory listings.
readMemory :: Snapshot -> Id -> IO (Either RepositoryError Memory)
readMemory snapshot digest = fmap join $ tryWith RepositoryIO $ runExceptT $ do
  unless (digest `Set.member` checkpointObjects (snapshotCheckpoint snapshot)) (throwE (UnacceptedObject digest))
  let repo = Repository (snapshotRoot snapshot) (checkpointStore (snapshotCheckpoint snapshot))
  bytes <- readObjectBytes repo digest
  either (throwE . InvalidMemory digest) pure (parseMemory bytes)

-- Missing active copies fall back to the durable archive. An existing corrupt
-- copy is an error, never a reason to hide corruption behind another file.
readObjectBytes :: Repository -> Id -> ExceptT RepositoryError IO ByteString
readObjectBytes repo digest = ExceptT $ do
  local <- ifMissing Nothing (Just <$> runExceptT primary)
  maybe fallback pure local
  where
    primary = readChecked maxPayloadBytes (objectPath repo digest) digest
    fallback = runExceptT (readChecked maxPayloadBytes (archiveObjectPath repo digest) digest)

data CollectionPlan = CollectionPlan
  { collectionCheckpoint :: CheckpointId,
    collectionRetained :: Set.Set Id,
    collectionCandidates :: Set.Set Id,
    collectionEvicted :: Set.Set Id
  }
  deriving (Eq, Show)

planCollection :: Repository -> Int -> IO (Either RepositoryError CollectionPlan)
planCollection repo depth = fmap join $ tryWith RepositoryIO $ runExceptT $ do
  (snapshot, memories) <- ExceptT (loadSnapshotMemories repo)
  either throwE pure (collectionPlan snapshot memories depth)

collectionPlan :: Snapshot -> Map Id Memory -> Int -> Either RepositoryError CollectionPlan
collectionPlan snapshot memories depth = do
  unless (depth >= 1 && depth <= 1000) (Left InvalidRetentionDepth)
  let checkpoint = snapshotCheckpoint snapshot
      live = retained depth checkpoint (snapshotState snapshot) memories
  pure (CollectionPlan (snapshotId snapshot) live (activeObjects checkpoint `Set.difference` live) (evictedObjects checkpoint))

-- | Prepare a complete durable local archive of one accepted checkpoint.
-- This is NOT acknowledgement of remote publication. Transport calls the
-- separate acknowledgement API only after it verifies remote inclusion.
-- Accepted inventories only grow and archive files are immutable. Preparation
-- therefore needs no mutation lock. Concurrent GC saves the same bytes before
-- unlinking an active copy, so readers can always use archive fallback.
archiveSnapshot :: Repository -> Snapshot -> IO (Either RepositoryError CheckpointId)
archiveSnapshot = archiveSnapshotWith (const (pure ()))

archiveSnapshotWith :: FaultHook -> Repository -> Snapshot -> IO (Either RepositoryError CheckpointId)
archiveSnapshotWith hook repo@(Repository root _) captured = fmap join $ tryWith RepositoryIO $ runExceptT $ do
  current <- ExceptT (loadSnapshot repo)
  unless (snapshotRoot captured == root && included (snapshotCheckpoint captured) (snapshotCheckpoint current)) (throwE ArchiveNotAccepted)
  saveArchive hook repo captured
  pure (snapshotId captured)

-- | Archive exactly the remotely verified inventory, not newer local events.
-- Used by resumable joins before the first local registration is published.
archiveIncoming :: Repository -> State -> Set.Set Id -> IO (Either RepositoryError CheckpointId)
archiveIncoming repo@(Repository root store) state objects = fmap join $ tryWith RepositoryIO $ runExceptT $ do
  current <- ExceptT (loadSnapshot repo)
  checkpoint <- either (throwE . InvalidCheckpoint) pure (mkCheckpoint (State.storeId state) (Map.keysSet (State.events state)) objects Set.empty Set.empty)
  unless (State.storeId state == store && included checkpoint (snapshotCheckpoint current)) (throwE ArchiveNotAccepted)
  memories <- loadMemories repo objects
  validatePayloads state memories
  let snapshot = Snapshot root checkpoint state
  saveArchive (const (pure ())) repo snapshot
  pure (snapshotId snapshot)

included :: Checkpoint -> Checkpoint -> Bool
included part whole =
  checkpointStore part == checkpointStore whole
    && checkpointEvents part `Set.isSubsetOf` checkpointEvents whole
    && checkpointObjects part `Set.isSubsetOf` checkpointObjects whole

saveArchive :: FaultHook -> Repository -> Snapshot -> ExceptT RepositoryError IO ()
saveArchive hook repo@(Repository root _) snapshot = do
  liftIO (traverse_ (ensureDirectory hook . (root </>)) ["archive/objects", "archive/events", "archive/checkpoints"])
  let checkpoint = snapshotCheckpoint snapshot
  traverse_ (\digest -> readObjectBytes repo digest >>= saveImmutable hook (ArchiveMemoryFile digest) (archiveObjectPath repo digest)) (Set.toAscList (checkpointObjects checkpoint))
  traverse_ (\(key, event) -> saveImmutable hook (ArchiveEventFile key) (archiveEventPath repo key) (renderEvent event)) (Map.toAscList (State.events (snapshotState snapshot)))
  -- A manifest is the archive commit marker. It comes after every dependency.
  saveImmutable hook (ArchiveCheckpointFile (snapshotId snapshot)) (archiveCheckpointPath repo (snapshotId snapshot)) (renderCheckpoint checkpoint)

loadArchive :: Repository -> CheckpointId -> ExceptT RepositoryError IO Checkpoint
loadArchive repo@(Repository _ store) key@(CheckpointId digest) = do
  bytes <- readChecked maxCheckpointBytes (archiveCheckpointPath repo key) digest
  checkpoint <- either (throwE . InvalidCheckpoint) pure (parseCheckpoint bytes)
  unless (checkpointStore checkpoint == store) (throwE IdentityMismatch)
  entries <- traverse (\eventId@(EventId hash) -> (eventId,) <$> readChecked maxEventBytes (archiveEventPath repo eventId) hash) (Set.toAscList (checkpointEvents checkpoint))
  state <- either (throwE . InvalidState) pure (State.fromBytes store entries)
  memories <-
    Map.fromList
      <$> traverse
        ( \i -> do
            payload <- readChecked maxPayloadBytes (archiveObjectPath repo i) i
            memory <- either (throwE . InvalidMemory i) pure (parseMemory payload)
            pure (i, memory)
        )
        (Set.toAscList (checkpointObjects checkpoint))
  validatePayloads state memories
  pure checkpoint

-- | Internal transport boundary. The caller MUST already have verified that
-- the remote contains the archived checkpoint's complete event/payload sets.
-- The local archive is validated independently before obligations are cleared.
-- Newer local writes remain pending. There is deliberately no CLI/MCP command.
acknowledgePublished :: Repository -> CheckpointId -> IO (Either RepositoryError Snapshot)
acknowledgePublished = acknowledgePublishedWith (const (pure ()))

acknowledgePublishedWith :: FaultHook -> Repository -> CheckpointId -> IO (Either RepositoryError Snapshot)
acknowledgePublishedWith hook repo@(Repository root store) key = withMutation root RepositoryBusy RepositoryIO $ \_ -> runExceptT $ do
  current <- ExceptT (loadSnapshot repo)
  archived <- loadArchive repo key
  liftIO (syncDir (takeDirectory (archiveCheckpointPath repo key)))
  let previous = snapshotCheckpoint current
  unless (included archived previous) (throwE ArchiveNotAccepted)
  base <- either (throwE . InvalidCheckpoint) pure (mkCheckpoint store (checkpointEvents previous) (checkpointObjects previous) (pendingEvents previous `Set.difference` checkpointEvents archived) (pendingObjects previous `Set.difference` checkpointObjects archived))
  checkpoint <- either (throwE . InvalidCheckpoint) pure (withEvicted (evictedObjects previous) base)
  saveCheckpoint hook repo checkpoint
  publishCurrent hook repo checkpoint
  pruneCheckpoints repo [checkpointId checkpoint, snapshotId current]
  pruneArchiveMarkers repo key
  pure (Snapshot root checkpoint (snapshotState current))

-- | Prepare the archive outside the lock, then recheck and recompute under
-- the mutation lock; never sweep a caller's stale plan. All accepted bytes
-- enter the durable archive before CURRENT permits eviction. Unlink follows
-- publication, so every old captured snapshot has fallback.
collect :: Repository -> CheckpointId -> Int -> IO (Either RepositoryError CollectionPlan)
collect = collectWith (const (pure ()))

collectWith :: FaultHook -> Repository -> CheckpointId -> Int -> IO (Either RepositoryError CollectionPlan)
collectWith hook repo@(Repository root _) expected depth = fmap join $ tryWith RepositoryIO $ runExceptT $ do
  unless (depth >= 1 && depth <= 1000) (throwE InvalidRetentionDepth)
  captured <- ExceptT (loadSnapshot repo)
  unless (snapshotId captured == expected) (throwE StaleCheckpoint)
  saveArchive hook repo captured
  ExceptT $ withMutation root RepositoryBusy RepositoryIO $ \_ -> runExceptT $ do
    (current, memories) <- ExceptT (loadSnapshotMemories repo)
    unless (snapshotId current == expected) (throwE StaleCheckpoint)
    plan <- either throwE pure (collectionPlan current memories depth)
    let gone = (collectionEvicted plan <> collectionCandidates plan) `Set.difference` collectionRetained plan
        restored = collectionEvicted plan `Set.difference` gone
    traverse_ (\digest -> readObjectBytes repo digest >>= saveImmutable hook (MemoryFile digest) (objectPath repo digest)) (Set.toAscList restored)
    checkpoint <- either (throwE . InvalidCheckpoint) pure (withEvicted gone (snapshotCheckpoint current))
    saveCheckpoint hook repo checkpoint
    publishCurrent hook repo checkpoint
    pruneCheckpoints repo [checkpointId checkpoint, snapshotId current]
    -- A failed unlink is retryable: CURRENT already excludes these active copies.
    removal <- liftIO $ tryWith (CollectionIncomplete (checkpointId checkpoint)) $ do
      traverse_
        ( \digest -> do
            ifMissing () (removeFile (objectPath repo digest))
            hook (MemoryEvicted digest)
        )
        (Set.toAscList gone)
      syncDir (root </> "objects")
      hook EvictionsSynced
    either throwE pure removal
    pure plan {collectionCheckpoint = checkpointId checkpoint, collectionEvicted = gone}

saveCheckpoint :: FaultHook -> Repository -> Checkpoint -> ExceptT RepositoryError IO ()
saveCheckpoint hook repo checkpoint = saveImmutable hook (CheckpointFile (checkpointId checkpoint)) (checkpointPath repo (checkpointId checkpoint)) (renderCheckpoint checkpoint)

saveImmutable :: FaultHook -> WriteTarget -> FilePath -> ByteString -> ExceptT RepositoryError IO ()
saveImmutable hook target path bytes = do
  existing <- liftIO (ifMissing Nothing (Just <$> boundedRead (BS.length bytes) path))
  case existing of
    Just old -> do
      unless (old == bytes) (throwE (CorruptData path))
      -- A prior process can die after rename but before the directory flush.
      liftIO (syncDir (takeDirectory path))
    Nothing -> liftIO (atomicWriteWith (hook . WriteBoundary target) path bytes)

publishCurrent :: FaultHook -> Repository -> Checkpoint -> ExceptT RepositoryError IO ()
publishCurrent hook (Repository root _) checkpoint = do
  renamed <- liftIO (newIORef False)
  let key@(CheckpointId digest) = checkpointId checkpoint
      step boundary = do
        when (boundary == Renamed) (writeIORef renamed True)
        hook (WriteBoundary CurrentFile boundary)
  result <- liftIO (tryWith id (atomicWriteWith step (root </> "CURRENT") (encodeUtf8 (Id.render digest <> "\n"))))
  case result of
    Right () -> pure ()
    Left err -> do
      visible <- liftIO (readIORef renamed)
      throwE (if visible then PublicationUncertain key err else RepositoryIO err)

-- | Remove archive commit markers older than an acknowledged one. Only
-- acknowledgement reads a marker. An older marker names a subset of an
-- inventory that is now published, so no later acknowledgement needs it. A
-- newer marker can belong to an archive that is still unpublished: keep it.
-- Archive payloads and events are not touched. Removal is best effort.
pruneArchiveMarkers :: Repository -> CheckpointId -> ExceptT RepositoryError IO ()
pruneArchiveMarkers repo@(Repository root _) key@(CheckpointId acknowledged) = liftIO $ ignoreIO $ do
  let directory = root </> "archive" </> "checkpoints"
      manifest file = either (const False) (const True) (Id.parse (T.pack file))
  reference <- getModificationTime (archiveCheckpointPath repo key)
  files <- listDirectory directory
  forM_ [file | file <- files, manifest file, file /= T.unpack (Id.render acknowledged)] $ \file -> ignoreIO $ do
    written <- getModificationTime (directory </> file)
    when (written < reference) (removeFile (directory </> file))

-- | Remove superseded manifests. Each manifest names the whole inventory, so
-- an unpruned directory grows with writes times inventory size. Callers hold
-- the mutation lock and have published CURRENT, so no other manifest is in
-- preparation. Removal is best effort: a failure never rejects the accepted
-- publication, and a later write tries again. Archive manifests are separate.
pruneCheckpoints :: Repository -> [CheckpointId] -> ExceptT RepositoryError IO ()
pruneCheckpoints (Repository root _) keep = liftIO $ ignoreIO $ do
  let directory = root </> "checkpoints"
      kept = Set.fromList [T.unpack (Id.render digest) | CheckpointId digest <- keep]
      manifest file = either (const False) (const True) (Id.parse (T.pack file))
  files <- listDirectory directory
  traverse_ (\file -> ignoreIO (removeFile (directory </> file))) [file | file <- files, manifest file, file `Set.notMember` kept]

objectPath :: Repository -> Id -> FilePath
objectPath (Repository root _) digest = root </> "objects" </> T.unpack (Id.render digest)

eventPath :: Repository -> EventId -> FilePath
eventPath (Repository root _) (EventId digest) = root </> "events" </> T.unpack (Id.render digest)

checkpointPath :: Repository -> CheckpointId -> FilePath
checkpointPath (Repository root _) (CheckpointId digest) = root </> "checkpoints" </> T.unpack (Id.render digest)

archiveObjectPath :: Repository -> Id -> FilePath
archiveObjectPath (Repository root _) digest = root </> "archive" </> "objects" </> T.unpack (Id.render digest)

archiveEventPath :: Repository -> EventId -> FilePath
archiveEventPath (Repository root _) (EventId digest) = root </> "archive" </> "events" </> T.unpack (Id.render digest)

archiveCheckpointPath :: Repository -> CheckpointId -> FilePath
archiveCheckpointPath (Repository root _) (CheckpointId digest) = root </> "archive" </> "checkpoints" </> T.unpack (Id.render digest)

readChecked :: Int -> FilePath -> Id -> ExceptT RepositoryError IO ByteString
readChecked limit path digest = do
  bytes <- liftIO (boundedRead limit path)
  when (BS.length bytes > limit) (throwE (OversizedData path))
  unless (Id.hashBytes bytes == digest) (throwE (CorruptData path))
  pure bytes

-- Read at most one extra byte to detect oversized input without allocating it all.
boundedRead :: Int -> FilePath -> IO ByteString
boundedRead limit path = withBinaryFile path ReadMode $ \handle -> do
  size <- hFileSize handle
  hGetBounded (limit + 1) size handle

ensureDirectory :: FaultHook -> FilePath -> IO ()
ensureDirectory hook path = do
  let parent = takeDirectory path
  when (parent /= path) (ensureDirectory hook parent)
  exists <- doesDirectoryExist path
  unless exists $ do
    result <- tryWith id (createDirectory path)
    case result of
      Left err | not (isAlreadyExistsError err) -> ioError err
      _ -> pure ()
    hook (DirectoryCreated path)
  -- Also flush existing parents: an earlier initialiser can die immediately
  -- after mkdir, before it saves the new directory entry in its parent.
  when (parent /= path) (syncDir parent)
