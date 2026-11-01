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
    loadSnapshot,
    commitLocal,
    commitLocalWith,
    importState,
    importStateWith,
    snapshotId,
    snapshotState,
    snapshotCheckpoint,
    readMemory,
    maxPayloadBytes,
  )
where

import Akyuu.Fs (AtomicStep (Renamed), atomicWriteWith, ifMissing, syncDir, tryWith)
import Akyuu.GC (retains)
import Akyuu.Graph (Edge (kind, target))
import Akyuu.Id (Id)
import Akyuu.Id qualified as Id
import Akyuu.Memory (Memory (memEdges), MemoryParseError, parseMemory)
import Akyuu.Mutation (withMutation)
import Akyuu.Sync.Checkpoint (Checkpoint, CheckpointError, CheckpointId (CheckpointId), checkpointEvents, checkpointId, checkpointObjects, checkpointStore, maxCheckpointBytes, mkCheckpoint, parseCheckpoint, pendingEvents, pendingObjects, renderCheckpoint)
import Akyuu.Sync.Event (Event, maxEventBytes, renderEvent)
import Akyuu.Sync.Event qualified as Event
import Akyuu.Sync.State (State, StateError, Version)
import Akyuu.Sync.State qualified as State
import Akyuu.Sync.Types (Action (AppendLog, ResolveLog, ResolveTopic, SetPin, SetReview, SetTopic), EventId (EventId), StoreId (StoreId), parseIdentifier, renderIdentifier)
import Control.Exception (IOException)
import Control.Monad (join, unless, when)
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
import System.Directory (canonicalizePath, createDirectory, doesDirectoryExist, listDirectory)
import System.FilePath (takeDirectory, (</>))
import System.IO (IOMode (ReadMode), withBinaryFile)
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
  | InvalidCheckpoint CheckpointError
  | InvalidState StateError
  | CorruptData FilePath
  | OversizedData FilePath
  | InvalidMemory Id MemoryParseError
  | MissingPayload Id
  | MissingRetainedTarget Id Id
  | UnacceptedObject Id
  | PublicationUncertain CheckpointId IOException
  deriving (Eq, Show)

data WriteTarget
  = IdentityFile
  | MemoryFile Id
  | EventFile EventId
  | CheckpointFile CheckpointId
  | CurrentFile
  deriving (Eq, Show)

data Boundary
  = DirectoryCreated FilePath
  | WriteBoundary WriteTarget AtomicStep
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
        unless (all (\entry -> entry == "store.lock" || ".tmp" `T.isPrefixOf` T.pack entry) entries) (throwE NotRepository)
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
        pure repo

openRepository :: FilePath -> IO (Either RepositoryError Repository)
openRepository path = fmap join $ tryWith RepositoryIO $ runExceptT $ do
  root <- liftIO (canonicalizePath path)
  bytes <- liftIO (boundedRead 256 (root </> "IDENTITY"))
  store <- either throwE pure (parseIdentity bytes)
  let repo = Repository root store
  _ <- ExceptT (loadSnapshot repo)
  pure repo

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

loadSnapshot :: Repository -> IO (Either RepositoryError Snapshot)
loadSnapshot repo@(Repository root store) = fmap join $ tryWith RepositoryIO $ runExceptT $ do
  identity <- liftIO (boundedRead 256 (root </> "IDENTITY"))
  unless (identity == identityBytes store) (throwE IdentityMismatch)
  pointer <- liftIO (boundedRead 128 (root </> "CURRENT"))
  digest <- either throwE pure (parsePointer pointer)
  bytes <- readChecked maxCheckpointBytes (checkpointPath repo (CheckpointId digest)) digest
  checkpoint <- either (throwE . InvalidCheckpoint) pure (parseCheckpoint bytes)
  unless (checkpointStore checkpoint == store) (throwE IdentityMismatch)
  eventBytes <- traverse (\key@(EventId hash) -> (key,) <$> readChecked maxEventBytes (eventPath repo key) hash) (Set.toAscList (checkpointEvents checkpoint))
  state <- either (throwE . InvalidState) pure (State.fromBytes store eventBytes)
  memories <- loadMemories repo (checkpointObjects checkpoint)
  validatePayloads state memories
  pure (Snapshot root checkpoint state)

