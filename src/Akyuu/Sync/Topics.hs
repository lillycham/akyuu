-- | Local topic operations for experimental checkpoint repositories. Each read
-- captures one checkpoint. Writers validate its resource token again under lock.
module Akyuu.Sync.Topics
  ( LocalReplica,
    TopicError (..),
    TopicStatus (..),
    TopicHead (..),
    TopicView (..),
    TopicContext (..),
    initialiseLocal,
    openLocal,
    readTopic,
    captureSnapshot,
    topicViewAt,
    topicNames,
    contextTopics,
    conflicts,
    createTopic,
    replaceTopic,
    resolveTopic,
    selectTopic,
    resolveTopicGuarded,
    selectTopicGuarded,
    resolveLogGuarded,
    appendLogChecked,
    changeResource,
    ResolutionGuard,
    viewJSON,
    contextJSON,
    errorJSON,
    renderView,
    describeError,
  )
where

import Akyuu.Error (describe, describeParse)
import Akyuu.Fs (atomicWrite, ifMissing, tryWith)
import Akyuu.Graph (Edge (Edge, kind, target), EdgeType (Follows, Supersedes))
import Akyuu.Id (Id)
import Akyuu.Id qualified as Id
import Akyuu.Memory (Memory (memAboutRefs, memAgent, memBody, memCreated, memEdges, memKind), edgeToHeader, memoryId, renderMemory)
import Akyuu.Mutation (withMutation)
import Akyuu.Ops (NewMemory (newAboutRefs, newBody, newEdges), buildMemory)
import Akyuu.Refs (Name, nameText)
import Akyuu.Sync.Checkpoint (CheckpointId (CheckpointId))
import Akyuu.Sync.Event (describeEventError, eventAction, eventReplica, eventTime, mkEvent)
import Akyuu.Sync.Repository (Repository, RepositoryError (ArchiveNotAccepted, CollectionIncomplete, CorruptData, IdentityMismatch, InvalidCheckpoint, InvalidMemory, InvalidPointer, InvalidResidency, InvalidRetentionDepth, InvalidState, MissingCheckpoint, MissingCurrent, MissingLogPredecessor, MissingPayload, MissingRetainedTarget, NotRepository, OversizedData, PublicationUncertain, RepositoryBusy, RepositoryIO, StaleCheckpoint, UnacceptedObject), Snapshot, commitLocal, initialise, loadSnapshot, openRepository, readMemory, readStoreIdentity, snapshotId, snapshotState)
import Akyuu.Sync.Repository qualified as Repository
import Akyuu.Sync.State (RefKind (LogKind, TopicKind), ResourceState (Absent, LogHeads, RefTypeConflict, Registered, TopicHeads), StateError (StaleVersion), Version, events, interpret, resourceHeads, storeId, version, versionText)
import Akyuu.Sync.State qualified as State
import Akyuu.Sync.Types (Action (AppendLog, ClearPin, ClearReview, RegisterReplica, ResolveLog, ResolveTopic, SetPin, SetReview, SetTopic), EventId (EventId), Identifier, Nonce (Nonce), ReplicaId (ReplicaId), Resource (RefResource, RegistryResource), ReviewValue (reviewAuthor, reviewReason), StoreId (StoreId), mkIdentifier, parseIdentifier, renderIdentifier, resourceOf)
import Control.Exception (IOException, displayException)
import Control.Monad (join, unless, when)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Trans.Except (ExceptT (ExceptT), runExceptT, throwE, withExceptT)
import Data.Aeson (Value, object, (.=))
import Data.Bifunctor (first)
import Data.ByteString qualified as BS
import Data.Foldable (traverse_)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (decodeUtf8', encodeUtf8)
import Data.Time (UTCTime, getCurrentTime)
import Data.Time.Clock.POSIX (posixSecondsToUTCTime, utcTimeToPOSIXSeconds)
import System.Directory (canonicalizePath, doesFileExist)
import System.FilePath ((</>))
import System.IO (IOMode (ReadMode), withBinaryFile)

data LocalReplica = LocalReplica Repository ReplicaId deriving (Eq, Show)

data TopicStatus = Missing | Resolved | Conflicted | TypeConflicted | LogTopic deriving (Eq, Show)

data TopicHead = TopicHead
  { headEvent :: EventId,
    headMemoryId :: Id,
    headKind :: RefKind,
    headMemory :: Memory,
    headReplica :: ReplicaId,
    headTime :: UTCTime
  }
  deriving (Eq, Show)

data TopicView = TopicView
  { viewCheckpoint :: CheckpointId,
    viewName :: Name,
    viewVersion :: Version,
    viewStatus :: TopicStatus,
    viewHeads :: [TopicHead]
  }
  deriving (Eq, Show)

data TopicContext = TopicContext CheckpointId [TopicView] deriving (Eq, Show)

data TopicError
  = StorageError RepositoryError
  | TopicIO IOException
  | InvalidInput Text
  | MissingTopic Name
  | ExistingTopic TopicView
  | NeedsResolution TopicView
  | StaleTopic TopicView
  | IsLog Name
  | InvalidSelection Id
  | UnregisteredReplica ReplicaId
  | ConfigurationChanged
  | TextIndexFailed Text
  | StaleResource Resource Version
  deriving (Eq, Show)

storage :: IO (Either RepositoryError a) -> ExceptT TopicError IO a
storage = withExceptT StorageError . ExceptT

freshIdentifier :: IO Identifier
freshIdentifier = withBinaryFile "/dev/urandom" ReadMode $ \handle -> do
  bytes <- BS.hGet handle 16
  either (ioError . userError . T.unpack) pure (mkIdentifier bytes)

freshEventData :: IO (Nonce, UTCTime)
freshEventData = do
  nonce <- Nonce <$> freshIdentifier
  now <- getCurrentTime
  pure (nonce, posixSecondsToUTCTime (fromInteger (floor (utcTimeToPOSIXSeconds now))))

-- | Local identity is not replicated. Registration is retryable after a crash
-- between the local identity write and its checkpoint transaction.
initialiseLocal :: FilePath -> Text -> IO (Either TopicError LocalReplica)
initialiseLocal path label = fmap join $ tryWith TopicIO $ runExceptT $ do
  hasIdentity <- liftIO (doesFileExist (path </> "IDENTITY"))
  store <- if hasIdentity then storage (readStoreIdentity path) else liftIO (StoreId <$> freshIdentifier)
  repo <- storage (initialise path store)
  root <- liftIO (canonicalizePath path)
  replica <- ExceptT $ withMutation root (StorageError RepositoryBusy) (StorageError . RepositoryIO) $ \_ -> runExceptT $ do
    bytes <- liftIO (ifMissing Nothing (Just <$> readLocalBytes root))
    case bytes of
      Just value -> either throwE pure (parseLocal value)
      Nothing -> do
        who <- liftIO (ReplicaId <$> freshIdentifier)
        liftIO (atomicWrite (root </> "REPLICA") (localBytes who))
        pure who
  register repo replica (3 :: Int)
  pure (LocalReplica repo replica)
  where
    register repo replica tries = do
      snapshot <- storage (loadSnapshot repo)
      let state = snapshotState snapshot
      case interpret state RegistryResource of
        Registered entries | Map.member replica entries -> pure ()
        _ -> do
          (nonce, now) <- liftIO freshEventData
          event <-
            either (throwE . InvalidInput . describeEventError) pure $
              mkEvent (storeId state) replica nonce (Map.keysSet (resourceHeads state RegistryResource)) (RegisterReplica replica label) now
          result <- liftIO (commitLocal repo (version state RegistryResource) event [])
          case result of
            Left (InvalidState StaleVersion) | tries > 1 -> register repo replica (tries - 1)
            _ -> either (throwE . StorageError) (const (pure ())) result

openLocal :: FilePath -> IO (Either TopicError LocalReplica)
openLocal path = fmap join $ tryWith TopicIO $ runExceptT $ do
  repo <- storage (openRepository path)
  saved <- liftIO (ifMissing Nothing (Just <$> readLocalBytes path))
  bytes <- maybe (throwE (InvalidInput "No local replica identity exists. Run replica init to complete initialisation.")) pure saved
  replica <- either throwE pure (parseLocal bytes)
  snapshot <- storage (loadSnapshot repo)
  case interpret (snapshotState snapshot) RegistryResource of
    Registered entries | Map.member replica entries -> pure (LocalReplica repo replica)
    _ -> throwE (UnregisteredReplica replica)

localBytes :: ReplicaId -> BS.ByteString
localBytes (ReplicaId replica) = "akyuu-local-replica-v1\n" <> encodeUtf8 (renderIdentifier replica) <> "\n"

readLocalBytes :: FilePath -> IO BS.ByteString
readLocalBytes root = withBinaryFile (root </> "REPLICA") ReadMode (\handle -> BS.hGet handle 257)

parseLocal :: BS.ByteString -> Either TopicError ReplicaId
parseLocal bytes = do
  text <- first (const (InvalidInput "Local replica identity is not UTF-8.")) (decodeUtf8' bytes)
  who <- case T.lines text of
    ["akyuu-local-replica-v1", value] -> ReplicaId <$> first InvalidInput (parseIdentifier value)
    _ -> Left (InvalidInput "Invalid local replica identity. Use replica init to complete initialisation.")
  unless (localBytes who == bytes) (Left (InvalidInput "Invalid local replica identity."))
  pure who

readTopic :: LocalReplica -> Name -> IO (Either TopicError TopicView)
readTopic (LocalReplica repo _) name = runExceptT $ storage (loadSnapshot repo) >>= (`viewAt` name)

captureSnapshot :: LocalReplica -> IO (Either TopicError Snapshot)
captureSnapshot (LocalReplica repo _) = runExceptT (storage (loadSnapshot repo))

topicViewAt :: Snapshot -> Name -> IO (Either TopicError TopicView)
topicViewAt snapshot name = runExceptT (viewAt snapshot name)

topicNames :: Snapshot -> [Name]
topicNames snapshot = Set.toAscList (Set.fromList [name | event <- Map.elems (events (snapshotState snapshot)), RefResource name <- [resourceOf (eventAction event)]])

viewAt :: Snapshot -> Name -> ExceptT TopicError IO TopicView
viewAt snapshot name = do
  heads <- traverse readHead (Map.toAscList (resourceHeads state (RefResource name)))
  let status = case interpret state (RefResource name) of
        Absent -> Missing
        TopicHeads values -> if Map.size values == 1 then Resolved else Conflicted
        LogHeads _ -> LogTopic
        RefTypeConflict _ -> TypeConflicted
        _ -> Missing
  pure (TopicView (snapshotId snapshot) name (version state (RefResource name)) status heads)
  where
    state = snapshotState snapshot
    readHead (key, event) = do
      (kind, digest) <- case eventAction event of
        SetTopic _ value -> pure (TopicKind, value)
        ResolveTopic _ value -> pure (TopicKind, value)
        -- Log actions can appear through imports before log writing is exposed.
        action -> case action of
          AppendLog _ value -> pure (LogKind, value)
          ResolveLog _ value -> pure (LogKind, value)
          _ -> throwE (InvalidInput "Invalid ref action.")
      memory <- storage (readMemory snapshot digest)
      pure (TopicHead key digest kind memory (eventReplica event) (eventTime event))

contextTopics :: LocalReplica -> [Name] -> IO (Either TopicError TopicContext)
contextTopics (LocalReplica repo _) names = runExceptT $ do
  snapshot <- storage (loadSnapshot repo)
  TopicContext (snapshotId snapshot) <$> traverse (viewAt snapshot) (Set.toAscList (Set.fromList names))

conflicts :: LocalReplica -> IO (Either TopicError TopicContext)
conflicts (LocalReplica repo _) = runExceptT $ do
  snapshot <- storage (loadSnapshot repo)
  let state = snapshotState snapshot
      names = Set.fromList [name | event <- Map.elems (events state), RefResource name <- [resourceOf (eventAction event)]]
  views <- traverse (viewAt snapshot) (Set.toAscList names)
  pure (TopicContext (snapshotId snapshot) (filter (\view -> viewStatus view `elem` [Conflicted, TypeConflicted]) views))

createTopic :: LocalReplica -> Name -> NewMemory -> IO (Either TopicError TopicView)
createTopic local name new = writeTopic local name (CreateWrite new)

replaceTopic :: LocalReplica -> Name -> Version -> NewMemory -> IO (Either TopicError TopicView)
replaceTopic local name expected new = writeTopic local name (ReplaceWrite expected new)

resolveTopic :: LocalReplica -> Name -> Version -> NewMemory -> IO (Either TopicError TopicView)
resolveTopic local name expected new = writeTopic local name (ResolveWrite expected (Right new))

selectTopic :: LocalReplica -> Name -> Version -> Id -> IO (Either TopicError TopicView)
selectTopic local name expected selected = writeTopic local name (ResolveWrite expected (Left selected))

type ResolutionGuard = Snapshot -> IO (Either TopicError [(Resource, Version)])

resolveTopicGuarded :: ResolutionGuard -> LocalReplica -> Name -> Version -> NewMemory -> IO (Either TopicError TopicView)
resolveTopicGuarded guard local name expected new = writeTopicWith guard local name (ResolveWrite expected (Right new))

selectTopicGuarded :: ResolutionGuard -> LocalReplica -> Name -> Version -> Id -> IO (Either TopicError TopicView)
selectTopicGuarded guard local name expected selected = writeTopicWith guard local name (ResolveWrite expected (Left selected))

-- | Resolve a type conflict in favour of the log. The new episode follows
-- every current log head, so the log keeps its whole history. The topic heads
-- are consumed and their memories leave the ref.
resolveLogGuarded :: ResolutionGuard -> LocalReplica -> Name -> Version -> NewMemory -> IO (Either TopicError TopicView)
resolveLogGuarded guard local name expected new = writeTopicWith guard local name (ResolveLogWrite expected new)

-- | Pin/review sets and observed clears use the same durable event transaction
-- as topics. GC never calls this function or invents a removal event.
changeResource :: LocalReplica -> Version -> Action -> IO (Either TopicError Snapshot)
changeResource (LocalReplica repo replica) expected action = fmap join $ tryWith TopicIO $ runExceptT $ do
  snapshot <- storage (loadSnapshot repo)
  let state = snapshotState snapshot
      resource = resourceOf action
      token = version state resource
  targets <- case action of
    SetPin digest -> pure [digest]
    ClearPin _ -> pure []
    SetReview a b value -> do
      when (T.null (T.strip (reviewAuthor value)) || T.null (T.strip (reviewReason value))) (throwE (InvalidInput "A review needs a nonblank author and reason."))
      when (a == b) (throwE (InvalidInput "A review needs two different memory IDs."))
      pure [a, b]
    ClearReview _ _ -> pure []
    _ -> throwE (InvalidInput "This operation accepts only pin and review changes.")
  unless (expected == token) (throwE (StaleResource resource token))
  traverse_ (storage . readMemory snapshot) targets
  (nonce, now) <- liftIO freshEventData
  event <- either (throwE . InvalidInput . describeEventError) pure (mkEvent (storeId state) replica nonce (Map.keysSet (resourceHeads state resource)) action now)
  result <- liftIO (commitLocal repo expected event [])
  case result of
    Left (InvalidState StaleVersion) -> do
      latest <- storage (loadSnapshot repo)
      throwE (StaleResource resource (version (snapshotState latest) resource))
    Left failure -> throwE (StorageError failure)
    Right accepted -> pure accepted

-- | Append to every observed log head. The caller can bind a summary to the
-- versions of its source levels. Both the target and those dependencies are
-- checked again inside the repository transaction.
appendLogChecked :: LocalReplica -> Name -> Version -> NewMemory -> [(Resource, Version)] -> IO (Either TopicError TopicView)
appendLogChecked local@(LocalReplica repo replica) name expected input checks = fmap join $ tryWith TopicIO $ runExceptT $ do
  snapshot <- storage (loadSnapshot repo)
  view <- viewAt snapshot name
  unless (expected == viewVersion view) (throwE (StaleTopic view))
  unless (viewStatus view `elem` [Missing, LogTopic]) (throwE (NeedsResolution view))
  when (T.null (T.strip (newBody input))) (throwE (InvalidInput "An episode body must not be blank."))
  when (any ((== Follows) . kind) (Set.toList (newEdges input))) (throwE (InvalidInput "Log append supplies the follows edges. Do not supply them yourself."))
  let state = snapshotState snapshot
  traverse_ (\target -> when (interpret state (RefResource target) == Absent) (throwE (InvalidInput ("The linked topic " <> nameText target <> " does not exist.")))) (Set.toList (newAboutRefs input))
  (nonce, now) <- liftIO freshEventData
  let predecessors = Set.fromList [Edge Follows (headMemoryId entry) | entry <- viewHeads view]
  memory <- either (throwE . InvalidInput . describe) pure (buildMemory now input {newEdges = newEdges input <> predecessors})
  event <- either (throwE . InvalidInput . describeEventError) pure (mkEvent (storeId state) replica nonce (Map.keysSet (resourceHeads state (RefResource name))) (AppendLog name (memoryId memory)) now)
  result <- liftIO (Repository.commitLocalChecked repo expected event [(memoryId memory, renderMemory memory)] checks)
  case result of
    Left (InvalidState StaleVersion) -> ExceptT (readTopic local name) >>= throwE . StaleTopic
    Left (InvalidState (State.StaleDependency _)) -> throwE (InvalidInput "The summary sources changed. Read the log levels before another summary.")
    Left err -> throwE (StorageError err)
    Right accepted -> viewAt accepted name

data TopicWrite = CreateWrite NewMemory | ReplaceWrite Version NewMemory | ResolveWrite Version (Either Id NewMemory) | ResolveLogWrite Version NewMemory

writeTopic :: LocalReplica -> Name -> TopicWrite -> IO (Either TopicError TopicView)
writeTopic = writeTopicWith (const (pure (Right [])))

writeTopicWith :: ResolutionGuard -> LocalReplica -> Name -> TopicWrite -> IO (Either TopicError TopicView)
writeTopicWith guard local@(LocalReplica repo replica) name operation = fmap join $ tryWith TopicIO $ runExceptT $ do
  snapshot <- storage (loadSnapshot repo)
  view <- viewAt snapshot name
  let state = snapshotState snapshot
      creating = case operation of CreateWrite _ -> True; _ -> False
      resolving = case operation of ResolveWrite _ _ -> True; ResolveLogWrite _ _ -> True; _ -> False
      asLog = case operation of ResolveLogWrite _ _ -> True; _ -> False
      expected = case operation of CreateWrite _ -> Nothing; ReplaceWrite token _ -> Just token; ResolveWrite token _ -> Just token; ResolveLogWrite token _ -> Just token
      content = case operation of CreateWrite input -> Right input; ReplaceWrite _ input -> Right input; ResolveWrite _ choice -> choice; ResolveLogWrite _ input -> Right input
  forExpected view expected
  checks <- if resolving then ExceptT (guard snapshot) else pure []
  when (creating && viewStatus view /= Missing) (throwE (ExistingTopic view))
  unless creating $ do
    when (viewStatus view == Missing) (throwE (MissingTopic name))
    when (viewStatus view == LogTopic) (throwE (IsLog name))
    when (not resolving && viewStatus view `elem` [Conflicted, TypeConflicted]) (throwE (NeedsResolution view))
    when (asLog && viewStatus view /= TypeConflicted) (throwE (InvalidInput "Only a topic and log type conflict can resolve to a log."))
  (nonce, now) <- liftIO freshEventData
  (digest, payloads) <- case content of
    Right input -> do
      when (T.null (T.strip (newBody input))) (throwE (InvalidInput "A topic body must not be blank."))
      traverse_ (checkLink state) (Set.toAscList (newAboutRefs input))
      when (asLog && any ((== Follows) . kind) (Set.toList (newEdges input))) (throwE (InvalidInput "Log resolution supplies the follows edges. Do not supply them yourself."))
      let replaced
            | creating = Set.empty
            | asLog = Set.fromList [Edge Follows (headMemoryId entry) | entry <- viewHeads view, headKind entry == LogKind]
            | otherwise = Set.fromList [Edge Supersedes (headMemoryId entry) | entry <- viewHeads view]
      memory <- either (throwE . InvalidInput . describe) pure (buildMemory now input {newEdges = newEdges input <> replaced})
      pure (memoryId memory, [(memoryId memory, renderMemory memory)])
    Left choice -> do
      unless (choice `elem` map headMemoryId (viewHeads view)) (throwE (InvalidSelection choice))
      pure (choice, [])
  let parents = Map.keysSet (resourceHeads state (RefResource name))
      action
        | asLog = ResolveLog name digest
        | resolving = ResolveTopic name digest
        | otherwise = SetTopic name digest
  event <- either (throwE . InvalidInput . describeEventError) pure (mkEvent (storeId state) replica nonce parents action now)
  result <- liftIO (Repository.commitLocalChecked repo (viewVersion view) event payloads checks)
  case result of
    Left (InvalidState StaleVersion) -> do
      latest <- ExceptT (readTopic local name)
      throwE (StaleTopic latest)
    Left (InvalidState (State.StaleDependency _)) -> throwE ConfigurationChanged
    Left err -> throwE (StorageError err)
    Right accepted -> viewAt accepted name
  where
    forExpected view (Just token) = unless (token == viewVersion view) (throwE (StaleTopic view))
    forExpected _ Nothing = pure ()
    checkLink state target = case interpret state (RefResource target) of
      Absent -> throwE (InvalidInput ("The linked topic " <> nameText target <> " does not exist."))
      _ -> pure ()

viewJSON :: TopicView -> Value
viewJSON view =
  object
    [ "checkpoint" .= checkpointText (viewCheckpoint view),
      "topic" .= nameText (viewName view),
      "version" .= versionText (viewVersion view),
      "status" .= statusText (viewStatus view),
      "heads" .= map headJSON (viewHeads view)
    ]
  where
    headJSON entry =
      object
        [ "event" .= eventText (headEvent entry),
          "memory" .= Id.render (headMemoryId entry),
          "type" .= (case headKind entry of TopicKind -> "topic"; LogKind -> "log" :: Text),
          "replica" .= replicaText (headReplica entry),
          "recorded_at" .= headTime entry,
          "kind" .= memKind (headMemory entry),
          "agent" .= memAgent (headMemory entry),
          "created" .= memCreated (headMemory entry),
          "body" .= memBody (headMemory entry),
          "about_refs" .= map nameText (Set.toAscList (memAboutRefs (headMemory entry))),
          "edges" .= [object ["kind" .= edgeToHeader (kind edge), "target" .= Id.render (target edge)] | edge <- Set.toAscList (memEdges (headMemory entry))]
        ]

contextJSON :: TopicContext -> Value
contextJSON (TopicContext checkpoint views) = object ["checkpoint" .= checkpointText checkpoint, "topics" .= map viewJSON views]

errorJSON :: TopicError -> Value
errorJSON err = object (["error" .= (code :: Text), "message" .= describeError err] <> maybe [] (\view -> ["topic" .= viewJSON view]) detail <> extras)
  where
    extras = case err of
      StaleResource _ token -> ["version" .= versionText token]
      StorageError (PublicationUncertain key _) -> ["checkpoint" .= checkpointText key]
      StorageError (CollectionIncomplete key _) -> ["checkpoint" .= checkpointText key]
      _ -> []
    (code, detail) = case err of
      ExistingTopic view -> ("topic-exists", Just view)
      NeedsResolution view -> ("topic-conflict", Just view)
      StaleTopic view -> ("stale-version", Just view)
      MissingTopic _ -> ("missing-topic", Nothing)
      IsLog _ -> ("wrong-ref-type", Nothing)
      StorageError (PublicationUncertain _ _) -> ("publication-uncertain", Nothing)
      StorageError (CollectionIncomplete _ _) -> ("collection-incomplete", Nothing)
      StorageError StaleCheckpoint -> ("stale-checkpoint", Nothing)
      StorageError _ -> ("repository-error", Nothing)
      TopicIO _ -> ("io-error", Nothing)
      UnregisteredReplica _ -> ("unregistered-replica", Nothing)
      InvalidSelection _ -> ("invalid-selection", Nothing)
      InvalidInput _ -> ("invalid-input", Nothing)
      ConfigurationChanged -> ("configuration-changed", Nothing)
      TextIndexFailed _ -> ("text-index-error", Nothing)
      StaleResource _ _ -> ("stale-version", Nothing)

renderView :: TopicView -> Text
renderView view =
  T.unlines $
    ["topic: " <> nameText (viewName view), "status: " <> statusText (viewStatus view), "version: " <> versionText (viewVersion view)]
      <> concat [["head: " <> eventText (headEvent entry) <> " memory: " <> Id.render (headMemoryId entry), memBody (headMemory entry)] | entry <- viewHeads view]

statusText :: TopicStatus -> Text
statusText status = case status of Missing -> "missing"; Resolved -> "resolved"; Conflicted -> "conflict"; TypeConflicted -> "type-conflict"; LogTopic -> "log"

checkpointText :: CheckpointId -> Text
checkpointText (CheckpointId digest) = Id.render digest

eventText :: EventId -> Text
eventText (EventId digest) = Id.render digest

replicaText :: ReplicaId -> Text
replicaText (ReplicaId who) = renderIdentifier who

describeError :: TopicError -> Text
describeError err = case err of
  StaleResource _ _ -> "The resource version changed. Read its state before another write."
  ConfigurationChanged -> "The configured policy or tier version changed. Read configured context before another resolution."
  TextIndexFailed message -> "The topic text index failed: " <> message
  InvalidInput text -> text
  TopicIO io -> T.pack (displayException io)
  MissingTopic name -> "The topic " <> nameText name <> " does not exist."
  ExistingTopic view -> "The topic " <> nameText (viewName view) <> " already exists. Read it before a revision."
  NeedsResolution view -> "The topic " <> nameText (viewName view) <> " has concurrent heads. Resolve them before a revision."
  StaleTopic _ -> "The topic version changed. Read the current heads before another write."
  IsLog name -> "The ref " <> nameText name <> " is a log, not a topic."
  InvalidSelection digest -> "The selected memory " <> Id.render digest <> " is not one of the current heads."
  UnregisteredReplica _ -> "The local replica is not registered. Run replica init to complete initialisation."
  StorageError failure -> case failure of
    RepositoryIO io -> T.pack (displayException io)
    RepositoryBusy -> "The repository is busy. Try again."
    NotRepository -> "This directory is not a checkpoint repository."
    IdentityMismatch -> "The repository identity does not match."
    InvalidPointer -> "CURRENT is damaged. Do not reinitialise this repository."
    MissingCurrent -> "CURRENT is missing from a repository with transaction data."
    MissingCheckpoint checkpoint -> "CURRENT names checkpoint " <> checkpointText checkpoint <> ", but its manifest is missing."
    InvalidCheckpoint _ -> "The checkpoint manifest is invalid."
    InvalidState _ -> "The event history is invalid."
    CorruptData path -> "Stored data does not match its content ID: " <> T.pack path
    OversizedData path -> "Stored data exceeds the size limit: " <> T.pack path
    InvalidMemory digest why -> "Invalid memory " <> Id.render digest <> ": " <> describeParse why
    MissingPayload digest -> "The write needs memory " <> Id.render digest <> "."
    MissingRetainedTarget _ digest -> "The write needs retained memory " <> Id.render digest <> "."
    UnacceptedObject digest -> "Memory " <> Id.render digest <> " is outside this checkpoint."
    MissingLogPredecessor _ digest -> "A log append does not follow its observed predecessor " <> Id.render digest <> "."
    StaleCheckpoint -> "The checkpoint changed. Read a new GC plan before collection."
    InvalidRetentionDepth -> "The generation depth must be from 1 to 1000."
    ArchiveNotAccepted -> "The archive checkpoint does not belong to the accepted repository history."
    InvalidResidency -> "The checkpoint marks a required live or pending payload as evicted."
    CollectionIncomplete checkpoint _ -> "Collection published " <> checkpointText checkpoint <> " but did not finish local file removal. Retry collection."
    PublicationUncertain checkpoint _ -> "Publication of " <> checkpointText checkpoint <> " is uncertain. Read current state before another write."
