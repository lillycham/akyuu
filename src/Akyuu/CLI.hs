-- | The command line of @akyuu@.
--
-- The parser and the runner are in the library, so that the tests can call
-- them. @app/Main.hs@ only calls 'main'.
--
-- Exit codes: 0 for success, 1 for a failed operation (the text of the error
-- goes to stderr), 2 for bad usage. A @verify@ that finds a problem exits
-- with 1 too.
module Akyuu.CLI
  ( -- * Commands
    Cli (..),
    Command (..),
    ReplicaCommand (..),
    ReplicaResolution (..),
    ReplicaContextArgs (..),
    MemoryArgs (..),
    SourceArgs (..),
    BodySource (..),
    GetTarget (..),
    Check (..),
    CheckArgs (..),

    -- * Parsing
    cliInfo,
    parseCli,

    -- * Running
    Output (..),
    readBody,
    resolveCommand,
    runCommand,
    runReplicaCommand,
    withNewline,
    terminalBytes,
    main,
  )
where

import Akyuu.Amend qualified as Amend
import Akyuu.Check (CheckOptions (CheckOptions, hubDegree, longLog, minWords, nearThreshold), Finding (findingSeverity), FindingKind, Severity (Problem), defaultCheckOptions, filterFindings, kindName, severityName)
import Akyuu.Config qualified as Config
import Akyuu.Embed qualified as Embed
import Akyuu.Episode (Walk (walkEnd), WalkEnd (Interrupted))
import Akyuu.Error (AkyuuError (BadConfig, BadInput, BadName), describe)
import Akyuu.Fs (tryWith)
import Akyuu.GC (Policy (Policy, gracePeriod, keepGenerations, trashTTL), defaultPolicy)
import Akyuu.Graph (Edge (Edge), EdgeType (About, DerivedFrom, Refines, Supersedes))
import Akyuu.Id (Id)
import Akyuu.Id qualified as Id
import Akyuu.Levels (LogView (Plain, Resolution, Todo), defaultKeep, defaultSize)
import Akyuu.MCP qualified as MCP
import Akyuu.Memory (Memory (memBody), renderMemory)
import Akyuu.Ops (Env (envStore), IdSpec, NewMemory (NewMemory, newAboutRefs, newAgent, newBody, newEdges, newKind), SearchMode (Fused, MeaningOnly, TextOnly), addMemory, addUnderRef, amendMemory, appendEpisode, checkField, checkStore, compareMemories, contextFor, dryRunGC, embedMissing, evalSearch, getMemory, initStore, listPinned, listRefValues, listReviewed, neighboursOf, noteEpisode, parseDuration, parseIdSpec, pinMemory, pruneEmbeddings, readLevels, readLog, readLogSince, readRef, refLinksOf, reindexCache, resolveId, resolvePolicyRef, resolveRoot, resolveTiersRef, reviewPair, runGC, searchMemoriesMode, setRefTo, sourcePointers, statusOf, summariseLog, supersedeMemory, unfoldMemory, unpinMemory, unreviewPair, verifyOk, verifyStore, withEnv)
import Akyuu.Ops qualified as Ops
import Akyuu.Query (SearchOptions (SearchOptions, searchFollow, searchHops, searchLimit), defaultSearchOptions)
import Akyuu.Refs (Expected (MustBe, MustBeAbsent, Unchecked), Name, Ref (current), mkName, nameText)
import Akyuu.Related qualified as Related
import Akyuu.Render (compareJSON, compareLines, configLines, edgeName, embedLines, episodeLines, evalLines, findingJSON, findingLines, hashVerdictOk, hashVerdictText, heldBy, idLine, logLines, neighbourLines, pinLines, pinListLines, planLines, refLines, refLinkLines, refListLines, reviewLines, runLines, searchLinesWith, sourceShowLines, sourceVerifyLine, statusLines, syncLines, tierLinesWithin, tierPage, unpinLines, verifyLines, viewLines)
import Akyuu.SearchEval (defaultEvalSetRef)
import Akyuu.Seed qualified as Seed
import Akyuu.Source qualified as Source
import Akyuu.Store qualified as Store
import Akyuu.Sync.Checkpoint (CheckpointId (CheckpointId))
import Akyuu.Sync.Context qualified as ReplicaContext
import Akyuu.Sync.Logs qualified as ReplicaLogs
import Akyuu.Sync.Migration qualified as ReplicaMigration
import Akyuu.Sync.Repository qualified as ReplicaRepository
import Akyuu.Sync.Resources qualified as ReplicaResources
import Akyuu.Sync.Run qualified as ReplicaSync
import Akyuu.Sync.Search qualified as ReplicaSearch
import Akyuu.Sync.State (Version, parseVersion)
import Akyuu.Sync.Topics qualified as Topics
import Akyuu.Sync.Types (Action (ClearPin, ClearReview, SetPin, SetReview), Resource (PinResource, ReviewResource), ReviewValue (ReviewValue))
import Akyuu.Sync.Web qualified as ReplicaWeb
import Akyuu.Tier (Place (Place))
import Akyuu.Web.Page qualified as Page
import Akyuu.Web.Read qualified as Read
import Akyuu.Web.Server qualified as Server
import Control.Exception (IOException, try)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Trans.Except (ExceptT (ExceptT), except, runExceptT, throwE)
import Data.Aeson (Value, eitherDecodeStrict', encode, object, toJSON, (.=))
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BL
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (decodeUtf8, decodeUtf8', encodeUtf8)
import Data.Time (NominalDiffTime, UTCTime, defaultTimeLocale, getCurrentTime, parseTimeM)
import Data.Version (showVersion)
import Options.Applicative (Alternative (many, some, (<|>)), CompletionResult (execCompletion), Parser, ParserInfo, ParserResult (CompletionInvoked, Failure, Success), ReadM, argument, auto, command, defaultPrefs, eitherReader, execParserPure, flag', footer, fullDesc, help, helper, hsubparser, info, infoOption, long, metavar, option, optional, progDesc, readerError, renderFailure, short, showDefault, showDefaultWith, strArgument, strOption, switch, value, (<**>))
import Paths_akyuu qualified as Pkg
import System.Directory (createDirectoryIfMissing, getCurrentDirectory)
import System.Environment (getArgs, getProgName, lookupEnv, setEnv)
import System.Exit (ExitCode (ExitFailure, ExitSuccess), exitWith)
import System.IO (hFlush, hIsTerminalDevice, hPutStrLn, stderr, stdout)

-- Commands -------------------------------------------------------------

-- | A whole command line: the global options and one command.
--
-- The command holds 'IdSpec' values, because a person can give the start of
-- an id. 'resolveCommand' turns them into whole ids, with the help of the
-- store.
data Cli = Cli
  { -- | The @--root@ option, if it was given. See 'resolveRoot'.
    cliRoot :: Maybe FilePath,
    -- | The @--embed-profile@ option: the profile of the config file to use.
    cliProfile :: Maybe Text,
    cliCommand :: Command IdSpec
  }
  deriving (Eq, Show)

-- | Where the body of a new memory comes from.
data BodySource
  = -- | The text of the @--body@ option.
    BodyText Text
  | -- | A file (@--file@).
    BodyFile FilePath
  | -- | Standard input. This is the default.
    BodyStdin
  deriving (Eq, Show)

-- | The options of a new memory, before the body is read. The edges are in
-- the order of the command line.
data MemoryArgs i = MemoryArgs
  { argKind :: Text,
    argAgent :: Text,
    argEdges :: [(EdgeType, i)],
    -- | The refs of the @about-ref@ links (@--about-ref@).
    argAboutRefs :: [Name],
    argBody :: BodySource
  }
  deriving (Eq, Show, Functor, Foldable, Traversable)

-- | What @get@ reads.
data GetTarget i
  = ById i
  | -- | The current memory of a ref (@--ref@).
    ByRef Name
  deriving (Eq, Show, Functor, Foldable, Traversable)

-- | What @ref set@ checks before it moves the ref. It is 'Expected' with a
-- parameter for the id, so that the id can be a prefix at first.
data Check i
  = -- | No check.
    NoCheck
  | -- | The ref must not exist (@--new@).
    MustBeNew
  | -- | The ref must point to this id now (@--expect@).
    MustBeAt i
  deriving (Eq, Show, Functor, Foldable, Traversable)

-- | One command. The parameter is the type of the ids that it holds: 'IdSpec'
-- when the command comes from the command line, and 'Id' when it is ready
-- to run. 'resolveCommand' makes the change, and it can fail.
data ReplicaResolution i = SelectHead i | MergeHeads (MemoryArgs i)
  deriving (Eq, Show, Functor, Foldable, Traversable)

data ReplicaContextArgs = ReplicaContextArgs (Maybe Name) (Maybe Name) Text (Maybe Text) [Name] ReplicaLogs.LogPageOptions
  deriving (Eq, Show)

data ReplicaCommand i
  = ReplicaInit Text Bool
  | ReplicaRead Name Bool
  | ReplicaCreate Name (MemoryArgs i) Bool
  | ReplicaReplace Name Version (MemoryArgs i) Bool
  | ReplicaResolve Name Version (ReplicaResolution i) Bool
  | ReplicaConflicts Bool
  | ReplicaContext [Name] Bool
  | ReplicaConfiguredContext ReplicaContextArgs Bool
  | ReplicaSearch Text Int Bool
  | ReplicaLog Name Int Bool
  | ReplicaAppend Name Version (MemoryArgs i) Bool
  | ReplicaLevels Name Bool
  | ReplicaSummarise Name i Int [i] (MemoryArgs i) Bool
  | ReplicaResolution Name Int Bool
  | ReplicaTodo Name Int Int Bool
  | ReplicaUnfold i Bool
  | ReplicaArchive Bool
  | ReplicaGC Int (Maybe i) Bool Bool
  | ReplicaPinState i Bool
  | ReplicaPin i Version Bool Bool
  | ReplicaReviewState i i Bool
  | ReplicaReview i i Version Text Text Bool
  | ReplicaUnreview i i Version Bool
  | ReplicaSyncConfigure Text Text Bool
  | ReplicaSync Bool Bool
  | ReplicaSyncStatus Bool
  | ReplicaJoin Text Text Text Bool
  | ReplicaMigrate FilePath FilePath (Maybe i) Bool Bool
  | ReplicaServe Int ReplicaContextArgs
  | ReplicaViz ReplicaContextArgs
  deriving (Eq, Show, Functor, Foldable, Traversable)

data Command i
  = Replica (ReplicaCommand i)
  | Add (MemoryArgs i)
  | -- | Add a memory and make a new ref for it (@add --ref@).
    AddRef Name (MemoryArgs i)
  | -- | The memory, and 'True' for @--with-id@: a first line with its id.
    Get (GetTarget i) Bool
  | -- | The ref, the 'Id' that the ref must point to now (@--expect@), and
    -- the new memory.
    Supersede Name (Maybe i) (MemoryArgs i)
  | -- | Change the text of the memory of a ref: the ref, the 'Id' that it
    -- must point to now, the agent of the new memory, and the edits.
    Amend Name (Maybe i) (Maybe Text) [Amend.Edit]
  | -- | The ref, and 'True' to show its older values too.
    RefGet Name Bool
  | RefSet Name (Check i) i
  | RefList
  | -- | Pin a memory, so that GC keeps it.
    Pin i
  | Unpin i
  | -- | Print the pins.
    Pins
  | -- | Two memories, the name of the agent that judged them, and a note.
    Review i i Text Text
  | Unreview i i
  | -- | Print the reviewed pairs.
    Reviews
  | -- | The tier, extra refs, the ref of the manifest ('Nothing' for the
    -- default), and the directory ('Nothing' for the current one).
    Context (Maybe Text) [Name] (Maybe Name) (Maybe Text) (Maybe Int) (Maybe Int)
  | -- | A note for the log of a directory: the directory ('Nothing' for the
    -- current one), the kind, the agent ('Nothing' for $AKYUU_AGENT), the
    -- ref of the manifest, the refs of the about-ref links, and the text.
    Note (Maybe Text) Text (Maybe Text) (Maybe Name) [Name] Text
  | -- | Append an episode to the log that a ref names.
    Append Name (MemoryArgs i)
  | -- | Read a log: the ref, the most episodes ('Nothing' for the default),
    -- 'True' for the bodies, the age, and the view ('Akyuu.Levels').
    Log Name (Maybe Int) Bool (Maybe NominalDiffTime) LogView
  | -- | A summary at a level of a log: the ref, the level, the sources, the
    -- kind, the agent and the body.
    Summarise Name Int [i] Text Text BodySource
  | -- | Print the sources of a summary.
    Unfold i
  | Search SearchMode SearchOptions Text
  | -- | A short report of the setup.
    Status
  | -- | Make the root if it is missing, and write a policy and a manifest.
    Init
  | -- | Give a vector to each memory that has none.
    Embed Bool
  | -- | Run a set of searches (the ref, or 'defaultEvalSetRef'), and show
    -- the refs found by each mode in the first k hits.
    SearchEvalCmd (Maybe Name) Int
  | Neighbours i
  | -- | Two memories to compare, and 'True' for JSON.
    Compare i i Bool
  | -- | 'True' for @--dry-run@, and the policy of the run.
    GC Bool Policy
  | Reindex
  | Verify
  | -- | Report what needs attention. See 'CheckArgs'.
    CheckStore CheckArgs
  | -- | Serve MCP on stdin and stdout until stdin ends. The ref of the policy,
    -- if one is given (@--policy-ref@).
    Mcp (Maybe Name) (Maybe Name) MCP.ToolSet
  | -- | Serve the web UI on 127.0.0.1 at this port, until the program is
    -- stopped. Port 0 is a free port.
    Serve Int
  | -- | Print the web UI as one HTML file, with the data of the store in it.
    Viz
  | -- | Make the demo store (@seed --demo@), in this directory or the root.
    Seed (Maybe FilePath)
  | -- | Show the settings in effect, and where each came from. It needs no
    -- store, so it runs before one is opened.
    ShowConfig
  | -- | Make a pointer to part of an agent session ("Akyuu.Source").
    SourceAdd SourceArgs
  | -- | Show the records of the session that a memory came from: the memory,
    -- and how many records to show before the time and after it.
    SourceShow i Int Int
  | -- | Say where the session of a memory's pointer is, or that it is not
    -- on this machine.
    SourceVerify i
  | -- | For a start hook: read the JSON that the agent gives it on standard
    -- input, and print the id of the session, for the context. The parameter
    -- is the transcript format of the agent.
    SourceHook Text
  deriving (Eq, Show, Functor, Foldable, Traversable)

-- | The options of @source add@: the transcript format, the session, the time
-- ('Nothing' means now), the first and last record ids, a hint, the agent
-- that writes the memory ('Nothing' means the configured agent), and whether
-- to store the hash of the span of records (@--hash@).
data SourceArgs = SourceArgs
  { saFormat :: Text,
    saSession :: Text,
    saAt :: Maybe UTCTime,
    saFrom :: Maybe Text,
    saTo :: Maybe Text,
    saHint :: Maybe Text,
    saAgent :: Maybe Text,
    saHash :: Bool
  }
  deriving (Eq, Show)

-- Parsing --------------------------------------------------------------

-- | A reader that uses a function of the library. The text of a 'Left' is
-- the friendly text of the error.
via :: (Text -> Either AkyuuError a) -> ReadM a
via f = eitherReader (first (T.unpack . describe) . f . T.pack)

-- | An id as a person types it: whole, or the start of one. See
-- 'parseIdSpec'.
idReader :: ReadM IdSpec
idReader = via parseIdSpec

nameReader :: ReadM Name
nameReader = via (\t -> first (BadName t) (mkName t))

modeReader :: ReadM SearchMode
modeReader = via $ \t ->
  maybe (Left (BadInput ("'" <> t <> "' is not a mode. Use fused, text or meaning."))) Right (lookup t [("fused", Fused), ("text", TextOnly), ("meaning", MeaningOnly)])

kindReader :: ReadM EdgeType
kindReader = via $ \t ->
  maybe (Left (BadInput (bad t))) Right (lookup t [(edgeName k, k) | k <- [minBound .. maxBound]])
  where
    bad t = "'" <> t <> "' is not a kind of edge. Use " <> T.intercalate ", " (map edgeName [minBound .. maxBound]) <> "."

-- | A number that is at least @lo@.
atLeast :: Int -> ReadM Int
atLeast lo = do
  n <- auto
  if n >= lo then pure n else readerError ("the number must be at least " <> show lo)

-- | Where the body comes from: --body, --file, or the standard input.
bodySource :: Parser BodySource
bodySource =
  (BodyText <$> strOption (long "body" <> metavar "TEXT" <> help "The body of the memory."))
    <|> (BodyFile <$> strOption (long "file" <> short 'f' <> metavar "PATH" <> help "Read the body from a file."))
    <|> pure BodyStdin

memoryArgs :: Parser (MemoryArgs IdSpec)
memoryArgs =
  MemoryArgs
    <$> field "kind" "The kind of memory, for example fact or preference."
    <*> field "agent" "The name of the agent that writes the memory."
    <*> edges
    <*> many (option nameReader (long "about-ref" <> metavar "NAME" <> help "The new memory is about the ref NAME, whatever memory it names. Repeat for more."))
    <*> body
  where
    field n h = option (via (checkField n)) (long (T.unpack n) <> metavar "TEXT" <> help h)
    edgeOpt k h = many ((,) k <$> option idReader (long (T.unpack (edgeName k)) <> metavar "ID" <> help h))
    edges =
      (\a b c d -> a <> b <> c <> d)
        <$> edgeOpt About "The new memory is about the memory ID. Repeat for more."
        <*> edgeOpt DerivedFrom "The new memory comes from the memory ID."
        <*> edgeOpt Refines "The new memory adds detail to the memory ID."
        <*> edgeOpt Supersedes "The new memory replaces the memory ID. The supersede command adds this edge for you."
    body = bodySource

commandParser :: Parser (Command IdSpec)
commandParser =
  hsubparser $
    cmd "add" addP "Add a memory and print its id. The body comes from --body, --file or stdin."
      <> cmd "get" getP "Print a memory, by id (or the start of one) or by ref."
      <> cmd "supersede" supersedeP "Replace the memory of a ref with a new one, and print the new id."
      <> cmd "amend" amendP "Change some text of the memory of a ref: replace one passage, or add text at the end. Prints the new id."
      <> cmd "ref" refP "Read, set or list refs."
      <> cmd "replica" (Replica <$> replicaP) "Use experimental checkpoint replicas, snapshot copies and manual Git sync."
      <> cmd "pin" (Pin <$> argument idReader (metavar "ID")) "Pin a memory, so that GC keeps it."
      <> cmd "unpin" (Unpin <$> argument idReader (metavar "ID")) "Remove the pin of a memory."
      <> cmd "pins" (pure Pins) "Print the id of each pinned memory."
      <> cmd "review" reviewP "Record that two memories are different and both true, so that check leaves the pair out."
      <> cmd "unreview" (Unreview <$> argument idReader (metavar "ID_A") <*> argument idReader (metavar "ID_B")) "Remove the review of a pair."
      <> cmd "reviews" (pure Reviews) "Print the reviewed pairs."
      <> cmd "append" appendP "Add an episode to a log: a memory that points at the one before it, under a ref that moves to it."
      <> cmd "note" noteP "Write a note in the log that the manifest names for the current directory."
      <> cmd "log" logP "Print the episodes of a log, newest first."
      <> cmd "summarise" summariseP "Record a summary of the oldest stretch of a log that has none."
      <> cmd "unfold" unfoldP "Print the sources of a summary, newest first, whole."
      <> cmd "source" sourceP "Pointers to the agent sessions that memories came from: make one, show the session around it, check that it can be read."
      <> cmd "context" contextP "Print the memories of a tier (the profile, the policy and so on) in one call, for the start of a session."
      <> cmd "search" searchP "Search the memories for words, and show the memories near each hit."
      <> cmd "init" (pure Init) "Start a store: make the root, and write a short policy for agents and a manifest of the tiers. Existing refs are kept."
      <> cmd "status" (pure Status) "Show the setup: the counts, the manifest, the policy, search by meaning and versioning."
      <> cmd "config" (pure ShowConfig) "Show the settings in effect (the config file, the environment, the defaults), and where each came from."
      <> cmd "embed" (Embed <$> switch (long "prune" <> help "Also remove the vectors of other models and of memories that GC deleted.")) "Give a vector to each memory that has none, with the command in AKYUU_EMBED_COMMAND (search by meaning)."
      <> cmd "search-eval" searchEvalP "Run a set of searches in each mode, and show which ones find the expected memories."
      <> cmd "neighbours" neighboursP "Show the edges of a memory, in both directions."
      <> cmd "compare" compareP "Show what each of two memories says that the other lacks."
      <> cmd "gc" gcP "Collect the memories that nothing needs."
      <> cmd "reindex" (pure Reindex) "Throw the cache away and read the whole store again."
      <> cmd "verify" (pure Verify) "Check every object, edge and ref of the store."
      <> cmd "check" (CheckStore <$> checkP) "Find memories that need attention: stale links, forks, duplicates, memories that nothing keeps."
      <> cmd "mcp" mcpP "Serve the MCP protocol (JSON-RPC 2.0) on stdin and stdout, until stdin ends."
      <> cmd "serve" serveP "Serve a read-only web view of the store on 127.0.0.1, and print its address."
      <> cmd "viz" (pure Viz) "Print a read-only web view of the store as one HTML file. It needs no server."
      <> cmd "seed" seedP "Make a demo store in an empty directory, to try the web view."
  where
    cmd n p d = command n (info p (progDesc d))
    replicaP =
      hsubparser $
        cmd "init" (ReplicaInit <$> option (via (checkField "label")) (long "label" <> metavar "TEXT" <> help "A label for this replica.") <*> jsonFlag) "Initialise an empty local checkpoint replica."
          <> cmd "read" (ReplicaRead <$> topicName <*> jsonFlag) "Read all current heads and their opaque version."
          <> cmd "create" (ReplicaCreate <$> topicName <*> memoryArgs <*> jsonFlag) "Create a topic that does not exist."
          <> cmd "replace" (ReplicaReplace <$> topicName <*> topicVersion <*> memoryArgs <*> jsonFlag) "Replace a resolved topic with a version check."
          <> cmd "resolve" (ReplicaResolve <$> topicName <*> topicVersion <*> ((SelectHead <$> option idReader (long "select" <> metavar "ID" <> help "Select one current head by its complete memory ID.")) <|> (MergeHeads <$> memoryArgs)) <*> jsonFlag) "Resolve current heads with a selected or merged memory."
          <> cmd "conflicts" (ReplicaConflicts <$> jsonFlag) "List unresolved topic conflicts."
          <> cmd "context" (ReplicaContext <$> some (option nameReader (long "ref" <> metavar "NAME" <> help "Read this topic. Repeat for more.")) <*> jsonFlag) "Read explicit topics from one checkpoint."
          <> cmd "configured-context" (ReplicaConfiguredContext <$> replicaContextArgs <*> jsonFlag) "Read configured policy, tiers and directory context."
          <> cmd "search" (ReplicaSearch <$> (T.unwords <$> some (strArgument (metavar "WORDS..."))) <*> option (atLeast 1) (long "limit" <> value 10 <> metavar "N" <> help "At most 100 topic results.") <*> jsonFlag) "Search current topic heads by words."
          <> cmd "log" (ReplicaLog <$> topicName <*> option (atLeast 0) (long "limit" <> value 100 <> metavar "N" <> help "At most N distinct episodes. An incomplete read includes its frontier.") <*> jsonFlag) "Read every log branch in reverse topological order."
          <> cmd "append" (ReplicaAppend <$> topicName <*> topicVersion <*> memoryArgs <*> jsonFlag) "Append an episode that follows every observed log head."
          <> cmd "log-levels" (ReplicaLevels <$> topicName <*> jsonFlag) "Read complete log levels and their summary source version."
          <> cmd "summarise" (ReplicaSummarise <$> topicName <*> option idReader (long "expected" <> metavar "VERSION" <> help "The source version from replica log-levels.") <*> option (atLeast 1) (long "level" <> metavar "N" <> help "The summary level, starting at 1.") <*> some (option idReader (long "source" <> metavar "ID" <> help "An exact source ID from the lower level. Repeat for more.")) <*> memoryArgs <*> jsonFlag) "Record a summary with exact sources and a source version check."
          <> cmd "log-resolution" (ReplicaResolution <$> topicName <*> keepEpisodes <*> jsonFlag) "Read a deterministic summary cover with raw fallback."
          <> cmd "log-todo" (ReplicaTodo <$> topicName <*> option (atLeast 2) (long "size" <> value 8 <> metavar "N" <> help "Sources per suggested summary.") <*> keepEpisodes <*> jsonFlag) "List uncovered source batches for summaries."
          <> cmd "unfold" (ReplicaUnfold <$> argument idReader (metavar "ID") <*> jsonFlag) "Read the exact direct sources of an accepted summary."
          <> cmd "archive" (ReplicaArchive <$> jsonFlag) "Save a complete durable local archive. This does not acknowledge remote publication."
          <> cmd "sync-config" (ReplicaSyncConfigure <$> remoteURL <*> syncBranch <*> jsonFlag) "Configure one sync target. This command does not contact the remote."
          <> cmd "sync" (ReplicaSync <$> switch (long "dry-run" <> help "Fetch and report changes without import, acknowledgement or push.") <*> jsonFlag) "Exchange accepted memory data through the configured Git branch."
          <> cmd "sync-status" (ReplicaSyncStatus <$> jsonFlag) "Report local progress and pending counts without a remote call."
          <> cmd "join" (ReplicaJoin <$> remoteURL <*> syncBranch <*> strOption (long "label" <> metavar "TEXT" <> help "A label for the new local replica.") <*> jsonFlag) "Join a verified archive into an empty directory. Resume an interrupted join."
          <> cmd "migrate" (ReplicaMigrate <$> strOption (long "source" <> metavar "DIR" <> help "The legacy source store. It is not converted in place.") <*> strOption (long "classification" <> metavar "FILE" <> help "A JSON object that maps every ref to topic or log.") <*> optional (option idReader (long "expected" <> metavar "VERSION" <> help "The source version from a migration dry run.")) <*> switch (long "dry-run" <> help "Validate and report the source without a destination write.") <*> jsonFlag) "Copy an explicitly classified legacy snapshot to a separate replica."
          <> cmd "gc" (ReplicaGC <$> option (atLeast 1) (long "keep-generations" <> value 5 <> metavar "N" <> help "Retain this many generations along every causal branch, from 1 to 1000.") <*> optional (option idReader (long "expected" <> metavar "CHECKPOINT" <> help "The checkpoint from a dry run. Required for collection.")) <*> switch (long "dry-run" <> help "Report the plan without a change.") <*> jsonFlag) "Evict unused local copies after a complete durable archive."
          <> cmd "pin-state" (ReplicaPinState <$> fullMemory <*> jsonFlag) "Read pin state and its resource version."
          <> cmd "pin" (ReplicaPin <$> fullMemory <*> topicVersion <*> pure True <*> jsonFlag) "Pin an accepted memory with a resource version check."
          <> cmd "unpin" (ReplicaPin <$> fullMemory <*> topicVersion <*> pure False <*> jsonFlag) "Clear observed pin heads. A concurrent unseen pin survives."
          <> cmd "review-state" (ReplicaReviewState <$> fullMemory <*> fullMemory <*> jsonFlag) "Read every surviving review reason and its resource version."
          <> cmd "review" (ReplicaReview <$> fullMemory <*> fullMemory <*> topicVersion <*> strOption (long "agent" <> metavar "TEXT" <> help "The review author.") <*> strOption (long "reason" <> metavar "TEXT" <> help "Why these memories are distinct.") <*> jsonFlag) "Review a pair with a resource version check."
          <> cmd "unreview" (ReplicaUnreview <$> fullMemory <*> fullMemory <*> topicVersion <*> jsonFlag) "Clear observed reviews. A concurrent unseen review survives."
          <> cmd "serve" (ReplicaServe <$> option portReader (long "port" <> value 0 <> metavar "PORT" <> help "Loopback port; 0 chooses a free port.") <*> replicaContextArgs) "Serve the read-only replica topic browser."
          <> cmd "viz" (ReplicaViz <$> replicaContextArgs) "Export one read-only topic snapshot as HTML."
    replicaContextArgs =
      ReplicaContextArgs
        <$> optional (option nameReader (long "policy-ref" <> metavar "NAME" <> help "The configured policy ref."))
        <*> optional (option nameReader (long "tiers-ref" <> metavar "NAME" <> help "The configured tier manifest ref."))
        <*> strOption (long "tier" <> value "always" <> metavar "TIER" <> help "The configured context tier.")
        <*> optional (strOption (long "cwd" <> metavar "DIR" <> help "The session directory."))
        <*> many (option nameReader (long "ref" <> metavar "NAME" <> help "An extra context ref."))
        <*> ( ReplicaLogs.LogPageOptions
                <$> option (atLeast 1) (long "log-page" <> value 1 <> metavar "N" <> help "The page of each resolved log; default 1.")
                <*> option (atLeast 1) (long "log-limit" <> value 20 <> metavar "N" <> help "Entries per log page, from 1 to 100.")
                <*> option (atLeast 0) (long "log-keep" <> value 10 <> metavar "N" <> help "Recent episodes to retain whole; default 10.")
                <*> optional (option (eitherReader (first (const "Give a complete checkpoint ID.") . Id.parse . T.pack)) (long "checkpoint" <> metavar "ID" <> help "The checkpoint from the first log page. Required after page 1."))
            )
    jsonFlag = switch (long "json" <> help "Print structured JSON, including operation errors.")
    keepEpisodes = option (atLeast 0) (long "keep" <> value 10 <> metavar "N" <> help "Recent episodes to retain whole.")
    fullMemory = argument idReader (metavar "ID")
    remoteURL = strOption (long "remote" <> metavar "URL" <> help "A local Git path or remote URL. Do not embed credentials.")
    syncBranch = strOption (long "branch" <> value "akyuu-sync-v1" <> metavar "NAME" <> help "A dedicated protocol branch; default akyuu-sync-v1.")
    topicName = argument nameReader (metavar "NAME")
    topicVersion = option (eitherReader (either (const (Left "Give the complete opaque resource version.")) Right . parseVersion . T.pack)) (long "expected" <> metavar "VERSION" <> help "The complete version returned by the matching state read.")
    addP =
      (\r a -> maybe (Add a) (`AddRef` a) r)
        <$> optional (option nameReader (long "ref" <> metavar "NAME" <> help "Also make a new ref NAME for the memory. The ref must not exist."))
        <*> memoryArgs
    getP =
      Get
        <$> ( (ById <$> argument idReader (metavar "ID"))
                <|> (ByRef <$> option nameReader (long "ref" <> metavar "NAME" <> help "Print the current memory of this ref."))
            )
        <*> switch (long "with-id" <> help "Print a first line, id: ID, with the id of the memory read (the value for --expect). Without it, the output is the stored file exactly.")
    supersedeP =
      Supersede
        <$> argument nameReader (metavar "NAME")
        <*> optional (option idReader (long "expect" <> metavar "ID" <> help "Fail if the ref does not point to ID now."))
        <*> memoryArgs
    amendP =
      amendArgs
        <$> argument nameReader (metavar "NAME")
        <*> optional (option idReader (long "expect" <> metavar "ID" <> help "Fail if the ref does not point to ID now."))
        <*> optional (option (via (checkField "agent")) (long "agent" <> metavar "TEXT" <> help "The agent of the new memory. The default is the agent of the old one."))
        <*> optional (strOption (long "from" <> metavar "TEXT" <> help "Text to replace. It must occur once."))
        <*> optional (strOption (long "to" <> metavar "TEXT" <> help "The text to put in its place."))
        <*> optional (strOption (long "append" <> metavar "TEXT" <> help "Text to add after the body."))
    amendArgs n e a from to app =
      Amend n e a (maybe [] (\f -> [Amend.Replace f (maybe "" id to)]) from <> maybe [] (pure . Amend.Append) app)
    sourceP =
      hsubparser $
        cmd "add" sourceAddP "Make a pointer to part of an agent session, and print its id. Link a memory to it with --derived-from."
          <> cmd "show" sourceShowP "Show the records of the session that a memory (a pointer, or a memory that derives from one) came from."
          <> cmd "verify" (SourceVerify <$> argument idReader (metavar "ID")) "Say where the session of a pointer is on this machine, or that it is not available."
          <> cmd "hook" sourceHookP "For a start hook of an agent: read the JSON that it gives on standard input, and print the id of the session, so that the agent can make pointers to it. Prints nothing if there is no session id."
    sourceHookP =
      SourceHook
        <$> strOption (long "format" <> metavar "FORMAT" <> value "claude-code" <> showDefault <> help "The transcript format of the agent that runs the hook.")
    sourceAddP =
      fmap SourceAdd $
        SourceArgs
          <$> strOption (long "format" <> metavar "FORMAT" <> value "claude-code" <> showDefault <> help "The transcript format of the session.")
          <*> strOption (long "session" <> metavar "ID" <> help "The session: the id that its file is named for.")
          <*> optional (option timeReader (long "at" <> metavar "TIME" <> help "The time the memory is about, like 2026-11-01T19:00:58Z. The default is now."))
          <*> optional (strOption (long "from" <> metavar "ID" <> help "The id of the first record, if you know it."))
          <*> optional (strOption (long "to" <> metavar "ID" <> help "The id of the last record, if you know it."))
          <*> optional (strOption (long "hint" <> metavar "PATH" <> help "A path below the root, for a person to read. It is not used to find the file."))
          <*> optional (option (via (checkField "agent")) (long "agent" <> metavar "TEXT" <> help "The agent that writes the memory. The default is $AKYUU_AGENT, then agent."))
          <*> switch (long "hash" <> help "Store the hash of the records from --from to --to, so that source verify can tell if they changed. It needs both ids, the session on this machine, and engi on the PATH.")
    sourceShowP =
      SourceShow
        <$> argument idReader (metavar "ID")
        <*> option auto (long "before" <> metavar "N" <> value 6 <> showDefault <> help "How many records to show before the time.")
        <*> option auto (long "after" <> metavar "N" <> value 2 <> showDefault <> help "How many records to show after the time.")
    timeReader =
      eitherReader $ \s ->
        maybe (Left "expected a time like 2026-11-01T19:00:58Z") Right (parseTimeM True defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" s)
    refP =
      hsubparser $
        cmd "get" refGetP "Print the id that a ref points to."
          <> cmd "set" refSetP "Point a ref at a memory that is in the store."
          <> cmd "list" (pure RefList) "Print the name and the id of each ref."
    refGetP =
      RefGet
        <$> argument nameReader (metavar "NAME")
        <*> switch (long "history" <> help "Also print the older values, newest first.")
    refSetP =
      (\n i e -> RefSet n e i)
        <$> argument nameReader (metavar "NAME")
        <*> argument idReader (metavar "ID")
        <*> ( (MustBeAt <$> option idReader (long "expect" <> metavar "ID" <> help "Fail if the ref does not point to ID now."))
                <|> flag' MustBeNew (long "new" <> help "Fail if the ref exists.")
                <|> pure NoCheck
            )
    searchP =
      Search
        <$> modeOpt
        <*> searchOpts
        <*> (T.unwords <$> some (strArgument (metavar "WORDS...")))
    modeOpt =
      option modeReader (long "mode" <> metavar "MODE" <> value Fused <> showDefault <> help "fused (the default: words and meaning), text (words only) or meaning (meaning only). The last two kinds need AKYUU_EMBED_COMMAND.")
    searchOpts =
      (\l h ks -> SearchOptions l h (if null ks then searchFollow defaultSearchOptions else Set.fromList ks))
        <$> option (atLeast 1) (long "limit" <> short 'n' <> metavar "N" <> value (searchLimit defaultSearchOptions) <> showDefault <> help "The most hits to show.")
        <*> option (atLeast 0) (long "hops" <> metavar "N" <> value (searchHops defaultSearchOptions) <> showDefault <> help "How many edges away from a hit to look.")
        <*> many (option kindReader (long "follow" <> metavar "KIND" <> help "Follow only this kind of edge. Repeat for more. The default is all kinds."))
    searchEvalP =
      SearchEvalCmd
        <$> optional (option nameReader (long "set" <> metavar "NAME" <> help "The ref of the set of searches. The default is policy/embedding-eval."))
        <*> option (atLeast 1) (long "k" <> metavar "N" <> value 3 <> showDefault <> help "How many hits count.")
    neighboursP = Neighbours <$> argument idReader (metavar "ID")
    appendP = Append <$> argument nameReader (metavar "REF") <*> memoryArgs
    logP =
      Log
        <$> argument nameReader (metavar "REF")
        <*> optional (option (atLeast 1) (long "limit" <> short 'n' <> metavar "N" <> help "The most episodes to print. The default is 20."))
        <*> switch (long "full" <> help "Print the body of each episode.")
        <*> optional (option (via parseDuration) (long "since" <> metavar "DURATION" <> help "Only the episodes of the last DURATION, for example 1d or 7d."))
        <*> logView
    logView =
      ( \todoV resV size keep budget ->
          if todoV then Todo size keep else if resV then Resolution keep budget else Plain
      )
        <$> switch (long "todo" <> help "Print the oldest stretches that need a summary, and the level of each.")
        <*> switch (long "resolution" <> help "Print the recent episodes whole, and the older ones as their summaries.")
        <*> option (atLeast 2) (long "size" <> metavar "N" <> value defaultSize <> showDefault <> help "With --todo, the memories that one summary covers.")
        <*> option (atLeast 0) (long "keep" <> metavar "N" <> value defaultKeep <> showDefault <> help "The newest episodes that are shown whole and get no summary yet.")
        <*> optional (option (atLeast 200) (long "budget" <> metavar "CHARS" <> help "With --resolution, show fewer episodes whole until the text fits, or fail."))
    summariseP =
      Summarise
        <$> argument nameReader (metavar "REF")
        <*> option (atLeast 1) (long "level" <> metavar "N" <> value 1 <> showDefault <> help "The level of the summary. Level 1 covers episodes, level 2 covers level-1 summaries.")
        <*> some (option idReader (long "source" <> metavar "ID" <> help "A memory that the summary covers. Repeat for each one: the oldest that no summary covers."))
        <*> option (via (checkField "kind")) (long "kind" <> metavar "TEXT" <> value "summary" <> showDefault <> help "The kind of the summary.")
        <*> option (via (checkField "agent")) (long "agent" <> metavar "TEXT" <> help "The agent that writes the summary.")
        <*> bodySource
    unfoldP = Unfold <$> argument idReader (metavar "ID")
    contextP =
      Context
        <$> optional (strOption (long "tier" <> metavar "NAME" <> help "The tier to print. The default is always."))
        <*> many (option nameReader (long "ref" <> metavar "NAME" <> help "Also print this ref. Repeat for more."))
        <*> optional (option nameReader (long "manifest" <> metavar "NAME" <> help "The ref of the manifest. The default is $AKYUU_TIERS_REF, then policy/tiers."))
        <*> optional (strOption (long "cwd" <> metavar "DIR" <> help "The directory to take the refs for. The default is the current directory."))
        <*> optional (option (atLeast 200) (long "budget" <> metavar "CHARS" <> help "Split the output into pages of about this many characters, and print page 1 (or --page). For a hook whose output is cut."))
        <*> optional (option (atLeast 1) (long "page" <> metavar "N" <> help "Print page N of the split output. The default size of a page is 9500 characters. A page after the last prints nothing."))
    noteP =
      Note
        <$> optional (strOption (long "cwd" <> metavar "DIR" <> help "The directory whose log gets the note. The default is the current directory."))
        <*> strOption (long "kind" <> metavar "TEXT" <> value "note" <> showDefault <> help "The kind of the note.")
        <*> optional (option (via (checkField "agent")) (long "agent" <> metavar "TEXT" <> help "The agent that writes the note. The default is $AKYUU_AGENT, then agent."))
        <*> optional (option nameReader (long "manifest" <> metavar "NAME" <> help "The ref of the manifest. The default is $AKYUU_TIERS_REF, then policy/tiers."))
        <*> many (option nameReader (long "about-ref" <> metavar "NAME" <> help "The note is about the ref NAME. Repeat for more."))
        <*> (T.unwords <$> some (strArgument (metavar "TEXT...")))
    reviewP =
      Review
        <$> argument idReader (metavar "ID_A")
        <*> argument idReader (metavar "ID_B")
        <*> strOption (long "agent" <> metavar "NAME" <> help "The name of the agent that judged the pair.")
        <*> strOption (long "note" <> metavar "TEXT" <> value "" <> help "A short reason.")
    compareP =
      Compare
        <$> argument idReader (metavar "ID_A")
        <*> argument idReader (metavar "ID_B")
        <*> switch (long "json" <> help "Print the comparison as JSON.")
    mcpP =
      Mcp
        <$> optional (option nameReader (long "policy-ref" <> metavar "NAME" <> help "The ref that holds the policy of this store. The default is $AKYUU_POLICY_REF, then policy/memory."))
        <*> optional (option nameReader (long "tiers-ref" <> metavar "NAME" <> help "The ref of the manifest of the tiers. The default is $AKYUU_TIERS_REF, then policy/tiers."))
        <*> option (eitherReader toolSetReader) (long "tool-set" <> metavar "ordinary|maintenance|topic|replicated" <> value MCP.Ordinary <> help "The default is ordinary. Topic exposes topic tools; replicated exposes experimental checkpoint tools.")
    toolSetReader "ordinary" = Right MCP.Ordinary
    toolSetReader "maintenance" = Right MCP.Maintenance
    toolSetReader "topic" = Right MCP.Topic
    toolSetReader "replicated" = Right MCP.Replicated
    toolSetReader _ = Left "The tool set must be ordinary, maintenance, topic or replicated."
    checkP =
      CheckArgs
        <$> ( CheckOptions
                <$> option unitDouble (long "near-threshold" <> metavar "X" <> value (nearThreshold defaultCheckOptions) <> showDefault <> help "The share of text (0 to 1) that two memories must have in common to be near duplicates.")
                <*> option (atLeast 0) (long "hub-degree" <> metavar "N" <> value (hubDegree defaultCheckOptions) <> showDefault <> help "A memory with more links than this is a hub.")
                <*> option (atLeast 1) (long "min-words" <> metavar "N" <> value (minWords defaultCheckOptions) <> showDefault <> help "Skip the near duplicate test for a text of fewer words.")
                <*> option (atLeast 1) (long "long-log" <> metavar "N" <> value (longLog defaultCheckOptions) <> showDefault <> help "A log with more episodes than this is long.")
            )
        <*> many (option checkKindReader (long "kind" <> metavar "KIND" <> help "Show only this kind of finding. Repeat for more."))
        <*> optional (option severityReader (long "severity" <> metavar "LEVEL" <> help "Show only this level or a higher one: info, suggestion or problem."))
        <*> switch (long "strict" <> help "Exit with code 1 if a problem is shown.")
        <*> switch (long "json" <> help "Print the findings as JSON.")
    gcP =
      GC
        <$> switch (long "dry-run" <> help "Only print what a run would collect. Write nothing.")
        <*> policyP
    policyP =
      Policy
        <$> option (atLeast 0) (long "keep-generations" <> metavar "N" <> value (keepGenerations defaultPolicy) <> showDefault <> help "How many older values of each ref to keep, as well as the current one.")
        <*> option (via parseDuration) (long "grace" <> metavar "DURATION" <> value (gracePeriod defaultPolicy) <> showDefaultWith showDuration <> help "Keep a memory that is younger than this. For example 30m, 1h or 7d.")
        <*> option (via parseDuration) (long "trash-ttl" <> metavar "DURATION" <> value (trashTTL defaultPolicy) <> showDefaultWith showDuration <> help "Delete a trash file that is older than this.")
    showDuration d = case [show (s `div` k) <> u | (k, u) <- [(86400, "d"), (3600, "h"), (60, "m")], s > 0, s `mod` k == 0] of
      (t : _) -> t
      [] -> show s <> "s"
      where
        s = round d :: Integer
    seedP =
      flag' () (long "demo" <> help "Make the demo store. This is the only kind of seed.")
        *> (Seed <$> optional (strOption (long "root" <> metavar "DIR" <> help "The directory of the new store. It must not hold a store with data.")))
    serveP =
      Serve
        <$> option
          portReader
          ( long "port"
              <> short 'p'
              <> metavar "N"
              <> value Server.defaultPort
              <> showDefault
              <> help "The port on 127.0.0.1. 0 means a free port."
          )
    portReader = do
      n <- atLeast 0
      if n <= 65535 then pure n else readerError "the port must be at most 65535"

cliParser :: Parser Cli
cliParser =
  Cli
    <$> optional (strOption (long "root" <> metavar "DIR" <> help "The directory of the store. The default is $AKYUU_ROOT, then root in the config file."))
    <*> optional (strOption (long "embed-profile" <> metavar "NAME" <> help "The embedding profile of the config file to use. The default is $AKYUU_EMBED_PROFILE, then embed.profile in the config file."))
    <*> commandParser

-- | The parser with its help text.
cliInfo :: ParserInfo Cli
cliInfo =
  info
    (cliParser <**> helper <**> infoOption ("akyuu " <> showVersion Pkg.version) (long "version" <> help "Print the version."))
    ( fullDesc
        <> progDesc "A content-addressed memory store for agents."
        <> footer "Exit codes: 0 success, 1 a failed operation, 2 bad usage."
    )

-- | Parse the arguments. This function is pure.
parseCli :: [String] -> ParserResult Cli
parseCli = execParserPure defaultPrefs cliInfo

-- Running --------------------------------------------------------------

-- | What a command prints on stdout, and whether it succeeded.
data Output = Output
  { -- | The bytes to print. For @get@ these are the bytes of the stored
    -- file, with nothing added, so a pipe or a file gets exactly them.
    outBytes :: ByteString,
    outOk :: Bool,
    -- | 'True' if a terminal should get a line feed at the end, when the
    -- bytes do not end with one. Only @get@ asks for this, because a body can
    -- end anywhere. See 'terminalBytes'.
    outEndLine :: Bool
  }
  deriving (Eq, Show)

ok :: [Text] -> Output
ok ls = Output (encodeUtf8 (T.unlines ls)) True False

-- | The bytes to write to stdout. @True@ means that stdout is a terminal.
--
-- A pipe or a file gets 'outBytes' exactly. A terminal gets a line feed at
-- the end if 'outEndLine' is set and the bytes do not end with one, so the
-- prompt of the shell does not land on the last line of the body.
terminalBytes :: Bool -> Output -> ByteString
terminalBytes isTerminal o
  | isTerminal && outEndLine o = withNewline (outBytes o)
  | otherwise = outBytes o

-- | Read the body of a new memory. It must be UTF-8 text.
readBody :: BodySource -> IO (Either AkyuuError Text)
readBody src = case src of
  BodyText t -> pure (Right t)
  BodyFile p -> do
    r <- try (BS.readFile p)
    pure $ case r of
      Left (e :: IOException) -> Left (BadInput ("The body file could not be read: " <> T.pack (show e)))
      Right bs -> decode bs
  BodyStdin -> decode <$> BS.getContents
  where
    decode = first (const (BadInput "The body is not valid UTF-8 text.")) . decodeUtf8'

-- | Read the body and make a 'NewMemory'.
newMemory :: MemoryArgs Id -> ExceptT AkyuuError IO NewMemory
newMemory a = do
  b <- ExceptT (readBody (argBody a))
  pure
    NewMemory
      { newKind = argKind a,
        newAgent = argAgent a,
        newEdges = Set.fromList [Edge k i | (k, i) <- argEdges a],
        newBody = b,
        newAboutRefs = Set.fromList (argAboutRefs a)
      }

-- | Find the whole 'Id' for each id that a person gave. See 'resolveId'.
-- The first id that cannot be found is the error.
resolveCommand :: Env -> Command IdSpec -> IO (Either AkyuuError (Command Id))
resolveCommand env = runExceptT . traverse (ExceptT . resolveId env)

-- | End the bytes with a line feed, if they do not end with one. A memory
-- file ends exactly where its body ends, so a body with no final line feed
-- would leave the prompt of the shell on the same line.
withNewline :: ByteString -> ByteString
withNewline bs
  | BS.null bs || BS.last bs == 10 = bs
  | otherwise = bs <> BS.singleton 10

-- | Run one command against an open store. 'Mcp' takes over stdin and
-- stdout until stdin ends, and then prints nothing more.
runCommand :: Env -> Command Id -> IO (Either AkyuuError Output)
runCommand env c = runExceptT $ case c of
  Replica _ -> throwE (BadInput "Replica commands must run against a checkpoint repository.")
  Add a -> do
    n <- newMemory a
    i <- ExceptT (addMemory env n)
    pure (ok [Id.render i])
  AddRef r a -> do
    n <- newMemory a
    i <- ExceptT (addUnderRef env r n)
    pure (ok [Id.render i])
  Get t withId -> do
    i <- case t of
      ById i -> pure i
      ByRef n -> current <$> ExceptT (readRef env n)
    m <- ExceptT (getMemory env i)
    let header = if withId then encodeUtf8 (idLine i <> "\n") else BS.empty
    pure (Output (header <> renderMemory m) True True)
  Supersede n old a -> do
    m <- newMemory a
    i <- ExceptT (supersedeMemory env n old m)
    pure (ok [Id.render i])
  Amend n e a es -> do
    i <- ExceptT (amendMemory env n e a es)
    pure (ok [Id.render i])
  RefGet n h -> ok . refLines h <$> ExceptT (readRef env n)
  RefSet n chk i -> ok . refLines False <$> ExceptT (setRefTo env n (expected chk) i)
  RefList -> ok . refListLines <$> ExceptT (listRefValues env)
  Pin i -> ok (pinLines i) <$ ExceptT (pinMemory env i)
  Unpin i -> ok (unpinLines i) <$ ExceptT (unpinMemory env i)
  Pins -> ok . pinListLines <$> ExceptT (listPinned env)
  Review a b agent note -> ok ["reviewed " <> Id.render a <> " " <> Id.render b] <$ ExceptT (reviewPair env a b agent note)
  Unreview a b -> ok ["unreviewed " <> Id.render a <> " " <> Id.render b] <$ ExceptT (unreviewPair env a b)
  Reviews -> ok . reviewLines <$> ExceptT (listReviewed env)
  Append n a -> do
    nm <- newMemory a
    i <- ExceptT (appendEpisode env n nm)
    pure (ok [Id.render i])
  Log n lim full since Plain -> do
    w <- ExceptT (maybe (readLog env n (maybe 20 id lim)) (readLogSince env n (maybe 200 id lim)) since)
    pure $ (ok (logLines full w)) {outOk = case walkEnd w of Interrupted _ _ -> False; _ -> True}
  Log n _ full _ view -> do
    levels <- ExceptT (readLevels env n)
    either (throwE . BadInput) (pure . ok) (viewLines full view levels)
  Summarise n level ids kind agent src -> do
    b <- ExceptT (readBody src)
    i <- ExceptT (summariseLog env n level ids NewMemory {newKind = kind, newAgent = agent, newEdges = Set.empty, newBody = b, newAboutRefs = Set.empty})
    pure (ok [Id.render i])
  Unfold i -> ok . concatMap (episodeLines True) <$> ExceptT (unfoldMemory env i)
  SourceAdd a -> do
    cfg <- config
    now <- liftIO getCurrentTime
    p0 <- either (throwE . BadInput) pure (Source.mkPointer (saFormat a) (saSession a) (fromMaybe now (saAt a)) (saFrom a) (saTo a) (saHint a))
    -- With --hash, the hash of the span comes from the file of the session as
    -- it is now, with the strip rule applied by engi.
    p <-
      if saHash a
        then do
          h <- ExceptT (first BadInput <$> Source.hashPointer Source.engiStrip (Config.sValue (Config.cfgSourceRoots cfg)) p0)
          either (throwE . BadInput) pure (Source.withSha256 h p0)
        else pure p0
    let who = fromMaybe (Config.sValue (Config.cfgAgent cfg)) (saAgent a)
    i <- ExceptT (addMemory env NewMemory {newKind = Source.sourceKind, newAgent = who, newEdges = Set.empty, newBody = Source.renderPointer p, newAboutRefs = Set.empty})
    pure (ok [Id.render i])
  SourceShow i before after -> do
    cfg <- config
    ps <- ExceptT (sourcePointers env i)
    let roots = Config.sValue (Config.cfgSourceRoots cfg)
    shown <- liftIO (mapM (\(pid, p) -> (,) (pid, p) <$> Source.showPointer roots (Source.Window before after) p) ps)
    pure ((ok (concatMap sourceShowLines shown)) {outOk = all (either (const False) (const True) . snd) shown})
  SourceHook format -> do
    payload <- liftIO BS.getContents
    pure (ok (maybe [] T.lines (Source.sessionHook format payload)))
  SourceVerify i -> do
    cfg <- config
    ps <- ExceptT (sourcePointers env i)
    let roots = Config.sValue (Config.cfgSourceRoots cfg)
    found <- liftIO (mapM (\(pid, p) -> (,) (pid, p) <$> Source.locate roots p) ps)
    -- A pointer that holds a hash, and whose session is here, is checked too:
    -- the span of records is read again and compared with the hash.
    checks <-
      liftIO $
        mapM
          ( \((_, p), located) -> case Source.pointerSha256 p of
              Just _ | not (null located) -> Just <$> Source.checkHash Source.engiStrip roots p
              _ -> pure Nothing
          )
          found
    pure
      ( (ok (zipWith (\f verdict -> sourceVerifyLine roots f <> maybe "" hashVerdictText verdict) found checks))
          { outOk = and (zipWith (\(_, located) verdict -> not (null located) && maybe True hashVerdictOk verdict) found checks)
          }
      )
  Context tier extra given cwd budget page -> do
    manifest <- liftIO (resolveTiersRef given)
    place <- liftIO (placeFor cwd)
    r <- ExceptT (either (pure . Left) (\mr -> contextFor env mr (maybe "always" id tier) (Just place) extra) manifest)
    pure . ok $ case (budget, page) of
      (Nothing, Nothing) -> tierLinesWithin Nothing r
      _ -> tierPage (fromMaybe 9500 budget) (fromMaybe 1 page) r
  Note cwd kind agent given about text -> do
    mr <- ExceptT (liftIO (resolveTiersRef given))
    place <- liftIO (placeFor cwd)
    cfg <- config
    let who = fromMaybe (Config.sValue (Config.cfgAgent cfg)) agent
    (n, i) <- ExceptT (noteEpisode env mr place NewMemory {newKind = kind, newAgent = who, newEdges = Set.empty, newBody = text, newAboutRefs = Set.fromList about})
    pure (ok ["noted in " <> nameText n <> " " <> Id.render i])
  Init -> do
    mr <- ExceptT (liftIO (resolveTiersRef Nothing))
    pr <- ExceptT (liftIO (resolvePolicyRef Nothing))
    ls <- ExceptT (initStore env pr mr)
    pure (ok (ls <> ["next: connect an agent (akyuu mcp), and see akyuu status"]))
  Status -> do
    mr <- ExceptT (liftIO (resolveTiersRef Nothing))
    pr <- ExceptT (liftIO (resolvePolicyRef Nothing))
    ok . statusLines <$> ExceptT (statusOf env (Store.storeRoot (envStore env)) mr pr)
  Embed prune -> do
    cfg <- config
    e <- maybe (ExceptT (pure (Left (BadInput "No embedding profile is set. Add one to the config file (see akyuu config and docs/embeddings.md).")))) pure (Embed.embedderFromConfig cfg)
    removed <- if prune then ExceptT (pruneEmbeddings env e) else pure 0
    ls <- embedLines (Embed.embModel e) <$> ExceptT (embedMissing env e)
    pure (ok (["pruned the vectors of " <> T.pack (show removed) <> " memories or models" | prune] <> ls))
  SearchEvalCmd given k -> do
    set <- except (maybe (first (BadName defaultEvalSetRef) (mkName defaultEvalSetRef)) Right given)
    ok . evalLines k <$> ExceptT (evalSearch env set k)
  Search mode o q -> do
    r <- ExceptT (searchMemoriesMode env mode o q)
    held <- either (const Map.empty) heldBy <$> liftIO (listRefValues env)
    pure (ok (searchLinesWith held r))
  Neighbours i -> do
    ns <- ExceptT (neighboursOf env i)
    ls <- ExceptT (refLinksOf env i)
    pure (ok (neighbourLines ns <> refLinkLines ls))
  Compare a b j -> do
    r <- ExceptT (compareMemories env a b)
    pure (if j then Output (BL.toStrict (encode (compareJSON r)) <> "\n") True False else ok (compareLines r))
  GC True p -> ok . planLines <$> ExceptT (dryRunGC env p)
  GC False p -> ok . runLines <$> ExceptT (runGC env p)
  Reindex -> ok . syncLines <$> ExceptT (reindexCache env)
  Verify -> do
    r <- ExceptT (verifyStore env)
    pure (Output (encodeUtf8 (T.unlines (verifyLines r))) (verifyOk r) False)
  CheckStore a -> do
    fs <- filterFindings (caKinds a) (caSeverity a) <$> ExceptT (checkStore env (caOptions a))
    refs <- ExceptT (listRefValues env)
    let out
          | caJson a = BL.toStrict (encode (toJSON (map findingJSON fs))) <> "\n"
          | otherwise = encodeUtf8 (T.unlines (findingLines refs fs))
    pure (Output out (not (caStrict a && any ((== Problem) . findingSeverity) fs)) False)
  Mcp givenPolicy givenTiers toolSet -> do
    policy <- liftIO (resolvePolicyRef givenPolicy)
    tiers <- liftIO (resolveTiersRef givenTiers)
    place <- liftIO (placeFor Nothing)
    -- Empty: the server takes the name of the client (MCP.clientAgent),
    -- unless the environment or the config file names an agent.
    cfg <- config
    let agent = case Config.cfgAgent cfg of
          Config.Sourced _ Config.Default -> ""
          s -> Config.sValue s
    let related
          | Config.sValue (Config.cfgRelated cfg) = Just (Related.Config (Config.sValue (Config.cfgParallel cfg)))
          | otherwise = Nothing
    -- The tool that shows a session is offered only if the config turns it on.
    let source
          | Config.sValue (Config.cfgSourceMcp cfg) = Just (Config.sValue (Config.cfgSourceRoots cfg))
          | otherwise = Nothing
    mcpConfig <- ExceptT (pure ((\p t -> MCP.McpConfig (nameText p) (nameText t) agent (Just place) toolSet related source) <$> policy <*> tiers))
    liftIO (MCP.serve mcpConfig env)
    pure (Output BS.empty True False)
  Serve port -> do
    liftIO (Server.serve env port announce)
    pure (Output BS.empty True False)
  Viz -> do
    v <- liftIO (Read.readBundle env)
    pure (Output (Page.vizPage v) True False)
  -- 'main' runs seed and config before it opens a store, so these cases are
  -- not used.
  Seed _ -> ExceptT (pure (Left (BadInput "seed makes its own store. It does not run on an open one.")))
  ShowConfig -> ok . configLines <$> config
  where
    config = ExceptT (first (BadConfig . Config.describeConfigError) <$> Config.loadConfig)
    -- The address goes to stdout alone, so a script can read it.
    announce p = do
      putStrLn ("http://127.0.0.1:" <> show p <> "/")
      hFlush stdout
      hPutStrLn stderr "akyuu serve: read-only, on 127.0.0.1 only. Stop it with Ctrl-C."
    expected NoCheck = Unchecked
    expected MustBeNew = MustBeAbsent
    expected (MustBeAt i) = MustBe i

-- | The program: parse the arguments, find the store, run the command.
runReplicaCommand :: FilePath -> ReplicaCommand Id -> IO (Either AkyuuError Output)
runReplicaCommand root (ReplicaSyncConfigure remote branch json) = syncOutput json $ fmap (fmap (const (object ["configured" .= True]))) (ReplicaSync.configure root remote branch)
runReplicaCommand root (ReplicaSync preview json) = syncOutput json (ReplicaSync.runSync root preview)
runReplicaCommand root (ReplicaSyncStatus json) = syncOutput json (ReplicaSync.status root)
runReplicaCommand root (ReplicaJoin remote branch label json) = syncOutput json (ReplicaSync.joinReplica root remote branch label)
runReplicaCommand root (ReplicaMigrate source classifications expected preview json) = syncOutput json $ do
  bytes <- tryWith ReplicaSync.SyncIO (BS.readFile classifications)
  case bytes of
    Left err -> pure (Left err)
    Right contents -> case eitherDecodeStrict' contents of
      Left _ -> pure (Left (ReplicaSync.SyncInvalid "The classification file must map ref names to topic or log."))
      Right kinds -> do
        result <- ReplicaMigration.planMigration source kinds
        case result of
          Left err -> pure (Left err)
          Right plan | preview -> pure (Right (ReplicaMigration.migrationJSON plan))
          Right plan -> case expected of
            Nothing -> pure (Left (ReplicaSync.SyncInvalid "Give --expected from replica migrate --dry-run before a copy."))
            Just token -> ReplicaMigration.copyMigration root plan token
runReplicaCommand root (ReplicaServe port options) = replicaWebAction root options $ \local settings -> do
  ExceptT (tryWith Topics.TopicIO (ReplicaWeb.serve local settings port (\actual -> putStrLn ("http://127.0.0.1:" <> show actual <> "/") >> hFlush stdout)))
  pure (Output BS.empty True False)
runReplicaCommand root (ReplicaViz options) = replicaWebAction root options $ \local settings -> do
  bytes <- ExceptT (ReplicaWeb.staticPage local settings)
  pure (Output bytes True False)
runReplicaCommand root operation = do
  result <- runExceptT $ case operation of
    ReplicaInit label _ -> do
      _ <- ExceptT (Topics.initialiseLocal root label)
      pure (object ["status" .= ("ready" :: Text)], "Local checkpoint replica initialised.")
    _ -> do
      local <- ExceptT (Topics.openLocal root)
      case operation of
        ReplicaRead name _ -> view <$> ExceptT (Topics.readTopic local name)
        ReplicaCreate name args _ -> new args >>= ExceptT . Topics.createTopic local name >>= pure . view
        ReplicaReplace name expected args _ -> new args >>= ExceptT . Topics.replaceTopic local name expected >>= pure . view
        ReplicaResolve name expected (SelectHead choice) _ -> do
          settings <- replicaSettings defaultReplicaContext
          view <$> ExceptT (Topics.selectTopicGuarded (ReplicaContext.resolutionGuard settings name) local name expected choice)
        ReplicaResolve name expected (MergeHeads args) _ -> do
          settings <- replicaSettings defaultReplicaContext
          content <- new args
          view <$> ExceptT (Topics.resolveTopicGuarded (ReplicaContext.resolutionGuard settings name) local name expected content)
        ReplicaConflicts _ -> context <$> ExceptT (Topics.conflicts local)
        ReplicaContext names _ -> context <$> ExceptT (Topics.contextTopics local names)
        ReplicaConfiguredContext args _ -> do
          settings <- replicaSettings args
          report <- ExceptT (ReplicaContext.configuredContext local settings)
          pure (ReplicaContext.reportJSON report, ReplicaContext.renderReport report)
        ReplicaSearch text limit _ -> do
          report <- ExceptT (ReplicaSearch.searchTopics local text limit)
          pure (ReplicaSearch.searchJSON report, ReplicaSearch.renderSearch report)
        ReplicaLog name limit _ -> do
          report <- ExceptT (ReplicaLogs.readLog local name limit)
          pure (ReplicaLogs.logJSON report, ReplicaLogs.renderLog report)
        ReplicaAppend name expected args _ -> new args >>= ExceptT . ReplicaLogs.appendLog local name expected >>= pure . view
        ReplicaLevels name _ -> do
          report <- ExceptT (ReplicaLogs.readLevels local name)
          pure (ReplicaLogs.levelsJSON report, Id.render (ReplicaLogs.levelsToken report))
        ReplicaSummarise name expected level sources args _ -> new args >>= ExceptT . ReplicaLogs.summarise local name expected level sources >>= pure . view
        ReplicaResolution name keep _ -> do
          levels <- ExceptT (ReplicaLogs.readLevels local name)
          items <- either (throwE . Topics.InvalidInput) pure (ReplicaLogs.resolution keep levels)
          pure (object ["version" .= Id.render (ReplicaLogs.levelsToken levels), "view" .= ReplicaLogs.itemsJSON items], T.unlines (map (memBody . ReplicaLogs.itemMemory) items))
        ReplicaTodo name size keep _ -> do
          levels <- ExceptT (ReplicaLogs.readLevels local name)
          runs <- either (throwE . Topics.InvalidInput) pure (ReplicaLogs.todo size keep levels)
          let payload = object ["version" .= Id.render (ReplicaLogs.levelsToken levels), "runs" .= [object ["level" .= level, "sources" .= map Id.render sources] | (level, sources) <- runs]]
          pure (payload, decodeUtf8 (BL.toStrict (encode payload)))
        ReplicaUnfold digest _ -> do
          entries <- ExceptT (ReplicaLogs.unfold local digest)
          pure (ReplicaLogs.entriesJSON entries, T.unlines (map (memBody . snd) entries))
        ReplicaArchive _ -> do
          repo <- repository
          snapshot <- ExceptT (Topics.captureSnapshot local)
          CheckpointId digest <- store (ReplicaRepository.archiveSnapshot repo snapshot)
          pure (object ["archived_checkpoint" .= Id.render digest], "Local archive saved: " <> Id.render digest)
        ReplicaGC depth expected dry _ -> do
          repo <- repository
          report <-
            if dry
              then store (ReplicaRepository.planCollection repo depth)
              else case expected of
                Nothing -> throwE (Topics.InvalidInput "Give --expected from replica gc --dry-run before collection.")
                Just digest -> store (ReplicaRepository.collect repo (CheckpointId digest) depth)
          let CheckpointId checkpoint = ReplicaRepository.collectionCheckpoint report
              ids = map Id.render . Set.toAscList
              payload = object ["checkpoint" .= Id.render checkpoint, "retained" .= ids (ReplicaRepository.collectionRetained report), "candidates" .= ids (ReplicaRepository.collectionCandidates report), "evicted" .= ids (ReplicaRepository.collectionEvicted report)]
          pure (payload, decodeUtf8 (BL.toStrict (encode payload)))
        ReplicaPinState digest _ -> resource (ReplicaResources.readResource local (PinResource digest))
        ReplicaPin digest expected pin _ -> resource (ReplicaResources.writeResource local expected (if pin then SetPin digest else ClearPin digest))
        ReplicaReviewState a b _ -> resource (ReplicaResources.readResource local (ReviewResource a b))
        ReplicaReview a b expected author reason _ -> resource (ReplicaResources.writeResource local expected (SetReview a b (ReviewValue author reason)))
        ReplicaUnreview a b expected _ -> resource (ReplicaResources.writeResource local expected (ClearReview a b))
  pure $ case result of
    Right (payload, text) -> Right (output True payload text)
    Left err | json -> Right (output False (Topics.errorJSON err) (Topics.describeError err))
    Left err -> Left (BadInput (Topics.describeError err <> details err))
  where
    json = case operation of
      ReplicaInit _ flag -> flag
      ReplicaRead _ flag -> flag
      ReplicaCreate _ _ flag -> flag
      ReplicaReplace _ _ _ flag -> flag
      ReplicaResolve _ _ _ flag -> flag
      ReplicaConflicts flag -> flag
      ReplicaContext _ flag -> flag
      ReplicaConfiguredContext _ flag -> flag
      ReplicaSearch _ _ flag -> flag
      ReplicaLog _ _ flag -> flag
      ReplicaAppend _ _ _ flag -> flag
      ReplicaLevels _ flag -> flag
      ReplicaSummarise _ _ _ _ _ flag -> flag
      ReplicaResolution _ _ flag -> flag
      ReplicaTodo _ _ _ flag -> flag
      ReplicaUnfold _ flag -> flag
      ReplicaArchive flag -> flag
      ReplicaGC _ _ _ flag -> flag
      ReplicaPinState _ flag -> flag
      ReplicaPin _ _ _ flag -> flag
      ReplicaReviewState _ _ flag -> flag
      ReplicaReview _ _ _ _ _ flag -> flag
      ReplicaUnreview _ _ _ flag -> flag
    store = ExceptT . fmap (first Topics.StorageError)
    repository = store (ReplicaRepository.openRepository root)
    resource action = do
      payload <- ExceptT action
      pure (payload, decodeUtf8 (BL.toStrict (encode payload)))
    new args = ExceptT (first (Topics.InvalidInput . describe) <$> runExceptT (newMemory args))
    view report = (Topics.viewJSON report, Topics.renderView report)
    context report@(Topics.TopicContext _ views) = (Topics.contextJSON report, T.concat (map Topics.renderView views))
    output success payload text = Output (if json then BL.toStrict (encode payload) <> "\n" else encodeUtf8 (withTextNewline text)) success False
    withTextNewline text = if T.isSuffixOf "\n" text then text else text <> "\n"
    details err = case err of
      Topics.ExistingTopic report -> "\n" <> Topics.renderView report
      Topics.NeedsResolution report -> "\n" <> Topics.renderView report
      Topics.StaleTopic report -> "\n" <> Topics.renderView report
      _ -> ""

defaultReplicaContext :: ReplicaContextArgs
defaultReplicaContext = ReplicaContextArgs Nothing Nothing "always" Nothing [] ReplicaLogs.defaultPageOptions

syncOutput :: Bool -> IO (Either ReplicaSync.SyncError Value) -> IO (Either AkyuuError Output)
syncOutput json action = do
  result <- action
  pure $ case result of
    Right payload -> Right (Output (BL.toStrict (encode payload) <> "\n") True False)
    Left err | json -> Right (Output (BL.toStrict (encode (object ["error" .= ("sync-error" :: Text), "message" .= ReplicaSync.describeSyncError err])) <> "\n") False False)
    Left err -> Left (BadInput (ReplicaSync.describeSyncError err))

replicaSettings :: ReplicaContextArgs -> ExceptT Topics.TopicError IO ReplicaContext.ContextOptions
replicaSettings (ReplicaContextArgs policy tiers tier cwd extras pages) = do
  p <- ExceptT (first (Topics.InvalidInput . describe) <$> resolvePolicyRef policy)
  t <- ExceptT (first (Topics.InvalidInput . describe) <$> resolveTiersRef tiers)
  place <- ExceptT (tryWith Topics.TopicIO (placeFor cwd))
  pure (ReplicaContext.ContextOptions p t tier (Just place) extras pages)

replicaWebAction :: FilePath -> ReplicaContextArgs -> (Topics.LocalReplica -> ReplicaContext.ContextOptions -> ExceptT Topics.TopicError IO Output) -> IO (Either AkyuuError Output)
replicaWebAction root options action = do
  result <- runExceptT $ do
    local <- ExceptT (Topics.openLocal root)
    settings <- replicaSettings options
    action local settings
  pure (first (BadInput . Topics.describeError) result)

-- | The program: parse the arguments, find the store, run the command.
main :: IO ()
main = do
  args <- getArgs
  prog <- getProgName
  case parseCli args of
    Success cli -> do
      -- The option goes into the environment, so that every part that reads
      -- the config (and an MCP server, for its whole life) sees it.
      mapM_ (setEnv "AKYUU_EMBED_PROFILE" . T.unpack) (cliProfile cli)
      rc <- Config.loadConfig
      let seedRoot = case cliCommand cli of
            Seed r -> r
            _ -> Nothing
          configRoot = either (const Nothing) (fmap Config.sValue . Config.cfgRoot) rc
      case (cliCommand cli, rc) of
        -- config shows the settings, or says what is wrong with the file.
        (ShowConfig, Left err) -> failWith 2 (BadConfig (Config.describeConfigError err))
        (ShowConfig, Right c) -> do
          let fromFlag e = case cliProfile cli of
                Just _ -> e {Config.esSource = Config.FromFlag}
                Nothing -> e
              c' = (Config.withRootOption (cliRoot cli) c) {Config.cfgEmbed = fromFlag <$> Config.cfgEmbed c}
          BS.putStr (encodeUtf8 (T.unlines (configLines c')))
          exitWith ExitSuccess
        (_, Left err) -> failWith 2 (BadConfig (Config.describeConfigError err))
        _ -> pure ()
      case resolveRoot (maybe (cliRoot cli) Just seedRoot) configRoot of
        Left e -> failWith 2 e
        Right root -> do
          r <- case cliCommand cli of
            Replica operation -> case traverse fullId operation of
              Left err -> pure (Left err)
              Right resolved -> runReplicaCommand root resolved
            Mcp givenPolicy givenTiers MCP.Replicated -> runExceptT $ do
              policy <- ExceptT (resolvePolicyRef givenPolicy)
              tiers <- ExceptT (resolveTiersRef givenTiers)
              local <- ExceptT (first (BadInput . Topics.describeError) <$> Topics.openLocal root)
              place <- liftIO (placeFor Nothing)
              let configured = case rc of
                    Right cfg -> case Config.cfgAgent cfg of
                      Config.Sourced _ Config.Default -> ""
                      setting -> Config.sValue setting
                    Left _ -> ""
              liftIO (MCP.serveReplica (MCP.defaultMcpConfig {MCP.mcpAgent = configured, MCP.mcpPolicyRef = nameText policy, MCP.mcpTiersRef = nameText tiers, MCP.mcpPlace = Just place, MCP.mcpToolSet = MCP.Replicated}) local)
              pure (Output BS.empty True False)
            -- seed makes the store, so it runs before withEnv.
            Seed _ -> do
              now <- getCurrentTime
              fmap (ok . Seed.demoLines root) <$> Seed.seedDemo root now
            -- init may make the root; every other command needs it to exist.
            Init -> do
              createDirectoryIfMissing True root
              withEnv root $ \env -> runCommand env Init
            _ ->
              withEnv root $ \env -> runExceptT $ do
                c <- ExceptT (resolveCommand env (cliCommand cli))
                ExceptT (runCommand env c)
          case r of
            Left e -> failWith 1 e
            Right o -> do
              tty <- hIsTerminalDevice stdout
              BS.putStr (terminalBytes tty o)
              exitWith (if outOk o then ExitSuccess else ExitFailure 1)
    Failure f -> do
      let (msg, code) = renderFailure f prog
      case code of
        ExitSuccess -> putStrLn msg >> exitWith ExitSuccess
        ExitFailure _ -> hPutStrLn stderr msg >> exitWith (ExitFailure 2)
    CompletionInvoked comp -> do
      msg <- execCompletion comp prog
      putStr msg
      exitWith ExitSuccess
  where
    fullId (Ops.Full digest) = Right digest
    fullId (Ops.Prefix _) = Left (BadInput "Replica commands require complete memory IDs; prefixes are not supported yet.")
    failWith code e = do
      BS.hPut stderr (encodeUtf8 ("akyuu: " <> describe e <> "\n"))
      exitWith (ExitFailure code)

-- Check ----------------------------------------------------------------

-- | The arguments of @check@.
data CheckArgs = CheckArgs
  { caOptions :: CheckOptions,
    -- | Show only these kinds. Empty means every kind.
    caKinds :: [FindingKind],
    -- | Show only this severity or a more serious one.
    caSeverity :: Maybe Severity,
    caStrict :: Bool,
    caJson :: Bool
  }
  deriving (Eq, Show)

checkKindReader :: ReadM FindingKind
checkKindReader = via $ \t ->
  maybe (Left (BadInput (bad t))) Right (lookup t [(kindName k, k) | k <- [minBound .. maxBound]])
  where
    bad t = "'" <> t <> "' is not a kind of finding. Use " <> T.intercalate ", " (map kindName [minBound .. maxBound]) <> "."

severityReader :: ReadM Severity
severityReader = via $ \t ->
  maybe (Left (BadInput (bad t))) Right (lookup t [(severityName s, s) | s <- [minBound .. maxBound]])
  where
    bad t = "'" <> t <> "' is not a level. Use " <> T.intercalate ", " (map severityName [minBound .. maxBound]) <> "."

-- | A number from 0 to 1.
unitDouble :: ReadM Double
unitDouble = do
  x <- auto
  if x >= 0 && x <= 1 then pure x else readerError "the number must be from 0 to 1"

-- | Where the command runs: the home directory, and the directory that was
-- given or else the current one.
placeFor :: Maybe Text -> IO Place
placeFor given = do
  home <- maybe "" T.pack <$> lookupEnv "HOME"
  dir <- maybe (T.pack <$> getCurrentDirectory) pure given
  pure (Place home dir)
