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

import Akyuu.Error (AkyuuError (..), describe)
import Akyuu.GC (Policy (..), defaultPolicy)
import Akyuu.Graph (Edge (..), EdgeType (..))
import Akyuu.Id (Id)
import Akyuu.Id qualified as Id
import Akyuu.Memory (renderMemory)
import Akyuu.Ops
import Akyuu.Query (SearchOptions (..), defaultSearchOptions)
import Akyuu.Refs (Expected (..), Name, Ref (current), mkName)
import Akyuu.MCP qualified as MCP
import Akyuu.Web.Page qualified as Page
import Akyuu.Web.Read qualified as Read
import Akyuu.Web.Server qualified as Server
import Akyuu.Seed qualified as Seed
import Data.Time (getCurrentTime)
import Akyuu.Render
import Control.Monad.IO.Class (liftIO)
import Control.Exception (IOException, try)
import Control.Monad.Trans.Except (ExceptT (ExceptT), runExceptT)
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (decodeUtf8', encodeUtf8)
import Options.Applicative
import System.Environment (getArgs, getProgName, lookupEnv)
import System.Exit (ExitCode (..), exitWith)
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
  | -- | The ref, and 'True' to show its older values too.
    RefGet Name Bool
  | RefSet Name (Check i) i
  | RefList
  | -- | Pin a memory, so that GC keeps it.
    Pin i
  | Unpin i
  | -- | Print the pins.
    Pins
  | Search SearchOptions Text
  | Neighbours i
  | -- | 'True' for @--dry-run@, and the policy of the run.
    GC Bool Policy
  | Reindex
  | Verify
  | -- | Serve MCP on stdin and stdout until stdin ends.
    Mcp
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
      <> cmd "ref" refP "Read, set or list refs."
      <> cmd "pin" (Pin <$> argument idReader (metavar "ID")) "Pin a memory, so that GC keeps it."
      <> cmd "unpin" (Unpin <$> argument idReader (metavar "ID")) "Remove the pin of a memory."
      <> cmd "pins" (pure Pins) "Print the id of each pinned memory."
      <> cmd "search" searchP "Search the memories for words, and show the memories near each hit."
      <> cmd "neighbours" neighboursP "Show the edges of a memory, in both directions."
      <> cmd "gc" gcP "Collect the memories that nothing needs."
      <> cmd "reindex" (pure Reindex) "Throw the cache away and read the whole store again."
      <> cmd "verify" (pure Verify) "Check every object, edge and ref of the store."
      <> cmd "mcp" (pure Mcp) "Serve the MCP protocol (JSON-RPC 2.0) on stdin and stdout, until stdin ends."
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
  RefGet n h -> ok . refLines h <$> ExceptT (readRef env n)
  RefSet n chk i -> ok . refLines False <$> ExceptT (setRefTo env n (expected chk) i)
  RefList -> ok . refListLines <$> ExceptT (listRefValues env)
  Pin i -> ok (pinLines i) <$ ExceptT (pinMemory env i)
  Unpin i -> ok (unpinLines i) <$ ExceptT (unpinMemory env i)
  Pins -> ok . pinListLines <$> ExceptT (listPinned env)
  Search o q -> ok . searchLines <$> ExceptT (searchMemories env o q)
  Neighbours i -> ok . neighbourLines <$> ExceptT (neighboursOf env i)
  GC True p -> ok . planLines <$> ExceptT (dryRunGC env p)
  GC False p -> ok . runLines <$> ExceptT (runGC env p)
  Reindex -> ok . syncLines <$> ExceptT (reindexCache env)
  Verify -> do
    r <- ExceptT (verifyStore env)
    pure (Output (encodeUtf8 (T.unlines (verifyLines r))) (verifyOk r) False)
  Mcp -> do
    liftIO (MCP.serve env)
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
