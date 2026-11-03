-- | Replicated pins and review records. Concurrent sets survive observed clears.
module Akyuu.Sync.Resources (readResource, writeResource, resourceJSON) where

import Akyuu.Id qualified as Id
import Akyuu.Sync.Checkpoint (CheckpointId (CheckpointId))
import Akyuu.Sync.Repository (Snapshot, snapshotId, snapshotState)
import Akyuu.Sync.State (ResourceState (PinState, ReviewState), Version, interpret, version, versionText)
import Akyuu.Sync.Topics (LocalReplica, TopicError (InvalidInput), captureSnapshot, changeResource)
import Akyuu.Sync.Types (Action, EventId (EventId), Resource (PinResource, ReviewResource), ReviewValue (reviewAuthor, reviewReason), resourceOf)
import Data.Aeson (Value, object, (.=))
import Data.Map.Strict qualified as Map
import Data.Text (Text)

readResource :: LocalReplica -> Resource -> IO (Either TopicError Value)
readResource local resource = case resource of
  PinResource _ -> fmap (resourceJSON resource) <$> captureSnapshot local
  ReviewResource _ _ -> fmap (resourceJSON resource) <$> captureSnapshot local
  _ -> pure (Left (InvalidInput "Read a pin or review resource."))

writeResource :: LocalReplica -> Version -> Action -> IO (Either TopicError Value)
writeResource local expected action = fmap (resourceJSON (resourceOf action)) <$> changeResource local expected action

resourceJSON :: Resource -> Snapshot -> Value
resourceJSON resource snapshot = object (["checkpoint" .= Id.render checkpoint, "version" .= versionText (version state resource)] <> details)
  where
    CheckpointId checkpoint = snapshotId snapshot
    state = snapshotState snapshot
    details = case resource of
      PinResource digest -> ["type" .= ("pin" :: Text), "memory" .= Id.render digest, "pinned" .= (interpret state resource == PinState True)]
      ReviewResource a b ->
        let records = case interpret state resource of ReviewState entries -> entries; _ -> Map.empty
         in ["type" .= ("review" :: Text), "a" .= Id.render (min a b), "b" .= Id.render (max a b), "reviewed" .= not (Map.null records), "records" .= [object ["event" .= Id.render digest, "author" .= reviewAuthor value, "reason" .= reviewReason value] | (EventId digest, value) <- Map.toAscList records]]
      _ -> []
