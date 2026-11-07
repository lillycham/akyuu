{-# LANGUAGE OverloadedStrings #-}

module TransportTests (transportTests) where

import Akyuu.Id qualified as Id
import Akyuu.Refs (mkName)
import Akyuu.Sync.Checkpoint (pendingEvents, pendingObjects)
import Akyuu.Sync.Git qualified as Git
import Akyuu.Sync.Process (deadline, runGit)
import Akyuu.Sync.Repository (loadSnapshot, openRepository, snapshotCheckpoint)
import Akyuu.Sync.Run (SyncError (RemoteRewritten), SyncPoint (AfterFetch, AfterPush, BeforePush, JoinImported, JoinRegistered), configure, joinReplica, joinReplicaWith, runSync, runSyncWith)
import Akyuu.Sync.State qualified as State
import Akyuu.Sync.Topics (LocalReplica, TopicError (NeedsResolution), TopicHead (headMemoryId), TopicStatus (Conflicted, Resolved), TopicView (viewHeads, viewStatus, viewVersion), createTopic, initialiseLocal, openLocal, readTopic, replaceTopic, selectTopic)
import Control.Monad (void, when)
import Data.Aeson (Value (Bool, Object))
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.IORef (atomicModifyIORef', newIORef)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Support (right, withTempDir)
import System.Directory (removeFile, renameDirectory)
import System.FilePath ((</>))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))
import TopicsTests (newTopic, onlyHead, topicName)

withPeers :: (FilePath -> FilePath -> LocalReplica -> FilePath -> LocalReplica -> IO a) -> IO a
withPeers action = withTempDir $ \base -> do
  let remote = base </> "remote.git"; a = base </> "a"; b = base </> "b"
  end <- deadline 60
  Git.prepare end remote >>= right
  localA <- initialiseLocal a "a" >>= right
  _ <- createTopic localA topicName (newTopic "shared") >>= right
  configure a (T.pack remote) "akyuu-sync-v1" >>= right
  _ <- runSync a False >>= right
  _ <- joinReplica b (T.pack remote) "akyuu-sync-v1" "b" >>= right
  localB <- openLocal b >>= right
  action remote a localA b localB

edit :: LocalReplica -> Text -> IO ()
edit local body = do
  before <- readTopic local topicName >>= right
  void (replaceTopic local topicName (viewVersion before) (newTopic body) >>= right)

tip :: FilePath -> IO Text
tip remote = do
  end <- deadline 60
  bytes <- runGit end Nothing ["--git-dir", remote, "rev-parse", "refs/heads/akyuu-sync-v1"] "" 128 >>= right
  pure (T.strip (T.pack (BC.unpack bytes)))

malformed :: Text -> FilePath -> BS.ByteString -> IO ()
malformed mode path bytes = withPeers $ \remote _ _ b _ -> do
  end <- deadline 60
  parent <- tip remote
  let mirror = b </> "transport.git"
      stream = "blob\nmark :1\ndata " <> BC.pack (show (BS.length bytes)) <> "\n" <> bytes <> "\ncommit refs/akyuu/attack\ncommitter Test <test@localhost> 1 +0000\ndata 5\ntest\nfrom " <> BC.pack (T.unpack parent) <> "\nM " <> BC.pack (T.unpack mode) <> " :1 " <> BC.pack path <> "\n\ndone\n"
  _ <- runGit end Nothing ["--git-dir", mirror, "fast-import", "--quiet", "--done"] stream 16384 >>= right
  hash <- runGit end Nothing ["--git-dir", mirror, "rev-parse", "refs/akyuu/attack"] "" 128 >>= right
  Git.push end mirror (T.pack remote) "refs/heads/akyuu-sync-v1" (T.strip (T.pack (BC.unpack hash))) >>= right
  repo <- openRepository b >>= right
  before <- loadSnapshot repo >>= right
  outcome <- runSync b False
  assertBool "malformed tree reached live state" (case outcome of Left _ -> True; _ -> False)
  loadSnapshot repo >>= (@?= Right before)

