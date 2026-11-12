-- | A supported legacy snapshot copy into a separate checkpoint directory.
-- The source is never converted in place. Cutover still requires coordinated
-- writer upgrades, a verified backup, and an explicitly quiescent source.
module Akyuu.Sync.Migration (MigrationPlan, MigrationPoint (..), planMigration, migrationJSON, migrationToken, copyMigration, copyMigrationWith) where

import Akyuu.Fs (atomicWrite, ifMissing, tryWith)
import Akyuu.GC qualified as GC
import Akyuu.Id (Id)
import Akyuu.Id qualified as Id
import Akyuu.Memory (memoryId, mkMemory, renderMemory)
import Akyuu.Mutation (withMutation)
import Akyuu.Refs (Ref (current, history), nameText)
import Akyuu.Refs qualified as Refs
import Akyuu.Review (Review (reviewAgent, reviewAt, reviewNote))
import Akyuu.Review qualified as Review
import Akyuu.Store qualified as Store
import Akyuu.Sync.Event (eventId, mkEvent, renderEvent)
import Akyuu.Sync.Repository (archiveSnapshot, importState, initialise, loadSnapshot, verifyIncoming)
import Akyuu.Sync.Run (SyncError (SyncBusy, SyncIO, SyncInvalid, SyncStorage))
import Akyuu.Sync.State (State, storeId)
import Akyuu.Sync.Topics (initialiseLocal)
import Akyuu.Sync.Types (Action (AppendLog, RegisterReplica, SetPin, SetReview, SetTopic), Nonce (Nonce), ReplicaId (ReplicaId), ReviewValue (ReviewValue), StoreId (StoreId), mkIdentifier)
import Control.Concurrent (threadDelay)
import Control.Monad (forM, forM_, unless, when)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Trans.Except (ExceptT (ExceptT), runExceptT, throwE)
import Data.Aeson (Value, encode, object, (.=))
import Data.Bifunctor (first)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BL
import Data.List (partition, sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (decodeUtf8, encodeUtf8)
import Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import Data.Time.Format (defaultTimeLocale, formatTime)
import System.Directory (canonicalizePath, createDirectoryIfMissing, doesDirectoryExist, doesFileExist, listDirectory, pathIsSymbolicLink)
import System.FileLock (SharedExclusive (Exclusive), withTryFileLock)
import System.FilePath ((</>))

data MigrationPlan = MigrationPlan FilePath Id Id Value State (Map Id BS.ByteString)

data MigrationPoint = BaselineImported | ReplicaRegistered | MigrationArchived deriving (Eq, Show)

migrationToken :: MigrationPlan -> Id
migrationToken (MigrationPlan _ token _ _ _ _) = token

migrationJSON :: MigrationPlan -> Value
migrationJSON (MigrationPlan _ token metadata report _ _) = object ["version" .= Id.render token, "metadata_memory" .= Id.render metadata, "snapshot" .= report, "cutover_complete" .= False]

planMigration :: FilePath -> Map Text Text -> IO (Either SyncError MigrationPlan)
planMigration root classification = do
  valid <- and <$> traverse (doesDirectoryExist . (root </>)) ["store", "refs", "trash"]
  checkpoint <- doesFileExist (root </> "IDENTITY")
  if not valid || checkpoint
    then pure (Left (SyncInvalid "Migration needs an existing legacy store, not a replica."))
    else withMutation root SyncBusy SyncIO $ \_ -> runExceptT $ do
      store <- legacy (Store.openStore root)
      refs <- legacy (Refs.openRefs root)
      names <- legacy (Refs.listRefs refs)
      let wanted = Set.fromList (map nameText names)
      unless (Map.keysSet classification == wanted && all (`elem` ["topic", "log"]) (Map.elems classification)) (throwE (SyncInvalid "Classify every ref exactly once as topic or log. Unknown refs are refused."))
      values <- forM (sortOn nameText names) (\name -> (name,) <$> legacy (Refs.getRef refs name))
      ids <- legacy (Store.list store)
      payloads <-
        Map.fromList
          <$> forM
            ids
            ( \digest -> do
                link <- liftIO (pathIsSymbolicLink (Store.objectPath store digest))
                when link (throwE (SyncInvalid "A legacy object is a symlink."))
                memory <- legacy (Store.getVerified store digest)
                pure (digest, renderMemory memory)
            )
      pins <- legacy (GC.listPins store)
      reviews <- legacy (Review.listReviews store)
      tombstones <- legacy (GC.listTombstones store)
      forM_ values $ \(_, ref) -> unless (Map.member (current ref) payloads) (throwE (SyncInvalid "A current ref has no available memory."))
      unless (pins `Set.isSubsetOf` Map.keysSet payloads) (throwE (SyncInvalid "A pin has no available memory."))
      reviewNames <- liftIO (ifMissing [] (listDirectory (root </> "reviewed")))
      unless (length reviewNames == length reviews && all (\(_, review) -> not (T.null (T.strip (reviewAgent review)))) reviews) (throwE (SyncInvalid "A legacy review is malformed. Repair it before migration."))
      forM_ reviews $ \((a, b), review) -> do
        raw <- liftIO (BS.readFile (Review.reviewPath store a b))
        let expectedHeaders = ["agent: " <> reviewAgent review, "reviewed: " <> T.pack (formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" (reviewAt review)), "verdict: distinct"]
        unless (takeWhile (not . T.null) (T.lines (decodeUtf8 raw)) == expectedHeaders) (throwE (SyncInvalid "A legacy review has invalid headers. Repair it before migration."))
      -- Legacy GC keeps a review record after it collects a reviewed memory.
      -- Such a record has no pair left to describe: report it, do not import it.
      let (liveReviews, orphanReviews) = partition (\((a, b), _) -> Map.member a payloads && Map.member b payloads) reviews
      let refsJSON = [object ["ref" .= nameText name, "type" .= (classification Map.! nameText name), "current" .= Id.render (current ref), "generations" .= map Id.render (history ref), "missing_generations" .= [Id.render i | i <- history ref, Map.notMember i payloads]] | (name, ref) <- values]
          report = object ["refs" .= refsJSON, "objects" .= map Id.render (Map.keys payloads), "pins" .= map Id.render (Set.toAscList pins), "reviews" .= [object ["a" .= Id.render a, "b" .= Id.render b, "author" .= reviewAgent review, "at" .= reviewAt review, "reason" .= reviewNote review] | ((a, b), review) <- reviews], "reviews_without_memory" .= [object ["a" .= Id.render a, "b" .= Id.render b] | ((a, b), _) <- orphanReviews], "tombstones" .= [object ["memory" .= Id.render i, "record" .= decodeUtf8 (GC.renderTombstone tombstone)] | (i, tombstone) <- tombstones], "baseline_time" .= ("1970-01-01T00:00:00Z: import sentinel; original action dates are unknown" :: Text)]
          fingerprint = Id.hashBytes (BL.toStrict (encode report))
          identifier tag = either (error . T.unpack) id (mkIdentifier (BS.take 16 (Id.toBytes (Id.hashBytes (tag <> Id.toBytes fingerprint)))))
          identity = StoreId (identifier "store")
          replica = ReplicaId (identifier "baseline")
          make tag parents action = first (SyncInvalid . T.pack . show) (mkEvent identity replica (Nonce (identifier tag)) (Set.fromList (map eventId parents)) action (posixSecondsToUTCTime 0))
      registration <- either throwE pure (make "registration" [] (RegisterReplica replica "Legacy snapshot baseline"))
      refEvents <- fmap concat $ forM values $ \(name, ref) -> do
        let kind = classification Map.! nameText name
            available = reverse (filter (`Map.member` payloads) (current ref : history ref))
            build [] _ [] = Right []
            build acc previous (i : rest) = do
              event <- make ("topic:" <> encodeUtf8 (nameText name) <> BS.pack [0] <> Id.toBytes i <> encodeUtf8 (T.pack (show (length acc)))) previous (SetTopic name i)
              build (event : acc) [event] rest
            build acc _ [] = Right acc
        if kind == "log"
          then (: []) <$> either throwE pure (make ("log:" <> encodeUtf8 (nameText name)) [] (AppendLog name (current ref)))
          else either throwE pure (build [] [] available)
      pinEvents <- traverse (\i -> either throwE pure (make ("pin:" <> Id.toBytes i) [] (SetPin i))) (Set.toAscList pins)
      reviewEvents <- traverse (\((a, b), review) -> either throwE pure (make ("review:" <> Id.toBytes a <> Id.toBytes b) [] (SetReview a b (ReviewValue (reviewAgent review) (reviewNote review))))) liveReviews
      let allEvents = registration : refEvents <> pinEvents <> reviewEvents
      metadata <- either (throwE . SyncInvalid . T.pack . show) pure (mkMemory "legacy-baseline" (posixSecondsToUTCTime 0) "migration" Set.empty (decodeUtf8 (BL.toStrict (encode report))))
      let complete = Map.insert (memoryId metadata) (renderMemory metadata) payloads
      state <- ExceptT (first SyncStorage <$> verifyIncoming identity [(eventId event, renderEvent event) | event <- allEvents] (Map.toList complete))
      source <- liftIO (canonicalizePath root)
      pure (MigrationPlan source fingerprint (memoryId metadata) report state complete)
  where
    legacy action = ExceptT (fmap (first (SyncInvalid . T.pack . show)) action)

-- | The source plan is rechecked before a copy. Resumption can only repeat the
-- same deterministic baseline. The source remains untouched and still live.
copyMigration :: FilePath -> MigrationPlan -> Id -> IO (Either SyncError Value)
copyMigration = copyMigrationWith (const (pure ()))

copyMigrationWith :: (MigrationPoint -> IO ()) -> FilePath -> MigrationPlan -> Id -> IO (Either SyncError Value)
copyMigrationWith hook target plan@(MigrationPlan source token _ _ state payloads) expected
  | expected /= token = pure (Left (SyncInvalid "The legacy snapshot changed. Read a new migration plan."))
  | otherwise = do
      created <- tryWith SyncIO $ do
        destination <- canonicalizePath target
        if destination == source || (source <> "/") `prefix` destination
          then pure False
          else createDirectoryIfMissing True target >> pure True
      case created of
        Left err -> pure (Left err)
        Right False -> pure (Left (SyncInvalid "Migration needs a separate destination outside the source."))
        Right True -> withMigrationLock target $ runExceptT $ do
          prior <- liftIO (ifMissing Nothing (Just <$> BS.readFile (target </> ".tmp.migration")))
          let journal = encodeUtf8 (Id.render token <> "\n")
          case prior of
            Just bytes -> unless (bytes == journal) (throwE (SyncInvalid "This target has a different migration journal."))
            Nothing -> do
              entries <- liftIO (listDirectory target)
              unless (all (== ".tmp.migration.lock") entries) (throwE (SyncInvalid "Migration needs an empty destination."))
              liftIO (atomicWrite (target </> ".tmp.migration") journal)
          repo <- storage (initialise target (storeId state))
          _ <- storage (importState repo state (Map.toList payloads))
          liftIO (hook BaselineImported)
          _ <- ExceptT (first (SyncInvalid . T.pack . show) <$> initialiseLocal target "Migrated replica")
          liftIO (hook ReplicaRegistered)
          captured <- storage (loadSnapshot repo)
          _ <- storage (archiveSnapshot repo captured)
          liftIO (hook MigrationArchived)
          liftIO (atomicWrite (target </> "LEGACY") (BL.toStrict (encode (migrationJSON plan))))
          pure (migrationJSON plan)
  where
    storage action = ExceptT (first SyncStorage <$> action)
    prefix a b = take (length a) b == a

withMigrationLock :: FilePath -> IO (Either SyncError a) -> IO (Either SyncError a)
withMigrationLock target action = go (100 :: Int)
  where
    go 0 = pure (Left SyncBusy)
    go n = do
      outcome <- tryWith SyncIO (withTryFileLock (target </> ".tmp.migration.lock") Exclusive (const action))
      case outcome of
        Left err -> pure (Left err)
        Right Nothing -> threadDelay 10000 >> go (n - 1)
        Right (Just value) -> pure value