parsePointer :: ByteString -> Either RepositoryError Id
parsePointer bytes = do
  text <- first (const InvalidPointer) (decodeUtf8' bytes)
  digest <- first (const InvalidPointer) (Id.parse (T.dropEnd 1 text))
  unless (encodeUtf8 (Id.render digest <> "\n") == bytes) (Left InvalidPointer)
  pure digest

commitLocal :: Repository -> Version -> Event -> [(Id, ByteString)] -> IO (Either RepositoryError Snapshot)
commitLocal = commitLocalWith (const (pure ()))

commitLocalWith :: FaultHook -> Repository -> Version -> Event -> [(Id, ByteString)] -> IO (Either RepositoryError Snapshot)
commitLocalWith hook repo expected event payloads = transact hook repo payloads $ \old ->
  first InvalidState (State.applyLocal expected event old)

-- | Merge into the latest checkpoint under the lock. Until transport supplies
-- verified publication receipts, all newly accepted events and objects stay pending.
importState :: Repository -> State -> [(Id, ByteString)] -> IO (Either RepositoryError Snapshot)
importState = importStateWith (const (pure ()))

importStateWith :: FaultHook -> Repository -> State -> [(Id, ByteString)] -> IO (Either RepositoryError Snapshot)
importStateWith hook repo incoming payloads = transact hook repo payloads (first InvalidState . (`State.merge` incoming))

transact :: FaultHook -> Repository -> [(Id, ByteString)] -> (State -> Either RepositoryError State) -> IO (Either RepositoryError Snapshot)
transact hook repo@(Repository root store) payloads advance = withMutation root RepositoryBusy RepositoryIO $ \_ -> runExceptT $ do
  old <- ExceptT (loadSnapshot repo)
  state <- either throwE pure (advance (snapshotState old))
  supplied <- Map.fromList <$> traverse verifyPayload payloads
  let previous = snapshotCheckpoint old
      objectIds = checkpointObjects previous <> Map.keysSet supplied
      eventIds = Map.keysSet (State.events state)
  oldMemories <- loadMemories repo (checkpointObjects previous)
  let memories = Map.union (Map.map snd supplied) oldMemories
  validatePayloads state memories
  checkpoint <-
    either (throwE . InvalidCheckpoint) pure $
      mkCheckpoint
        store
        eventIds
        objectIds
        (pendingEvents previous <> (eventIds `Set.difference` checkpointEvents previous))
        (pendingObjects previous <> (objectIds `Set.difference` checkpointObjects previous))
  traverse_ (\(digest, (bytes, _)) -> saveImmutable hook (MemoryFile digest) (objectPath repo digest) bytes) (Map.toAscList supplied)
  traverse_ (\(key, event) -> saveImmutable hook (EventFile key) (eventPath repo key) (renderEvent event)) (Map.toAscList (State.events state))
  saveCheckpoint hook repo checkpoint
  publishCurrent hook repo checkpoint
  pure (Snapshot root checkpoint state)

verifyPayload :: (Id, ByteString) -> ExceptT RepositoryError IO (Id, (ByteString, Memory))
verifyPayload (digest, bytes) = do
  when (BS.length bytes > maxPayloadBytes) (throwE (OversizedData (T.unpack (Id.render digest))))
  unless (Id.hashBytes bytes == digest) (throwE (CorruptData (T.unpack (Id.render digest))))
  memory <- either (throwE . InvalidMemory digest) pure (parseMemory bytes)
  pure (digest, (bytes, memory))

validatePayloads :: State -> Map Id Memory -> ExceptT RepositoryError IO ()
validatePayloads state memories = do
  traverse_ (\digest -> unless (Map.member digest memories) (throwE (MissingPayload digest))) (concatMap (targets . Event.eventAction) (Map.elems (State.events state)))
  traverse_ checkMemory (Map.toAscList memories)
  where
    targets action = case action of
      SetTopic _ digest -> [digest]
      AppendLog _ digest -> [digest]
      ResolveTopic _ digest -> [digest]
      ResolveLog _ digest -> [digest]
      SetPin digest -> [digest]
      SetReview a b _ -> [a, b]
      _ -> []
    checkMemory (digest, memory) = traverse_ (checkEdge digest) (Set.toAscList (memEdges memory))
    checkEdge source edge = when (retains (kind edge) && Map.notMember (target edge) memories) (throwE (MissingRetainedTarget source (target edge)))

loadMemories :: Repository -> Set.Set Id -> ExceptT RepositoryError IO (Map Id Memory)
loadMemories repo ids = Map.fromList <$> traverse readOne (Set.toAscList ids)
  where
    readOne digest = do
      bytes <- readChecked maxPayloadBytes (objectPath repo digest) digest
      memory <- either (throwE . InvalidMemory digest) pure (parseMemory bytes)
      pure (digest, memory)

-- | Explicit reads are scoped to the captured checkpoint, never directory listings.
readMemory :: Snapshot -> Id -> IO (Either RepositoryError Memory)
readMemory snapshot digest = fmap join $ tryWith RepositoryIO $ runExceptT $ do
  unless (digest `Set.member` checkpointObjects (snapshotCheckpoint snapshot)) (throwE (UnacceptedObject digest))
  let repo = Repository (snapshotRoot snapshot) (checkpointStore (snapshotCheckpoint snapshot))
  bytes <- readChecked maxPayloadBytes (objectPath repo digest) digest
  either (throwE . InvalidMemory digest) pure (parseMemory bytes)

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

objectPath :: Repository -> Id -> FilePath
objectPath (Repository root _) digest = root </> "objects" </> T.unpack (Id.render digest)

eventPath :: Repository -> EventId -> FilePath
eventPath (Repository root _) (EventId digest) = root </> "events" </> T.unpack (Id.render digest)

checkpointPath :: Repository -> CheckpointId -> FilePath
checkpointPath (Repository root _) (CheckpointId digest) = root </> "checkpoints" </> T.unpack (Id.render digest)

readChecked :: Int -> FilePath -> Id -> ExceptT RepositoryError IO ByteString
readChecked limit path digest = do
  bytes <- liftIO (boundedRead limit path)
  when (BS.length bytes > limit) (throwE (OversizedData path))
  unless (Id.hashBytes bytes == digest) (throwE (CorruptData path))
  pure bytes

-- Read at most one extra byte to detect oversized input without allocating it all.
boundedRead :: Int -> FilePath -> IO ByteString
boundedRead limit path = withBinaryFile path ReadMode (\handle -> BS.hGet handle (limit + 1))

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
