-- | Canonical publication manifests. A manifest is authoritative only when
-- CURRENT names its hash and every dependency passes repository validation.
module Akyuu.Sync.Checkpoint
  ( Checkpoint,
    CheckpointId (..),
    checkpointStore,
    checkpointEvents,
    checkpointObjects,
    pendingEvents,
    pendingObjects,
    checkpointId,
    mkCheckpoint,
    renderCheckpoint,
    parseCheckpoint,
    CheckpointError (..),
    maxCheckpointBytes,
  )
where

import Akyuu.Id (Id)
import Akyuu.Id qualified as Id
import Akyuu.Sync.Types (EventId (EventId), StoreId (StoreId), parseIdentifier, renderIdentifier)
import Control.Monad (foldM, unless, when)
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (decodeUtf8', encodeUtf8)

newtype CheckpointId = CheckpointId Id deriving (Eq, Ord, Show)

data Checkpoint = Checkpoint
  { checkpointStore :: StoreId,
    checkpointEvents :: Set EventId,
    checkpointObjects :: Set Id,
    pendingEvents :: Set EventId,
    pendingObjects :: Set Id
  }
  deriving (Eq, Show)

data CheckpointError
  = BadCheckpoint Text
  | NonCanonicalCheckpoint
  | CheckpointTooLarge
  | UnknownPendingEvent
  | UnknownPendingObject
  deriving (Eq, Show)

maxCheckpointBytes :: Int
maxCheckpointBytes = 64 * 1024 * 1024

mkCheckpoint :: StoreId -> Set EventId -> Set Id -> Set EventId -> Set Id -> Either CheckpointError Checkpoint
mkCheckpoint store es objects waitingEvents waitingObjects = do
  unless (waitingEvents `Set.isSubsetOf` es) (Left UnknownPendingEvent)
  unless (waitingObjects `Set.isSubsetOf` objects) (Left UnknownPendingObject)
  let checkpoint = Checkpoint store es objects waitingEvents waitingObjects
  when (BS.length (renderCheckpoint checkpoint) > maxCheckpointBytes) (Left CheckpointTooLarge)
  pure checkpoint

checkpointId :: Checkpoint -> CheckpointId
checkpointId = CheckpointId . Id.hashBytes . renderCheckpoint

renderCheckpoint :: Checkpoint -> ByteString
renderCheckpoint checkpoint = encodeUtf8 (T.unlines fields)
  where
    StoreId store = checkpointStore checkpoint
    fields =
      ["akyuu-sync-checkpoint-v1", "store: " <> renderIdentifier store]
        <> ["event: " <> Id.render digest | EventId digest <- Set.toAscList (checkpointEvents checkpoint)]
        <> ["object: " <> Id.render digest | digest <- Set.toAscList (checkpointObjects checkpoint)]
        <> ["pending-event: " <> Id.render digest | EventId digest <- Set.toAscList (pendingEvents checkpoint)]
        <> ["pending-object: " <> Id.render digest | digest <- Set.toAscList (pendingObjects checkpoint)]

parseCheckpoint :: ByteString -> Either CheckpointError Checkpoint
parseCheckpoint bytes = do
  when (BS.length bytes > maxCheckpointBytes) (Left CheckpointTooLarge)
  text <- first (const (BadCheckpoint "Checkpoint is not UTF-8.")) (decodeUtf8' bytes)
  checkpoint <- case T.lines text of
    "akyuu-sync-checkpoint-v1" : storeLine : entries -> do
      storeText <- maybe (Left (BadCheckpoint "Missing store identity.")) Right (T.stripPrefix "store: " storeLine)
      store <- StoreId <$> first BadCheckpoint (parseIdentifier storeText)
      initial <- mkCheckpoint store Set.empty Set.empty Set.empty Set.empty
      parsed <- foldM entry initial entries
      mkCheckpoint store (checkpointEvents parsed) (checkpointObjects parsed) (pendingEvents parsed) (pendingObjects parsed)
    _ -> Left (BadCheckpoint "Unknown or incomplete checkpoint header.")
  unless (renderCheckpoint checkpoint == bytes) (Left NonCanonicalCheckpoint)
  pure checkpoint
  where
    entry checkpoint line = do
      let (key, suffix) = T.breakOn ": " line
      digest <- first (BadCheckpoint . T.pack . show) (Id.parse (T.drop 2 suffix))
      case key of
        "event" -> Right checkpoint {checkpointEvents = Set.insert (EventId digest) (checkpointEvents checkpoint)}
        "object" -> Right checkpoint {checkpointObjects = Set.insert digest (checkpointObjects checkpoint)}
        "pending-event" -> Right checkpoint {pendingEvents = Set.insert (EventId digest) (pendingEvents checkpoint)}
        "pending-object" -> Right checkpoint {pendingObjects = Set.insert digest (pendingObjects checkpoint)}
        _ -> Left (BadCheckpoint "Unknown checkpoint field.")
