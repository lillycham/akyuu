-- | Manual exchange. Network calls hold only sync.lock. Repository transactions
-- independently capture CURRENT and retain later local export obligations.
module Akyuu.Sync.Run (SyncError (..), SyncPoint (..), configure, runSync, runSyncWith, status, joinReplica, joinReplicaWith, describeSyncError) where

import Akyuu.Fs (atomicWrite, ifMissing, ignoreIO, tryWith)
import Akyuu.Id qualified as Id
import Akyuu.Sync.Checkpoint (CheckpointId (CheckpointId), checkpointEvents, checkpointObjects, pendingEvents, pendingObjects)
import Akyuu.Sync.Event (eventAction)
import Akyuu.Sync.Git (Bundle (bundlePayloads, bundleState), GitError, ancestor, bundleAt, describeGitError, fetch, prepare, push, readBundle, writeBundle)
import Akyuu.Sync.Process (Deadline, deadline)
import Akyuu.Sync.Repository (RepositoryError, acknowledgePublished, archiveIncoming, archiveSnapshot, importState, initialise, loadSnapshot, openRepository, snapshotCheckpoint, snapshotId, snapshotState)
import Akyuu.Sync.State (ResourceState (RefTypeConflict, TopicHeads), State, events, interpret, merge, storeId)
import Akyuu.Sync.Topics (initialiseLocal)
import Akyuu.Sync.Types (resourceOf)
import Control.Concurrent (threadDelay)
import Control.Exception (IOException)
import Control.Monad (forM_, unless, void, when)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Trans.Except (ExceptT (ExceptT), runExceptT, throwE)
import Data.Aeson (Value, eitherDecodeStrict', encode, object, (.:), (.=))
import Data.Aeson.Types (parseEither, withObject)
import Data.Bifunctor (first)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BL
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import System.Directory (createDirectoryIfMissing, doesDirectoryExist, doesFileExist, listDirectory, makeAbsolute, renameDirectory)
import System.FileLock (SharedExclusive (Exclusive), withTryFileLock)
import System.FilePath ((</>))

data SyncError = SyncIO IOException | SyncGit GitError | SyncStorage RepositoryError | SyncInvalid Text | SyncBusy | RemoteRewritten | PublicationUnconfirmed deriving (Eq, Show)

data SyncPoint = AfterFetch | BeforePush | AfterPush | JoinImported | JoinRegistered deriving (Eq, Show)

data Settings = Settings Text Text deriving (Eq, Show)

type Work = ExceptT SyncError IO

storage :: IO (Either RepositoryError a) -> Work a
storage = ExceptT . fmap (first SyncStorage)

transport :: IO (Either GitError a) -> Work a
transport = ExceptT . fmap (first SyncGit)

withSync :: FilePath -> Work a -> IO (Either SyncError a)
withSync root action = go (100 :: Int)
  where
    go 0 = pure (Left SyncBusy)
    go n = do
      result <- tryWith SyncIO (withTryFileLock (root </> "sync.lock") Exclusive (const (runExceptT action)))
      case result of
        Left err -> pure (Left err)
        Right Nothing -> threadDelay 10000 >> go (n - 1)
        Right (Just value) -> pure value

settings :: Text -> Text -> IO (Either SyncError Settings)
settings remote branch = runExceptT $ do
  let full = if "refs/heads/" `T.isPrefixOf` branch then branch else "refs/heads/" <> branch
      pieces = T.splitOn "/" full
      allowed c = c `elem` ['a' .. 'z'] || c `elem` ['A' .. 'Z'] || c `elem` ['0' .. '9'] || c `elem` ['-', '_', '.', '/']
  unless (not (T.null remote) && T.strip remote == remote && not (T.any (`elem` ['\n', '\r', '\0']) remote) && not ("-" `T.isPrefixOf` remote)) (throwE (SyncInvalid "Give a nonblank remote path or URL."))
  when (("https://" `T.isPrefixOf` remote || "http://" `T.isPrefixOf` remote) && "@" `T.isInfixOf` remote) (throwE (SyncInvalid "Do not put credentials in a remote URL."))
  unless (T.length full <= 200 && T.all allowed full && not (".." `T.isInfixOf` full) && all (\p -> not (T.null p) && not ("." `T.isPrefixOf` p) && not ("." `T.isSuffixOf` p) && not (".lock" `T.isSuffixOf` p)) pieces) (throwE (SyncInvalid "Give a valid branch below refs/heads/."))
  url <- if ":" `T.isInfixOf` remote then pure remote else liftIO (T.pack <$> makeAbsolute (T.unpack remote))
  pure (Settings url full)

settingsJSON :: Settings -> Value
settingsJSON (Settings remote branch) = object ["remote" .= remote, "branch" .= branch]

readSettings :: FilePath -> Work Settings
readSettings root = do
  bytes <- liftIO (BS.readFile (root </> "SYNC"))
  value <- either (const (throwE (SyncInvalid "Invalid sync configuration."))) pure (eitherDecodeStrict' bytes)
  (remote, branch) <- either (const (throwE (SyncInvalid "Invalid sync configuration."))) pure (parseEither (withObject "sync" (\o -> (,) <$> o .: "remote" <*> o .: "branch")) value)
  ExceptT (settings remote branch)

configure :: FilePath -> Text -> Text -> IO (Either SyncError ())
configure root remote branch = withSync root $ do
  _ <- storage (openRepository root)
  chosen <- ExceptT (settings remote branch)
  exists <- liftIO (doesFileExist (root </> "SYNC"))
  when exists $ do
    previous <- readSettings root
    unless (previous == chosen) (throwE (SyncInvalid "This replica already has a different sync target."))
  end <- liftIO (deadline 60)
  transport (prepare end (root </> "transport.git"))
  liftIO (atomicWrite (root </> "SYNC") (BL.toStrict (encode (settingsJSON chosen))))

remember :: FilePath -> Maybe Text -> Work ()
remember _ Nothing = pure ()
remember root (Just tip) = liftIO (atomicWrite (root </> "SYNC-TIP") (BL.toStrict (encode tip)))

-- The cursor is JSON, so parse it strictly rather than interpolating raw text
-- into a revision argument. It never becomes a refspec or remote URL.
readTip :: FilePath -> Work (Maybe Text)
readTip root = do
  bytes <- liftIO (ifMissing Nothing (Just <$> BS.readFile (root </> "SYNC-TIP")))
  case bytes of
    Nothing -> pure Nothing
    Just value -> case eitherDecodeStrict' value of
      Right tip | T.length tip == 40 && T.all (\c -> c `elem` ['0' .. '9'] || c `elem` ['a' .. 'f']) tip -> pure (Just tip)
      _ -> throwE (SyncInvalid "The saved remote cursor is invalid.")

verifiedFetch :: Deadline -> FilePath -> Settings -> Work (Maybe Text, Maybe Bundle)
verifiedFetch end root (Settings remote branch) = do
  let gitRoot = root </> "transport.git"
  old <- readTip root
  tip <- transport (fetch end gitRoot remote branch)
  case (old, tip) of
    (Just _, Nothing) -> throwE RemoteRewritten
    (Just previous, Just current) | previous /= current -> do
      follows <- transport (ancestor end gitRoot previous current)
      unless follows (throwE RemoteRewritten)
    _ -> pure ()
  bundle <- traverse (transport . readBundle end gitRoot) tip
  case (old, bundle) of
    (Just previous, Just incoming) | Just previous /= tip -> do
      accepted <- transport (readBundle end gitRoot previous)
      unless (contains incoming accepted) (throwE RemoteRewritten)
    _ -> pure ()
  remember root tip
  pure (tip, bundle)

contains :: Bundle -> Bundle -> Bool
contains whole part = storeId (bundleState whole) == storeId (bundleState part) && Map.keysSet (events (bundleState part)) `Set.isSubsetOf` Map.keysSet (events (bundleState whole)) && Map.keysSet (bundlePayloads part) `Set.isSubsetOf` Map.keysSet (bundlePayloads whole)

runSync :: FilePath -> Bool -> IO (Either SyncError Value)
runSync = runSyncWith (const (pure ())) 60

runSyncWith :: (SyncPoint -> IO ()) -> Int -> FilePath -> Bool -> IO (Either SyncError Value)
runSyncWith hook seconds root preview = withSync root $ do
  checked <- liftIO $ tryWith SyncIO $ runExceptT $ do
    when (seconds < 1 || seconds > 60) (throwE (SyncInvalid "The sync deadline must be from 1 to 60 seconds."))
    repo <- storage (openRepository root)
    config <- readSettings root
    end <- liftIO (deadline seconds)
    transport (prepare end (root </> "transport.git"))
    attempt end repo config (3 :: Int)
  let result = either Left id checked
  liftIO (ignoreIO (atomicWrite (root </> "SYNC-ERROR") (BL.toStrict (encode (either (Just . describeSyncError) (const Nothing) result)))))
  either throwE pure result
  where
    attempt end repo config@(Settings remote branch) tries = do
      (tip, incoming) <- verifiedFetch end root config
      liftIO (hook AfterFetch)
      before <- storage (loadSnapshot repo)
      forM_ incoming $ \bundle -> unless (storeId (bundleState bundle) == storeId (snapshotState before)) (throwE (SyncInvalid "The remote belongs to a different memory store."))
      if preview
        then do
          combined <- maybe (pure (snapshotState before)) (either (const (throwE (SyncInvalid "The remote history cannot merge."))) pure . merge (snapshotState before) . bundleState) incoming
          pure (object ["preview" .= True, "checkpoint" .= checkpointText (snapshotId before), "remote_tip" .= tip, "import_events" .= maybe 0 (\bundle -> Set.size (Map.keysSet (events (bundleState bundle)) `Set.difference` Map.keysSet (events (snapshotState before)))) incoming, "conflicts" .= countConflicts combined])
        else do
          forM_ incoming $ \bundle -> do
            -- The fetched bundle and local checkpoint were both fully verified.
            -- Accepted inventories only grow, so a subset needs no import even
            -- if another writer advances CURRENT after this comparison.
            let known =
                  Map.keysSet (events (bundleState bundle)) `Set.isSubsetOf` checkpointEvents (snapshotCheckpoint before)
                    && Map.keysSet (bundlePayloads bundle) `Set.isSubsetOf` checkpointObjects (snapshotCheckpoint before)
            unless known (void (storage (importState repo (bundleState bundle) (Map.toList (bundlePayloads bundle)))))
          captured <- storage (loadSnapshot repo)
          key <- storage (archiveSnapshot repo captured)
          outgoing <- transport (bundleAt captured)
          if maybe False (`contains` outgoing) incoming
            then finish repo key tip False
            else do
              commit <- transport (writeBundle end (root </> "transport.git") tip outgoing)
              liftIO (hook BeforePush)
              result <- liftIO (push end (root </> "transport.git") remote branch commit)
              case result of
                Left _ | tries > 1 -> attempt end repo config (tries - 1)
                Left failure -> throwE (SyncGit failure)
                Right () -> do
                  liftIO (hook AfterPush)
                  (published, receipt) <- verifiedFetch end root config
                  unless (maybe False (`contains` outgoing) receipt) (throwE PublicationUnconfirmed)
                  finish repo key published (maybe False (\bundle -> not (outgoing `contains` bundle)) receipt)
    finish repo key tip more = do
      accepted <- storage (acknowledgePublished repo key)
      saved <- liftIO (tryWith SyncIO (atomicWrite (root </> "SYNC-PUBLISHED") (BL.toStrict (encode (checkpointText key)))))
      pure (object ["preview" .= False, "published_checkpoint" .= checkpointText key, "remote_tip" .= tip, "remote_changes_remaining" .= more, "status_saved" .= either (const False) (const True) saved, "checkpoint" .= checkpointText (snapshotId accepted), "pending_events" .= Set.size (pendingEvents (snapshotCheckpoint accepted)), "pending_objects" .= Set.size (pendingObjects (snapshotCheckpoint accepted)), "conflicts" .= countConflicts (snapshotState accepted)])

status :: FilePath -> IO (Either SyncError Value)
status root = runExceptT $ do
  repo <- storage (openRepository root)
  snapshot <- storage (loadSnapshot repo)
  tip <- readTip root
  published <-
    liftIO
      ( ifMissing Nothing $ do
          bytes <- BS.readFile (root </> "SYNC-PUBLISHED")
          pure (either (const Nothing) (Just :: Text -> Maybe Text) (eitherDecodeStrict' bytes))
      )
  failure <-
    liftIO
      ( ifMissing Nothing $ do
          bytes <- BS.readFile (root </> "SYNC-ERROR")
          pure (either (const Nothing) id (eitherDecodeStrict' bytes :: Either String (Maybe Text)))
      )
  pure (object ["checkpoint" .= checkpointText (snapshotId snapshot), "last_fetched_tip" .= tip, "last_published_checkpoint" .= published, "last_error" .= failure, "pending_events" .= Set.size (pendingEvents (snapshotCheckpoint snapshot)), "pending_objects" .= Set.size (pendingObjects (snapshotCheckpoint snapshot)), "conflicts" .= countConflicts (snapshotState snapshot)])

countConflicts :: State -> Int
countConflicts state = length [() | resource <- Set.toList (Set.fromList (map (resourceOf . eventAction) (Map.elems (events state)))), case interpret state resource of TopicHeads heads -> Map.size heads > 1; RefTypeConflict _ -> True; _ -> False]

checkpointText :: CheckpointId -> Text
checkpointText (CheckpointId digest) = Id.render digest

-- | Fresh join is recoverable and never adopts an unrelated nonempty target.
-- Only the read/verified remote inventory is acknowledged; local registration
-- comes afterward and stays pending for the first publishing sync.
joinReplica :: FilePath -> Text -> Text -> Text -> IO (Either SyncError Value)
joinReplica = joinReplicaWith (const (pure ()))

joinReplicaWith :: (SyncPoint -> IO ()) -> FilePath -> Text -> Text -> Text -> IO (Either SyncError Value)
joinReplicaWith hook root remote branch label = do
  createDirectoryIfMissing True root
  withSync root $ do
    config <- ExceptT (settings remote branch)
    configured <- liftIO (doesFileExist (root </> "SYNC"))
    if configured
      then do
        existing <- readSettings root
        unless (existing == config) (throwE (SyncInvalid "This target has a different sync configuration."))
        _ <- ExceptT (first (SyncInvalid . T.pack . show) <$> initialiseLocal root label)
        ExceptT (status root)
      else do
        entries <- liftIO (listDirectory root)
        journal <- liftIO (doesFileExist (root </> ".tmp.join"))
        unless (journal || all (== "sync.lock") entries) (throwE (SyncInvalid "Join needs an empty directory or its own interrupted join."))
        when journal $ do
          bytes <- liftIO (BS.readFile (root </> ".tmp.join"))
          unless (bytes == BL.toStrict (encode (settingsJSON config))) (throwE (SyncInvalid "The interrupted join has different settings."))
        unless journal (liftIO (atomicWrite (root </> ".tmp.join") (BL.toStrict (encode (settingsJSON config)))))
        end <- liftIO (deadline 60)
        finalGit <- liftIO (doesDirectoryExist (root </> "transport.git"))
        let mirror = root </> if finalGit then "transport.git" else ".tmp.join.git"
            Settings url branchName = config
        transport (prepare end mirror)
        tip <- transport (fetch end mirror url branchName) >>= maybe (throwE (SyncInvalid "The remote protocol branch is empty.")) pure
        bundle <- transport (readBundle end mirror tip)
        priorBytes <- liftIO (ifMissing Nothing (Just <$> BS.readFile (root </> ".tmp.join-tip")))
        forM_ priorBytes $ \bytes -> do
          previous <- either (const (throwE (SyncInvalid "Invalid interrupted join cursor."))) pure (eitherDecodeStrict' bytes)
          follows <- transport (ancestor end mirror previous tip)
          old <- transport (readBundle end mirror previous)
          unless (follows && bundle `contains` old) (throwE RemoteRewritten)
        liftIO (atomicWrite (root </> ".tmp.join-tip") (BL.toStrict (encode tip)))
        repo <- storage (initialise root (storeId (bundleState bundle)))
        _ <- storage (importState repo (bundleState bundle) (Map.toList (bundlePayloads bundle)))
        liftIO (hook JoinImported)
        key <- storage (archiveIncoming repo (bundleState bundle) (Map.keysSet (bundlePayloads bundle)))
        _ <- storage (acknowledgePublished repo key)
        _ <- ExceptT (first (SyncInvalid . T.pack . show) <$> initialiseLocal root label)
        liftIO (hook JoinRegistered)
        unless finalGit (liftIO (renameDirectory mirror (root </> "transport.git")))
        remember root (Just tip)
        liftIO (atomicWrite (root </> "SYNC") (BL.toStrict (encode (settingsJSON config))))
        ExceptT (status root)

describeSyncError :: SyncError -> Text
describeSyncError err = case err of
  SyncGit failure -> describeGitError failure
  SyncStorage _ -> "The local replica operation failed. Its accepted checkpoint remains authoritative."
  SyncIO _ -> "A sync file or process operation failed. Pending work is retained."
  SyncInvalid text -> text
  SyncBusy -> "Another sync holds the sync lock."
  RemoteRewritten -> "The remote archive was rewritten or lost accepted entries. Recovery is required."
  PublicationUnconfirmed -> "Remote publication could not be confirmed. Export obligations remain pending."
