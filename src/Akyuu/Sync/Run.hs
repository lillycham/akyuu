-- | Manual exchange. Network calls hold only sync.lock. Repository transactions
-- independently capture CURRENT and retain later local export obligations.
module Akyuu.Sync.Run (SyncError (..), SyncPoint (..), configure, runSync, runSyncWith, status, joinReplica, joinReplicaWith, describeSyncError) where

import Akyuu.Fs (atomicWrite, ifMissing, ignoreIO, tryWith)
import Akyuu.Id qualified as Id
import Akyuu.Mutation (withLockFile)
import Akyuu.Sync.Checkpoint (CheckpointId (CheckpointId), checkpointEvents, checkpointObjects, pendingEvents, pendingObjects)
import Akyuu.Sync.Event (eventAction)
import Akyuu.Sync.Git (Bundle (bundlePayloads, bundleState), GitError, Inventory (Inventory, inventoryObjects), ancestor, bundleAt, bundleFor, bundleInventory, describeGitError, fetch, listInventory, prepare, push, readBundle, within, writeBundle)
import Akyuu.Sync.Process (Deadline, deadline)
import Akyuu.Sync.Repository (RepositoryError, acknowledgePublished, archiveIncoming, archiveSnapshot, importState, initialise, loadSnapshot, openRepository, snapshotCheckpoint, snapshotId, snapshotState)
import Akyuu.Sync.State (ResourceState (RefTypeConflict, TopicHeads), State, events, interpret, merge, storeId)
import Akyuu.Sync.Topics (TopicError (StorageError), describeError, initialiseLocal)
import Akyuu.Sync.Types (resourceOf)
import Control.Exception (IOException, displayException)
import Control.Monad (forM_, unless, void, when)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Trans.Except (ExceptT (ExceptT), runExceptT, throwE)
import Data.Aeson (Value, eitherDecodeStrict', encode, object, (.:), (.=))
import Data.Aeson.Types (parseEither, withObject)
import Data.Bifunctor (first)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BL
import Data.Foldable (traverse_)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import System.Directory (createDirectoryIfMissing, doesDirectoryExist, doesFileExist, listDirectory, makeAbsolute, removeFile, renameDirectory)
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
withSync root action = withLockFile (root </> "sync.lock") SyncBusy SyncIO (runExceptT action)

settings :: Text -> Text -> IO (Either SyncError Settings)
settings remote branch = runExceptT $ do
  let full = if "refs/heads/" `T.isPrefixOf` branch then branch else "refs/heads/" <> branch
      pieces = T.splitOn "/" full
      allowed c = c `elem` ['a' .. 'z'] || c `elem` ['A' .. 'Z'] || c `elem` ['0' .. '9'] || c `elem` ['-', '_', '.', '/']
  unless
    ( not (T.null remote)
        && T.strip remote == remote
        && not (T.any (`elem` ['\n', '\r', '\0']) remote)
        && not ("-" `T.isPrefixOf` remote)
    )
    (throwE (SyncInvalid "Give a nonblank remote path or URL."))
  when (("https://" `T.isPrefixOf` remote || "http://" `T.isPrefixOf` remote) && "@" `T.isInfixOf` remote) (throwE (SyncInvalid "Do not put credentials in a remote URL."))
  unless
    ( T.length full <= 200
        && T.all allowed full
        && not (".." `T.isInfixOf` full)
        && all (\p -> not (T.null p) && not ("." `T.isPrefixOf` p) && not ("." `T.isSuffixOf` p) && not (".lock" `T.isSuffixOf` p)) pieces
    )
    (throwE (SyncInvalid "Give a valid branch below refs/heads/."))
  url <- if ":" `T.isInfixOf` remote then pure remote else liftIO (T.pack <$> makeAbsolute (T.unpack remote))
  pure (Settings url full)

settingsJSON :: Settings -> Value
settingsJSON (Settings remote branch) = object ["remote" .= remote, "branch" .= branch]

readSettings :: FilePath -> Work Settings
readSettings root = do
  saved <- liftIO (ifMissing Nothing (Just <$> BS.readFile (root </> "SYNC")))
  bytes <- maybe (throwE (SyncInvalid "This replica has no sync target. Run replica sync-config first.")) pure saved
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
readTip root = readCursor (root </> "SYNC-TIP")

readCursor :: FilePath -> Work (Maybe Text)
readCursor path = do
  bytes <- liftIO (ifMissing Nothing (Just <$> BS.readFile path))
  case bytes of
    Nothing -> pure Nothing
    Just value -> case eitherDecodeStrict' value of
      Right tip | T.length tip == 40 && T.all (\c -> c `elem` ['0' .. '9'] || c `elem` ['a' .. 'f']) tip -> pure (Just tip)
      _ -> throwE (SyncInvalid "The saved remote cursor is invalid.")

-- | Fetch the remote tip. Return the saved cursor and the tip. A tip that
-- does not descend from the cursor is a rewritten remote.
fetchTip :: Deadline -> FilePath -> Settings -> Work (Maybe Text, Maybe Text)
fetchTip end root (Settings remote branch) = do
  let gitRoot = root </> "transport.git"
  old <- readTip root
  tip <- transport (fetch end gitRoot remote branch)
  case (old, tip) of
    (Just _, Nothing) -> throwE RemoteRewritten
    (Just previous, Just current) | previous /= current -> do
      follows <- transport (ancestor end gitRoot previous current)
      unless follows (throwE RemoteRewritten)
    _ -> pure ()
  pure (old, tip)

-- | Read and verify the complete bundle of a fetched tip, then save the tip as
-- the cursor. The cursor therefore always names a verified commit. The tree
-- of the earlier cursor must be a part of the new one: its listing is enough,
-- because that commit was verified when it became the cursor.
verifyTip :: Deadline -> FilePath -> Maybe Text -> Text -> Work Bundle
verifyTip end root old tip = do
  let gitRoot = root </> "transport.git"
  bundle <- transport (readBundle end gitRoot tip)
  forM_ old $ \previous -> when (previous /= tip) $ do
    (accepted, _) <- transport (listInventory end gitRoot previous)
    unless (accepted `within` bundleInventory bundle) (throwE RemoteRewritten)
  remember root (Just tip)
  pure bundle

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
      let gitRoot = root </> "transport.git"
          inventoryOf checkpoint = Inventory (checkpointEvents checkpoint) (checkpointObjects checkpoint)
      (old, tip) <- fetchTip end root config
      liftIO (hook AfterFetch)
      before <- storage (loadSnapshot repo)
      listed <- traverse (transport . listInventory end gitRoot) tip
      -- The cursor names a commit that an earlier sync verified completely.
      -- If the tip is still that commit and the local checkpoint holds all
      -- that its tree names, there is nothing to read or import.
      let current = old == tip && maybe True ((`within` inventoryOf (snapshotCheckpoint before)) . fst) listed
      incoming <- if current then pure Nothing else traverse (verifyTip end root old) tip
      forM_ incoming $ \bundle -> unless (storeId (bundleState bundle) == storeId (snapshotState before)) (throwE (SyncInvalid "The remote belongs to a different memory store."))
      if preview
        then do
          combined <- maybe (pure (snapshotState before)) (either (const (throwE (SyncInvalid "The remote history cannot merge."))) pure . merge (snapshotState before) . bundleState) incoming
          pure
            ( object
                [ "preview" .= True,
                  "checkpoint" .= checkpointText (snapshotId before),
                  "remote_tip" .= tip,
                  "import_events" .= maybe 0 (\bundle -> Set.size (Map.keysSet (events (bundleState bundle)) `Set.difference` Map.keysSet (events (snapshotState before)))) incoming,
                  "conflicts" .= countConflicts combined
                ]
            )
        else do
          forM_ incoming $ \bundle ->
            -- The fetched bundle was fully verified. Accepted inventories only
            -- grow, so a subset needs no import even if another writer
            -- advances CURRENT after this comparison.
            unless (bundleInventory bundle `within` inventoryOf (snapshotCheckpoint before)) (void (storage (importState repo (bundleState bundle) (Map.toList (bundlePayloads bundle)))))
          captured <- storage (loadSnapshot repo)
          let checkpoint = snapshotCheckpoint captured
              mine = inventoryOf checkpoint
              theirs = maybe (Inventory Set.empty Set.empty) fst listed
              idle = Set.null (pendingEvents checkpoint) && Set.null (pendingObjects checkpoint)
          if mine `within` theirs
            then
              if idle
                then report (snapshotId captured) tip False captured
                else do
                  key <- storage (archiveSnapshot repo captured)
                  finish repo key tip False
            else do
              key <- storage (archiveSnapshot repo captured)
              -- After the import, the local inventory names all of the remote
              -- tree. The commit then adds only the files that the tree lacks.
              let base = if theirs `within` mine then listed else Nothing
              outgoing <- transport (maybe (bundleAt captured) (\(inventory, _) -> bundleFor captured (inventoryObjects mine `Set.difference` inventoryObjects inventory)) base)
              commit <- transport (writeBundle end gitRoot tip base outgoing)
              liftIO (hook BeforePush)
              result <- liftIO (push end gitRoot remote branch commit)
              case result of
                Left _ | tries > 1 -> attempt end repo config (tries - 1)
                Left failure -> throwE (SyncGit failure)
                Right () -> do
                  liftIO (hook AfterPush)
                  (cursor, published) <- fetchTip end root config
                  if published == Just commit
                    then do
                      -- The remote tip is the commit that this sync wrote, so
                      -- its content is known without a read.
                      remember root published
                      finish repo key published False
                    else do
                      receipt <- traverse (verifyTip end root cursor) published
                      unless (maybe False ((mine `within`) . bundleInventory) receipt) (throwE PublicationUnconfirmed)
                      finish repo key published (maybe False (not . (`within` mine) . bundleInventory) receipt)
    finish repo key tip more = do
      accepted <- storage (acknowledgePublished repo key)
      report key tip more accepted
    report key tip more accepted = do
      saved <- liftIO (tryWith SyncIO (atomicWrite (root </> "SYNC-PUBLISHED") (BL.toStrict (encode (checkpointText key)))))
      pure
        ( object
            [ "preview" .= False,
              "published_checkpoint" .= checkpointText key,
              "remote_tip" .= tip,
              "remote_changes_remaining" .= more,
              "status_saved" .= either (const False) (const True) saved,
              "checkpoint" .= checkpointText (snapshotId accepted),
              "pending_events" .= Set.size (pendingEvents (snapshotCheckpoint accepted)),
              "pending_objects" .= Set.size (pendingObjects (snapshotCheckpoint accepted)),
              "conflicts" .= countConflicts (snapshotState accepted)
            ]
        )

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
  pure
    ( object
        [ "checkpoint" .= checkpointText (snapshotId snapshot),
          "last_fetched_tip" .= tip,
          "last_published_checkpoint" .= published,
          "last_error" .= failure,
          "pending_events" .= Set.size (pendingEvents (snapshotCheckpoint snapshot)),
          "pending_objects" .= Set.size (pendingObjects (snapshotCheckpoint snapshot)),
          "conflicts" .= countConflicts (snapshotState snapshot)
        ]
    )

countConflicts :: State -> Int
countConflicts state =
  length
    [ ()
    | resource <- Set.toList (Set.fromList (map (resourceOf . eventAction) (Map.elems (events state)))),
      case interpret state resource of
        TopicHeads heads -> Map.size heads > 1
        RefTypeConflict _ -> True
        _ -> False
    ]

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
        _ <- ExceptT (first (SyncInvalid . describeError) <$> initialiseLocal root label)
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
        prior <- readCursor (root </> ".tmp.join-tip")
        forM_ prior $ \previous -> do
          follows <- transport (ancestor end mirror previous tip)
          old <- transport (readBundle end mirror previous)
          unless (follows && storeId (bundleState old) == storeId (bundleState bundle) && bundleInventory old `within` bundleInventory bundle) (throwE RemoteRewritten)
        liftIO (atomicWrite (root </> ".tmp.join-tip") (BL.toStrict (encode tip)))
        repo <- storage (initialise root (storeId (bundleState bundle)))
        _ <- storage (importState repo (bundleState bundle) (Map.toList (bundlePayloads bundle)))
        liftIO (hook JoinImported)
        key <- storage (archiveIncoming repo (bundleState bundle) (Map.keysSet (bundlePayloads bundle)))
        _ <- storage (acknowledgePublished repo key)
        _ <- ExceptT (first (SyncInvalid . describeError) <$> initialiseLocal root label)
        liftIO (hook JoinRegistered)
        unless finalGit (liftIO (renameDirectory mirror (root </> "transport.git")))
        remember root (Just tip)
        liftIO (atomicWrite (root </> "SYNC") (BL.toStrict (encode (settingsJSON config))))
        liftIO (traverse_ (ignoreIO . removeFile . (root </>)) [".tmp.join", ".tmp.join-tip"])
        ExceptT (status root)

describeSyncError :: SyncError -> Text
describeSyncError err = case err of
  SyncGit failure -> describeGitError failure
  SyncStorage failure -> describeError (StorageError failure)
  SyncIO failure -> "A sync file or process operation failed: " <> T.pack (displayException failure) <> ". Pending work is retained."
  SyncInvalid text -> text
  SyncBusy -> "Another sync holds the sync lock."
  RemoteRewritten -> "The remote archive was rewritten or lost accepted entries. Recovery is required."
  PublicationUnconfirmed -> "Remote publication could not be confirmed. Export obligations remain pending."