transportTests :: TestTree
transportTests =
  testGroup
    "manual Git sync"
    [ testCase "fresh join has a distinct identity and only its registration pending" $ withPeers $ \_ a localA b localB -> do
        viewA <- readTopic localA topicName >>= right
        viewB <- readTopic localB topicName >>= right
        map headMemoryId (viewHeads viewA) @?= map headMemoryId (viewHeads viewB)
        identityA <- BS.readFile (a </> "REPLICA")
        identityB <- BS.readFile (b </> "REPLICA")
        assertBool "join copied a replica identity" (identityA /= identityB)
        repoB <- openRepository b >>= right
        before <- loadSnapshot repoB >>= right
        Set.size (pendingEvents (snapshotCheckpoint before)) @?= 1
        pendingObjects (snapshotCheckpoint before) @?= Set.empty
        _ <- runSync b False >>= right
        _ <- runSync a False >>= right
        after <- loadSnapshot repoB >>= right
        pendingEvents (snapshotCheckpoint after) @?= Set.empty,
      testCase "unchanged sync preserves the checkpoint and still checks local bytes" $ withPeers $ \_ a localA _ _ -> do
        before <- BS.readFile (a </> "CURRENT")
        _ <- runSync a False >>= right
        BS.readFile (a </> "CURRENT") >>= (@?= before)
        entry <- readTopic localA topicName >>= right >>= onlyHead
        let path = a </> "objects" </> T.unpack (Id.render (headMemoryId entry))
            hook point = when (point == AfterFetch) (BS.writeFile path "corrupt after open")
        outcome <- runSyncWith hook 60 a False
        assertBool "unchanged sync hid local corruption" (case outcome of Left _ -> True; _ -> False)
        BS.readFile (a </> "CURRENT") >>= (@?= before)
        BS.readFile path >>= (@?= "corrupt after open"),
      testCase "join resumption never acknowledges its unpublished local registration" $ withPeers $ \remote _ _ b _ -> do
        identity <- BS.readFile (b </> "REPLICA")
        removeFile (b </> "SYNC")
        _ <- joinReplica b (T.pack remote) "akyuu-sync-v1" "resume" >>= right
        BS.readFile (b </> "REPLICA") >>= (@?= identity)
        repo <- openRepository b >>= right
        after <- loadSnapshot repo >>= right
        Set.size (pendingEvents (snapshotCheckpoint after)) @?= 1,
      testGroup
        "join resumes after durable-stage failures"
        [ testCase (show point) $ withPeers $ \remote _ _ b _ -> do
            let c = b <> "-interrupted"
                hook stage = when (stage == point) (ioError (userError "injected join failure"))
            failed <- joinReplicaWith hook c (T.pack remote) "akyuu-sync-v1" "new"
            assertBool "failure hook did not fire" (case failed of Left _ -> True; _ -> False)
            _ <- joinReplica c (T.pack remote) "akyuu-sync-v1" "resume" >>= right
            repo <- openRepository c >>= right
            after <- loadSnapshot repo >>= right
            Set.size (pendingEvents (snapshotCheckpoint after)) @?= 1
            pendingObjects (snapshotCheckpoint after) @?= Set.empty
        | point <- [JoinImported, JoinRegistered]
        ],
      testCase "offline edits preserve conflicts, explicit resolution and late third branches" $ withPeers $ \remote a localA b localB -> do
        let c = take (length b - 1) b <> "c"
        _ <- joinReplica c (T.pack remote) "akyuu-sync-v1" "c" >>= right
        localC <- openLocal c >>= right
        edit localA "from a"
        edit localB "from b"
        _ <- runSync a False >>= right
        _ <- runSync b False >>= right
        _ <- runSync a False >>= right
        conflict <- readTopic localA topicName >>= right
        viewStatus conflict @?= Conflicted
        length (viewHeads conflict) @?= 2
        replaceTopic localA topicName (viewVersion conflict) (newTopic "overwrite") >>= (@?= Left (NeedsResolution conflict))
        chosen <- case viewHeads conflict of entry : _ -> pure (headMemoryId entry); _ -> assertFailure "No conflict heads."
        _ <- selectTopic localA topicName (viewVersion conflict) chosen >>= right
        _ <- runSync a False >>= right
        _ <- runSync b False >>= right
        readTopic localB topicName >>= right >>= (\view -> viewStatus view @?= Resolved)
        edit localC "late c"
        _ <- runSync c False >>= right
        _ <- runSync a False >>= right
        late <- readTopic localA topicName >>= right
        viewStatus late @?= Conflicted
        length (viewHeads late) @?= 2,
      testCase "dry run fetches without changing CURRENT or the remote branch" $ withPeers $ \remote a localA b localB -> do
        edit localA "remote update"
        _ <- runSync a False >>= right
        edit localB "offline update"
        repo <- openRepository b >>= right
        before <- loadSnapshot repo >>= right
        remoteBefore <- tip remote
        report <- runSync b True >>= right
        case report of Object fields -> KM.lookup "preview" fields @?= Just (Bool True); _ -> assertFailure "Expected a preview object."
        loadSnapshot repo >>= (@?= Right before)
        tip remote >>= (@?= remoteBefore),
      testCase "a push race fetches and retries a fast-forward union" $ withPeers $ \_ a localA b localB -> do
        edit localA "a race"
        edit localB "b race"
        once <- newIORef True
        let hook point = when (point == BeforePush) $ do
              first <- atomicModifyIORef' once (\x -> (False, x))
              when first (void (runSync b False >>= right))
        _ <- runSyncWith hook 60 a False >>= right
        _ <- runSync b False >>= right
        view <- readTopic localB topicName >>= right
        viewStatus view @?= Conflicted
        length (viewHeads view) @?= 2,
      testCase "a later local write is not cleared by an earlier publication receipt" $ withPeers $ \_ a localA _ _ -> do
        edit localA "to publish"
        name <- right (mkName "me/later")
        let hook point = when (point == AfterPush) (void (createTopic localA name (newTopic "later") >>= right))
        _ <- runSyncWith hook 60 a False >>= right
        repo <- openRepository a >>= right
        after <- loadSnapshot repo >>= right
        Set.size (pendingEvents (snapshotCheckpoint after)) @?= 1
        Set.size (pendingObjects (snapshotCheckpoint after)) @?= 1,
      testCase "an interrupted push response recovers without another remote commit" $ withPeers $ \remote a localA _ _ -> do
        edit localA "publication with a lost response"
        let hook point = when (point == AfterPush) (ioError (userError "lost push reply"))
        outcome <- runSyncWith hook 60 a False
        assertBool "lost reply unexpectedly succeeded" (case outcome of Left _ -> True; _ -> False)
        published <- tip remote
        repo <- openRepository a >>= right
        before <- loadSnapshot repo >>= right
        assertBool "uncertain export was acknowledged" (not (Set.null (pendingEvents (snapshotCheckpoint before))))
        _ <- runSync a False >>= right
        tip remote >>= (@?= published)
        after <- loadSnapshot repo >>= right
        pendingEvents (snapshotCheckpoint after) @?= Set.empty,
      testCase "branch rewrites are rejected before live import or acknowledgement" $ withPeers $ \remote a localA b _ -> do
        original <- tip remote
        edit localA "newer"
        _ <- runSync a False >>= right
        _ <- runSync b False >>= right
        repo <- openRepository b >>= right
        before <- loadSnapshot repo >>= right
        end <- deadline 60
        _ <- runGit end Nothing ["--git-dir", remote, "update-ref", "refs/heads/akyuu-sync-v1", T.unpack original] "" 128 >>= right
        runSync b False >>= (@?= Left RemoteRewritten)
        loadSnapshot repo >>= (@?= Right before),
      testCase "a descendant that removes archive entries is rejected" $ withPeers $ \remote _ _ b _ -> do
        end <- deadline 60
        current <- Git.fetch end (b </> "transport.git") (T.pack remote) "refs/heads/akyuu-sync-v1" >>= right >>= maybe (assertFailure "Missing tip") pure
        old <- Git.readBundle end (b </> "transport.git") current >>= right
        let empty = Git.Bundle (State.empty (State.storeId (Git.bundleState old))) Map.empty
        bad <- Git.writeBundle end (b </> "transport.git") (Just current) empty >>= right
        Git.push end (b </> "transport.git") (T.pack remote) "refs/heads/akyuu-sync-v1" bad >>= right
        runSync b False >>= (@?= Left RemoteRewritten),
      testCase "fetch failure retains accepted local writes and export obligations" $ withPeers $ \remote a localA _ _ -> do
        edit localA "offline"
        repo <- openRepository a >>= right
        before <- loadSnapshot repo >>= right
        renameDirectory remote (remote <> "-unavailable")
        result <- runSync a False
        assertBool "fetch failure reported success" (case result of Left _ -> True; _ -> False)
        loadSnapshot repo >>= (@?= Right before),
      testCase "symlink entries are refused" (malformed "120000" "protocol" "elsewhere"),
      testCase "unknown tree entries are refused" (malformed "100644" "unexpected" "untrusted text"),
      testCase "oversized payloads are refused before blob allocation" $ do
        let bytes = BS.replicate (16 * 1024 * 1024 + 1) 0
            digest = T.unpack (Id.render (Id.hashBytes bytes))
        malformed "100644" ("objects/" <> take 2 (drop 7 digest) <> "/" <> digest <> ".md") bytes
    ]
