-- | Configured context from one immutable checkpoint. Unresolved control refs
-- remain data with diagnostics; their bodies are never interpreted as a manifest.
module Akyuu.Sync.Context
  ( ContextOptions (..),
    ContextReport (..),
    configuredContext,
    configuredAt,
    resolutionGuard,
    reportJSON,
    renderReport,
  )
where

import Akyuu.Id qualified as Id
import Akyuu.Memory (Memory (memBody))
import Akyuu.Refs (Name, nameText)
import Akyuu.Sync.Checkpoint (CheckpointId (CheckpointId))
import Akyuu.Sync.Logs (LogPage, LogPageOptions (pageCheckpoint), pageAt, pageJSON, renderPage, validatePageOptions)
import Akyuu.Sync.Repository (Snapshot, snapshotId, snapshotState)
import Akyuu.Sync.State (version)
import Akyuu.Sync.Topics (LocalReplica, ResolutionGuard, TopicError (ConfigurationChanged, InvalidInput), TopicHead (headMemory), TopicStatus (Conflicted, LogTopic, Missing, Resolved, TypeConflicted), TopicView (viewHeads, viewName, viewStatus), captureSnapshot, describeError, renderView, topicNames, topicViewAt, viewJSON)
import Akyuu.Sync.Types (Resource (RefResource))
import Akyuu.Tier (Place, parseManifest, placeRefs, tierNames, tierRefs)
import Control.Monad (when)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Trans.Except (ExceptT (ExceptT), runExceptT, throwE)
import Data.Aeson (Value, object, (.=))
import Data.List (nub)
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as T

data ContextOptions = ContextOptions
  { policyRef :: Name,
    manifestRef :: Name,
    wantedTier :: Text,
    wantedPlace :: Maybe Place,
    extraRefs :: [Name],
    logOptions :: LogPageOptions
  }
  deriving (Eq, Show)

data ContextReport = ContextReport
  { contextCheckpoint :: CheckpointId,
    contextTier :: Text,
    contextReady :: Bool,
    contextIssues :: [Text],
    contextEntries :: [TopicView],
    contextLogs :: [LogPage],
    contextOthers :: [Name],
    availableTiers :: [Text],
    maintenanceReady :: Bool
  }
  deriving (Eq, Show)

configuredContext :: LocalReplica -> ContextOptions -> IO (Either TopicError ContextReport)
configuredContext local options = runExceptT $ do
  snapshot <- ExceptT (captureSnapshot local)
  ExceptT (configuredAt snapshot options)

configuredAt :: Snapshot -> ContextOptions -> IO (Either TopicError ContextReport)
configuredAt snapshot options = runExceptT $ do
  ExceptT (pure (validatePageOptions (logOptions options)))
  let CheckpointId captured = snapshotId snapshot
  when (maybe False (/= captured) (pageCheckpoint (logOptions options))) (throwE ConfigurationChanged)
  policy <- ExceptT (topicViewAt snapshot (policyRef options))
  manifest <- ExceptT (topicViewAt snapshot (manifestRef options))
  let controlIssues = issues "Policy" policy <> issues "Tier manifest" manifest
      parsed = resolvedBody manifest >>= either (const Nothing) Just . parseManifest
      parseIssues = case (resolvedBody manifest, parsed) of
        (Just _, Nothing) -> ["The tier manifest is invalid. Repair it before configured expansion."]
        _ -> []
      requested = parsed >>= tierRefs (wantedTier options)
      tierIssues = case (parsed, requested) of
        (Just _, Nothing) -> ["The tier " <> wantedTier options <> " does not exist."]
        _ -> []
      diagnostics = controlIssues <> parseIssues <> tierIssues
      expanded = case (null diagnostics, parsed, requested) of
        (True, Just tiers, Just refs) -> refs <> maybe [] (`placeRefs` tiers) (wantedPlace options)
        _ -> []
      wanted = nub ([policyRef options, manifestRef options] <> expanded <> extraRefs options)
  entries <- traverse (ExceptT . topicViewAt snapshot) wanted
  logs <- liftIO (traverse (\view -> do result <- pageAt snapshot (viewName view) (logOptions options); pure (viewName view, result)) (filter ((== LogTopic) . viewStatus) entries))
  let entryIssues = concatMap (\view -> if viewStatus view == LogTopic then [] else issues "Context" view) (filter (\view -> viewName view `notElem` [policyRef options, manifestRef options]) entries)
      logIssues = ["Context log " <> nameText name <> ": " <> describeError err | (name, Left err) <- logs]
  pure
    ContextReport
      { contextCheckpoint = snapshotId snapshot,
        contextTier = wantedTier options,
        contextReady = null (diagnostics <> entryIssues <> logIssues),
        contextIssues = diagnostics <> entryIssues <> logIssues,
        contextEntries = entries,
        contextLogs = [report | (_, Right report) <- logs],
        contextOthers = filter (`notElem` wanted) (topicNames snapshot),
        availableTiers = maybe [] tierNames parsed,
        maintenanceReady =
          all ((`elem` [Missing, Resolved]) . viewStatus) [policy, manifest]
            && (viewStatus manifest == Missing || isJust parsed)
      }

issues :: Text -> TopicView -> [Text]
issues label view = case viewStatus view of
  Resolved -> []
  Missing -> [label <> " ref " <> nameText (viewName view) <> " is missing."]
  Conflicted -> [label <> " ref " <> nameText (viewName view) <> " has concurrent heads. No version was selected."]
  TypeConflicted -> [label <> " ref " <> nameText (viewName view) <> " has a type conflict."]
  LogTopic -> [label <> " ref " <> nameText (viewName view) <> " is a log."]

resolvedBody :: TopicView -> Maybe Text
resolvedBody view = case (viewStatus view, viewHeads view) of
  (Resolved, [entry]) -> Just (memBody (headMemory entry))
  _ -> Nothing

-- | Repairs to the control refs themselves must remain possible. Missing
-- controls permit initial setup; ambiguous or invalid controls block other
-- resolutions. Version dependencies close the check/publication race.
resolutionGuard :: ContextOptions -> Name -> ResolutionGuard
resolutionGuard options target snapshot
  | target `elem` [policyRef options, manifestRef options] = pure (Right [])
  | otherwise = runExceptT $ do
      report <- ExceptT (configuredAt snapshot options)
      if not (maintenanceReady report)
        then throwE (InvalidInput "Configured policy or tiers are unresolved. Read configured_context and repair the control refs before another resolution.")
        else pure [(RefResource ref, version (snapshotState snapshot) (RefResource ref)) | ref <- nub [policyRef options, manifestRef options]]

reportJSON :: ContextReport -> Value
reportJSON report =
  object
    [ "checkpoint" .= let CheckpointId digest = contextCheckpoint report in Id.render digest,
      "tier" .= contextTier report,
      "ready" .= contextReady report,
      "maintenance_ready" .= maintenanceReady report,
      "issues" .= contextIssues report,
      "topics" .= map viewJSON (contextEntries report),
      "logs" .= map pageJSON (contextLogs report),
      "other_refs" .= map nameText (contextOthers report),
      "available_tiers" .= availableTiers report
    ]

renderReport :: ContextReport -> Text
renderReport report =
  T.unlines
    (["context: " <> contextTier report, "checkpoint: " <> let CheckpointId digest = contextCheckpoint report in Id.render digest, "ready: " <> if contextReady report then "yes" else "no"] <> contextIssues report)
    <> T.concat (map renderView (filter ((/= LogTopic) . viewStatus) (contextEntries report)))
    <> T.concat (map renderPage (contextLogs report))
