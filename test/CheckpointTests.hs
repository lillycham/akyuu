{-# LANGUAGE OverloadedStrings #-}

module CheckpointTests (checkpointTests) where

import Akyuu.Id qualified as Id
import Akyuu.Sync.Checkpoint (CheckpointError (NonCanonicalCheckpoint, PendingObjectEvicted, UnknownEvictedObject, UnknownPendingEvent, UnknownPendingObject), activeObjects, checkpointId, mkCheckpoint, parseCheckpoint, renderCheckpoint, withEvicted)
import Akyuu.Sync.Types (EventId (EventId), StoreId (StoreId), mkIdentifier)
import Data.ByteString qualified as BS
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Text.Encoding (decodeUtf8, encodeUtf8)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

checkpointTests :: TestTree
checkpointTests =
  testGroup
    "Akyuu.Sync.Checkpoint"
    [ testCase "canonical manifest round-trips" $ parseCheckpoint (renderCheckpoint sample) @?= Right sample,
      testCase "eviction metadata round-trips and changes the checkpoint ID" $ do
        let published = must (mkCheckpoint store (Set.singleton event) (Set.singleton object) Set.empty Set.empty)
            evicted = must (withEvicted (Set.singleton object) published)
        activeObjects evicted @?= Set.empty
        parseCheckpoint (renderCheckpoint evicted) @?= Right evicted
        assertBool "residency omitted from checkpoint hash" (checkpointId published /= checkpointId evicted),
      testCase "unaccepted and pending objects cannot be marked evicted" $ do
        withEvicted (Set.singleton object) sample @?= Left PendingObjectEvicted
        withEvicted (Set.singleton (Id.hashBytes "foreign")) sample @?= Left UnknownEvictedObject,
      testCase "hash includes export obligations" $ do
        let acknowledged = must (mkCheckpoint store (Set.singleton event) (Set.singleton object) Set.empty Set.empty)
        assertBool "pending obligations omitted from hash" (checkpointId sample /= checkpointId acknowledged),
      testCase "pending events must be accepted" $
        mkCheckpoint store Set.empty Set.empty (Set.singleton event) Set.empty @?= Left UnknownPendingEvent,
      testCase "pending objects must be accepted" $
        mkCheckpoint store Set.empty Set.empty Set.empty (Set.singleton object) @?= Left UnknownPendingObject,
      testCase "duplicate entries are refused" $ do
        let line = "object: " <> Id.render object <> "\n"
            bytes = encodeUtf8 (T.replace line (line <> line) (decodeUtf8 (renderCheckpoint sample)))
        parseCheckpoint bytes @?= Left NonCanonicalCheckpoint,
      testCase "missing newline is refused" $
        parseCheckpoint (BS.init (renderCheckpoint sample)) @?= Left NonCanonicalCheckpoint,
      testCase "unknown protocol and fields are refused" $ do
        assertBool "unknown protocol accepted" (isLeft (parseCheckpoint "akyuu-sync-checkpoint-v2\n"))
        assertBool "unknown field accepted" (isLeft (parseCheckpoint (renderCheckpoint sample <> "extra: " <> encodeUtf8 (Id.render object) <> "\n"))),
      testCase "invalid UTF-8 is refused" $ assertBool "bad bytes accepted" (isLeft (parseCheckpoint (BS.singleton 255)))
    ]
  where
    store = StoreId (must (mkIdentifier (BS.replicate 16 0)))
    event = EventId (Id.hashBytes "event")
    object = Id.hashBytes "object"
    sample = must (mkCheckpoint store (Set.singleton event) (Set.singleton object) (Set.singleton event) (Set.singleton object))

must :: (Show e) => Either e a -> a
must = either (error . show) id

isLeft :: Either a b -> Bool
isLeft (Left _) = True
isLeft _ = False
