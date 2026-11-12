{-# LANGUAGE OverloadedStrings #-}

module MigrationTests (migrationTests) where

import Akyuu.Id qualified as Id
import Akyuu.Memory (Memory, memoryId)
import Akyuu.Refs (Expected (Unchecked), Ref (Ref), mkName)
import Akyuu.Refs qualified as Refs
import Akyuu.Review qualified as Review
import Akyuu.Store qualified as Store
import Akyuu.Sync.Migration (MigrationPoint (BaselineImported, MigrationArchived, ReplicaRegistered), copyMigration, copyMigrationWith, migrationJSON, migrationToken, planMigration)
import Akyuu.Sync.Repository (loadSnapshot, openRepository, readMemory, snapshotState)
import Akyuu.Sync.Topics (TopicHead (headMemoryId), TopicView (viewHeads), openLocal, readTopic)
import Control.Monad (when)
import Data.Aeson (Value (Object), object, toJSON, (.=))
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString qualified as BS
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Support (right, testMemory, withTempDir)
import System.Directory (createDirectory, doesFileExist, removeFile)
import System.FilePath ((</>))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

fixture :: (FilePath -> Store.Store -> Refs.Refs -> Memory -> IO a) -> IO a
fixture action = withTempDir $ \root -> do
  store <- Store.openStore root >>= right
  refs <- Refs.openRefs root >>= right
  let memory = testMemory "fact" (read "2026-01-01 00:00:00 UTC") "test" Set.empty "legacy body"
  digest <- Store.add store memory >>= right
  name <- right (mkName "me/topic")
  _ <- Refs.setRef refs name Unchecked digest >>= right
  action root store refs memory

kinds :: Map.Map Text Text
kinds = Map.singleton "me/topic" "topic"

migrationTests :: TestTree
migrationTests =
  testGroup
    "legacy snapshot migration"
    [ testCase "classification is explicit and complete" $ fixture $ \root _ _ _ -> do
        planMigration root Map.empty >>= assertLeft
        planMigration root (Map.singleton "me/topic" "guess") >>= assertLeft
        planMigration root (Map.insert "me/missing" "topic" kinds) >>= assertLeft,
      testCase "plan identity is deterministic and binds changed source content" $ fixture $ \root store refs _ -> do
        before <- planMigration root kinds >>= right
        again <- planMigration root kinds >>= right
        migrationToken before @?= migrationToken again
        let memory = testMemory "fact" (read "2026-01-02 00:00:00 UTC") "test" Set.empty "new source"
        digest <- Store.add store memory >>= right
        name <- right (mkName "me/topic")
        _ <- Refs.setRef refs name Unchecked digest >>= right
        after <- planMigration root kinds >>= right
        assertBool "plan token ignored a changed source" (migrationToken before /= migrationToken after)
        withTempDir $ \target -> copyMigration target after (migrationToken before) >>= assertLeft,
      testCase "copy preserves memory bytes and resumes without a second local identity" $ fixture $ \root _ refs memory -> withTempDir $ \target -> do
        plan <- planMigration root kinds >>= right
        name <- right (mkName "me/topic")
        sourceBefore <- Refs.getRef refs name >>= right
        _ <- copyMigration target plan (migrationToken plan) >>= right
        local <- openLocal target >>= right
        view <- readTopic local name >>= right
        map headMemoryId (viewHeads view) @?= [memoryId memory]
        repo <- openRepository target >>= right
        snapshot <- loadSnapshot repo >>= right
        readMemory snapshot (memoryId memory) >>= (@?= Right memory)
        identity <- BS.readFile (target </> "REPLICA")
        _ <- copyMigration target plan (migrationToken plan) >>= right
        BS.readFile (target </> "REPLICA") >>= (@?= identity)
        doesFileExist (target </> ".tmp.migration") >>= (@?= False)
        Refs.getRef refs name >>= (@?= Right sourceBefore)
        doesFileExist (root </> "IDENTITY") >>= (@?= False)
        doesFileExist (target </> "LEGACY") >>= (@?= True),
      testCase "missing historical generations are permitted but missing current values are refused" $ fixture $ \root _ refs memory -> do
        name <- right (mkName "me/topic")
        let missing = Id.hashBytes "collected history"
        BS.writeFile (Refs.refPath refs name) (Refs.renderRef (Ref (memoryId memory) [missing]))
        _ <- planMigration root kinds >>= right
        BS.writeFile (Refs.refPath refs name) (Refs.renderRef (Ref missing [memoryId memory]))
        planMigration root kinds >>= assertLeft,
      testCase "a nested destination cannot alter the legacy source" $ fixture $ \root _ _ _ -> do
        plan <- planMigration root kinds >>= right
        copyMigration (root </> "copy") plan (migrationToken plan) >>= assertLeft
        doesFileExist (root </> "IDENTITY") >>= (@?= False),
      testCase "unrecognised review records cannot disappear during migration" $ fixture $ \root _ _ _ -> do
        createDirectory (root </> "reviewed")
        BS.writeFile (root </> "reviewed" </> "unknown") "invalid review"
        planMigration root kinds >>= assertLeft,
      testCase "a review of a collected memory is reported, not imported" $ fixture $ \root store _ memory -> withTempDir $ \target -> do
        let other = testMemory "fact" (read "2026-01-03 00:00:00 UTC") "test" Set.empty "collected later"
        gone <- Store.add store other >>= right
        Review.review store (memoryId memory) gone (Review.Review "test" (read "2026-01-04 00:00:00 UTC") "distinct") >>= right
        removeFile (Store.objectPath store gone)
        plan <- planMigration root kinds >>= right
        let orphans = case migrationJSON plan of
              Object fields -> case KM.lookup "snapshot" fields of
                Just (Object snapshot) -> KM.lookup "reviews_without_memory" snapshot
                _ -> Nothing
              _ -> Nothing
        orphans @?= Just (toJSON [object ["a" .= Id.render (min gone (memoryId memory)), "b" .= Id.render (max gone (memoryId memory))]])
        _ <- copyMigration target plan (migrationToken plan) >>= right
        pure (),
      testGroup
        "copy resumes after durable-stage failures"
        [ testCase (show point) $ fixture $ \source _ _ _ -> withTempDir $ \target -> do
            plan <- planMigration source kinds >>= right
            let hook stage = when (stage == point) (ioError (userError "injected copy failure"))
            failed <- copyMigrationWith hook target plan (migrationToken plan)
            assertBool "failure hook did not fire" (case failed of Left _ -> True; _ -> False)
            _ <- copyMigration target plan (migrationToken plan) >>= right
            repo <- openRepository target >>= right
            first <- loadSnapshot repo >>= right
            _ <- copyMigration target plan (migrationToken plan) >>= right
            after <- loadSnapshot repo >>= right
            snapshotState after @?= snapshotState first
        | point <- [BaselineImported, ReplicaRegistered, MigrationArchived]
        ]
    ]

assertLeft :: Either e a -> IO ()
assertLeft (Left _) = pure ()
assertLeft _ = assertFailure "Expected refusal."
