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
    MemoryArgs (..),
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
    withNewline,
    terminalBytes,
    main,
  )
where

import Akyuu.Amend qualified as Amend
import Akyuu.Check (CheckOptions (CheckOptions, hubDegree, minWords, nearThreshold), Finding (findingSeverity), FindingKind, Severity (Problem), defaultCheckOptions, filterFindings, kindName, severityName)
import Akyuu.Error (AkyuuError (BadInput, BadName), describe)
import Akyuu.GC (Policy (Policy, gracePeriod, keepGenerations, trashTTL), defaultPolicy)
import Akyuu.Graph (Edge (Edge), EdgeType (About, DerivedFrom, Refines, Supersedes))
import Akyuu.Id (Id)
import Akyuu.Id qualified as Id
import Akyuu.MCP qualified as MCP
import Akyuu.Memory (renderMemory)
import Akyuu.Ops (Env, IdSpec, NewMemory (NewMemory, newAgent, newBody, newEdges, newKind), addMemory, amendMemory, appendEpisode, checkField, checkStore, compareMemories, contextFor, dryRunGC, getMemory, listPinned, listRefValues, listReviewed, neighboursOf, parseDuration, parseIdSpec, pinMemory, readLog, readRef, reindexCache, resolveId, resolveRoot, reviewPair, runGC, searchMemories, setRefTo, supersedeMemory, unpinMemory, unreviewPair, verifyOk, verifyStore, withEnv)
import Akyuu.Query (SearchOptions (SearchOptions, searchFollow, searchHops, searchLimit), defaultSearchOptions)
import Akyuu.Refs (Expected (MustBe, MustBeAbsent, Unchecked), Name, Ref (current), mkName, nameText)
import Akyuu.Render (compareJSON, compareLines, edgeName, findingJSON, findingLines, heldBy, logLines, neighbourLines, pinLines, pinListLines, planLines, refLines, refListLines, reviewLines, runLines, searchLinesWith, syncLines, tierLines, unpinLines, verifyLines)
import Akyuu.Seed qualified as Seed
import Akyuu.Web.Page qualified as Page
import Akyuu.Web.Read qualified as Read
import Akyuu.Web.Server qualified as Server
import Control.Exception (IOException, try)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Trans.Except (ExceptT (ExceptT), runExceptT)
import Data.Aeson (encode, toJSON)
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BL
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (decodeUtf8', encodeUtf8)
import Data.Time (getCurrentTime)
import Options.Applicative (Alternative (many, some, (<|>)), CompletionResult (execCompletion), Parser, ParserInfo, ParserResult (CompletionInvoked, Failure, Success), ReadM, argument, auto, command, defaultPrefs, eitherReader, execParserPure, flag', footer, fullDesc, help, helper, hsubparser, info, long, metavar, option, optional, progDesc, readerError, renderFailure, short, showDefault, showDefaultWith, strArgument, strOption, switch, value, (<**>))
import System.Environment (getArgs, getProgName, lookupEnv)
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
data Command i
  = Add (MemoryArgs i)
  | Get (GetTarget i)
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
  | -- | The tier, extra refs, and the ref of the manifest ('Nothing' for the default).
    Context (Maybe Text) [Name] (Maybe Name)
  | -- | Append an episode to the log that a ref names.
    Append Name (MemoryArgs i)
  | -- | Read a log: the ref, the most episodes ('Nothing' for the default),
    -- and 'True' for the bodies.
    Log Name (Maybe Int) Bool
  | Search SearchOptions Text
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
    Mcp (Maybe Name) (Maybe Name)
  | -- | Serve the web UI on 127.0.0.1 at this port, until the program is
    -- stopped. Port 0 is a free port.
    Serve Int
  | -- | Print the web UI as one HTML file, with the data of the store in it.
    Viz
  | -- | Make the demo store (@seed --demo@), in this directory or the root.
    Seed (Maybe FilePath)
  deriving (Eq, Show, Functor, Foldable, Traversable)

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

memoryArgs :: Parser (MemoryArgs IdSpec)
memoryArgs =
  MemoryArgs
    <$> field "kind" "The kind of memory, for example fact or preference."
    <*> field "agent" "The name of the agent that writes the memory."
    <*> edges
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
    body =
      (BodyText <$> strOption (long "body" <> metavar "TEXT" <> help "The body of the memory."))
        <|> (BodyFile <$> strOption (long "file" <> short 'f' <> metavar "PATH" <> help "Read the body from a file."))
        <|> pure BodyStdin

commandParser :: Parser (Command IdSpec)
commandParser =
  hsubparser $
    cmd "add" addP "Add a memory and print its id. The body comes from --body, --file or stdin."
      <> cmd "get" getP "Print a memory, by id (or the start of one) or by ref."
      <> cmd "supersede" supersedeP "Replace the memory of a ref with a new one, and print the new id."
      <> cmd "amend" amendP "Change some text of the memory of a ref: replace one passage, or add text at the end. Prints the new id."
      <> cmd "ref" refP "Read, set or list refs."
      <> cmd "pin" (Pin <$> argument idReader (metavar "ID")) "Pin a memory, so that GC keeps it."
      <> cmd "unpin" (Unpin <$> argument idReader (metavar "ID")) "Remove the pin of a memory."
      <> cmd "pins" (pure Pins) "Print the id of each pinned memory."
      <> cmd "review" reviewP "Record that two memories are different and both true, so that check leaves the pair out."
      <> cmd "unreview" (Unreview <$> argument idReader (metavar "ID_A") <*> argument idReader (metavar "ID_B")) "Remove the review of a pair."
      <> cmd "reviews" (pure Reviews) "Print the reviewed pairs."
      <> cmd "append" appendP "Add an episode to a log: a memory that points at the one before it, under a ref that moves to it."
      <> cmd "log" logP "Print the episodes of a log, newest first."
      <> cmd "context" contextP "Print the memories of a tier (the profile, the policy and so on) in one call, for the start of a session."
      <> cmd "search" searchP "Search the memories for words, and show the memories near each hit."
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
    addP = Add <$> memoryArgs
    getP =
      Get
        <$> ( (ById <$> argument idReader (metavar "ID"))
                <|> (ByRef <$> option nameReader (long "ref" <> metavar "NAME" <> help "Print the current memory of this ref."))
            )
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
        <$> searchOpts
        <*> (T.unwords <$> some (strArgument (metavar "WORDS...")))
    searchOpts =
      (\l h ks -> SearchOptions l h (if null ks then searchFollow defaultSearchOptions else Set.fromList ks))
        <$> option (atLeast 1) (long "limit" <> short 'n' <> metavar "N" <> value (searchLimit defaultSearchOptions) <> showDefault <> help "The most hits to show.")
        <*> option (atLeast 0) (long "hops" <> metavar "N" <> value (searchHops defaultSearchOptions) <> showDefault <> help "How many edges away from a hit to look.")
        <*> many (option kindReader (long "follow" <> metavar "KIND" <> help "Follow only this kind of edge. Repeat for more. The default is all kinds."))
    neighboursP = Neighbours <$> argument idReader (metavar "ID")
    appendP = Append <$> argument nameReader (metavar "REF") <*> memoryArgs
    logP =
      Log
        <$> argument nameReader (metavar "REF")
        <*> optional (option (atLeast 1) (long "limit" <> short 'n' <> metavar "N" <> help "The most episodes to print. The default is 20."))
        <*> switch (long "full" <> help "Print the body of each episode.")
    contextP =
      Context
        <$> optional (strOption (long "tier" <> metavar "NAME" <> help "The tier to print. The default is always."))
        <*> many (option nameReader (long "ref" <> metavar "NAME" <> help "Also print this ref. Repeat for more."))
        <*> optional (option nameReader (long "manifest" <> metavar "NAME" <> help "The ref of the manifest. The default is $AKYUU_TIERS_REF, then policy/tiers."))
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
    checkP =
      CheckArgs
        <$> ( CheckOptions
                <$> option unitDouble (long "near-threshold" <> metavar "X" <> value (nearThreshold defaultCheckOptions) <> showDefault <> help "The share of text (0 to 1) that two memories must have in common to be near duplicates.")
                <*> option (atLeast 0) (long "hub-degree" <> metavar "N" <> value (hubDegree defaultCheckOptions) <> showDefault <> help "A memory with more links than this is a hub.")
                <*> option (atLeast 1) (long "min-words" <> metavar "N" <> value (minWords defaultCheckOptions) <> showDefault <> help "Skip the near duplicate test for a text of fewer words.")
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
    <$> optional (strOption (long "root" <> metavar "DIR" <> help "The directory of the store. The default is $AKYUU_ROOT."))
    <*> commandParser

-- | The parser with its help text.
cliInfo :: ParserInfo Cli
cliInfo =
  info
    (cliParser <**> helper)
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
        newBody = b
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
  Add a -> do
    n <- newMemory a
    i <- ExceptT (addMemory env n)
    pure (ok [Id.render i])
  Get t -> do
    i <- case t of
      ById i -> pure i
      ByRef n -> current <$> ExceptT (readRef env n)
    m <- ExceptT (getMemory env i)
    pure (Output (renderMemory m) True True)
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
  Log n lim full -> do
    w <- ExceptT (readLog env n (maybe 20 id lim))
    pure (ok (logLines full w))
  Context tier extra given -> do
    manifest <- liftIO (manifestRef given)
    r <- ExceptT (either (pure . Left) (\mr -> contextFor env mr (maybe "always" id tier) extra) manifest)
    pure (ok (tierLines r))
  Search o q -> do
    r <- ExceptT (searchMemories env o q)
    held <- either (const Map.empty) heldBy <$> liftIO (listRefValues env)
    pure (ok (searchLinesWith held r))
  Neighbours i -> ok . neighbourLines <$> ExceptT (neighboursOf env i)
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
  Mcp givenPolicy givenTiers -> do
    policy <- liftIO (refFromEnv "AKYUU_POLICY_REF" "policy/memory" givenPolicy)
    tiers <- liftIO (manifestRef givenTiers)
    mcpConfig <- ExceptT (pure (MCP.McpConfig . nameText <$> policy <*> (nameText <$> tiers)))
    liftIO (MCP.serve mcpConfig env)
    pure (Output BS.empty True False)
  Serve port -> do
    liftIO (Server.serve env port announce)
    pure (Output BS.empty True False)
  Viz -> do
    v <- liftIO (Read.readBundle env)
    pure (Output (Page.vizPage v) True False)
  -- 'main' runs seed before it opens a store, so this case is not used.
  Seed _ -> ExceptT (pure (Left (BadInput "seed makes its own store. It does not run on an open one.")))
  where
    -- The address goes to stdout alone, so a script can read it.
    announce p = do
      putStrLn ("http://127.0.0.1:" <> show p <> "/")
      hFlush stdout
      hPutStrLn stderr "akyuu serve: read-only, on 127.0.0.1 only. Stop it with Ctrl-C."
    expected NoCheck = Unchecked
    expected MustBeNew = MustBeAbsent
    expected (MustBeAt i) = MustBe i

-- | The program: parse the arguments, find the store, run the command.
main :: IO ()
main = do
  args <- getArgs
  prog <- getProgName
  case parseCli args of
    Success cli -> do
      envRoot <- lookupEnv "AKYUU_ROOT"
      let seedRoot = case cliCommand cli of
            Seed r -> r
            _ -> Nothing
      case resolveRoot (maybe (cliRoot cli) Just seedRoot) envRoot of
        Left e -> failWith 2 e
        Right root -> do
          r <- case cliCommand cli of
            -- seed makes the store, so it runs before withEnv.
            Seed _ -> do
              now <- getCurrentTime
              fmap (ok . Seed.demoLines root) <$> Seed.seedDemo root now
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

-- | A ref name from an option, then from an environment variable, then the
-- default.
refFromEnv :: String -> Text -> Maybe Name -> IO (Either AkyuuError Name)
refFromEnv _ _ (Just n) = pure (Right n)
refFromEnv var def Nothing = do
  fromEnv <- lookupEnv var
  let t = case fromEnv of
        Just v | not (null v) -> T.pack v
        _ -> def
  pure (first (BadName t) (mkName t))

-- | The ref of the manifest of the tiers: the option, then @AKYUU_TIERS_REF@,
-- then @policy/tiers@.
manifestRef :: Maybe Name -> IO (Either AkyuuError Name)
manifestRef = refFromEnv "AKYUU_TIERS_REF" "policy/tiers"
