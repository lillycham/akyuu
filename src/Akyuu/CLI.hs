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

    -- * Parsing
    cliInfo,
    parseCli,

    -- * Running
    Output (..),
    readBody,
    runCommand,
    main,
  )
where

import Akyuu.Error (AkyuuError (..), describe)
import Akyuu.Graph (Edge (..), EdgeType (..))
import Akyuu.Id (Id)
import Akyuu.Id qualified as Id
import Akyuu.Memory (renderMemory)
import Akyuu.Ops
import Akyuu.Query (SearchOptions (..), defaultSearchOptions)
import Akyuu.Refs (Expected (..), Name, Ref (current), mkName, nameText)
import Akyuu.Render
import Control.Exception (IOException, try)
import Control.Monad.Trans.Except (ExceptT (ExceptT), runExceptT)
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (decodeUtf8', encodeUtf8)
import Options.Applicative
import System.Environment (getArgs, getProgName, lookupEnv)
import System.Exit (ExitCode (..), exitWith)
import System.IO (hPutStrLn, stderr)

-- Commands -------------------------------------------------------------

-- | A whole command line: the global options and one command.
data Cli = Cli
  { -- | The @--root@ option, if it was given. See 'resolveRoot'.
    cliRoot :: Maybe FilePath,
    cliCommand :: Command
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

-- | The options of a new memory, before the body is read.
data MemoryArgs = MemoryArgs
  { argKind :: Text,
    argAgent :: Text,
    argEdges :: Set Edge,
    argBody :: BodySource
  }
  deriving (Eq, Show)

-- | What @get@ reads.
data GetTarget
  = ById Id
  | -- | The current memory of a ref (@--ref@).
    ByRef Name
  deriving (Eq, Show)

-- | One command.
data Command
  = Add MemoryArgs
  | Get GetTarget
  | -- | The ref, the 'Id' that the ref must point to now (@--expect@), and
    -- the new memory.
    Supersede Name (Maybe Id) MemoryArgs
  | -- | The ref, and 'True' to show its older values too.
    RefGet Name Bool
  | RefSet Name Expected Id
  | RefList
  | Search SearchOptions Text
  | Neighbours Id
  | -- | 'True' for @--dry-run@.
    GC Bool
  | Reindex
  | Verify
  deriving (Eq, Show)

-- Parsing --------------------------------------------------------------

-- | A reader that uses a function of the library. The text of a 'Left' is
-- the friendly text of the error.
via :: (Text -> Either AkyuuError a) -> ReadM a
via f = eitherReader (first (T.unpack . describe) . f . T.pack)

idReader :: ReadM Id
idReader = via (\t -> first (BadId t) (Id.parse t))

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

memoryArgs :: Parser MemoryArgs
memoryArgs =
  MemoryArgs
    <$> field "kind" "The kind of memory, for example fact or preference."
    <*> field "agent" "The name of the agent that writes the memory."
    <*> edges
    <*> body
  where
    field n h = option (via (checkField n)) (long (T.unpack n) <> metavar "TEXT" <> help h)
    edgeOpt k h = many (Edge k <$> option idReader (long (T.unpack (edgeName k)) <> metavar "ID" <> help h))
    edges =
      (\a b c d -> Set.fromList (a <> b <> c <> d))
        <$> edgeOpt About "The new memory is about the memory ID. Repeat for more."
        <*> edgeOpt DerivedFrom "The new memory comes from the memory ID."
        <*> edgeOpt Refines "The new memory adds detail to the memory ID."
        <*> edgeOpt Supersedes "The new memory replaces the memory ID. The supersede command adds this edge for you."
    body =
      (BodyText <$> strOption (long "body" <> metavar "TEXT" <> help "The body of the memory."))
        <|> (BodyFile <$> strOption (long "file" <> short 'f' <> metavar "PATH" <> help "Read the body from a file."))
        <|> pure BodyStdin

commandParser :: Parser Command
commandParser =
  hsubparser $
    cmd "add" addP "Add a memory and print its id. The body comes from --body, --file or stdin."
      <> cmd "get" getP "Print a memory, by id or by ref."
      <> cmd "supersede" supersedeP "Replace the memory of a ref with a new one, and print the new id."
      <> cmd "ref" refP "Read, set or list refs."
      <> cmd "search" searchP "Search the memories for words, and show the memories near each hit."
      <> cmd "neighbours" neighboursP "Show the edges of a memory, in both directions."
      <> cmd "gc" gcP "Collect the memories that nothing needs."
      <> cmd "reindex" (pure Reindex) "Throw the cache away and read the whole store again."
      <> cmd "verify" (pure Verify) "Check every object, edge and ref of the store."
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
          <> cmd "list" (pure RefList) "Print the names of all refs."
    refGetP =
      RefGet
        <$> argument nameReader (metavar "NAME")
        <*> switch (long "history" <> help "Also print the older values, newest first.")
    refSetP =
      (\n i e -> RefSet n e i)
        <$> argument nameReader (metavar "NAME")
        <*> argument idReader (metavar "ID")
        <*> ( (MustBe <$> option idReader (long "expect" <> metavar "ID" <> help "Fail if the ref does not point to ID now."))
                <|> flag' MustBeAbsent (long "new" <> help "Fail if the ref exists.")
                <|> pure Unchecked
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
    gcP = GC <$> switch (long "dry-run" <> help "Only print what a run would collect. Write nothing.")

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
  { outBytes :: ByteString,
    outOk :: Bool
  }
  deriving (Eq, Show)

ok :: [Text] -> Output
ok ls = Output (encodeUtf8 (T.unlines ls)) True

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
newMemory :: MemoryArgs -> ExceptT AkyuuError IO NewMemory
newMemory a = do
  b <- ExceptT (readBody (argBody a))
  pure NewMemory {newKind = argKind a, newAgent = argAgent a, newEdges = argEdges a, newBody = b}

-- | Run one command against an open store.
runCommand :: Env -> Command -> IO (Either AkyuuError Output)
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
    pure (Output (renderMemory m) True)
  Supersede n old a -> do
    m <- newMemory a
    i <- ExceptT (supersedeMemory env n old m)
    pure (ok [Id.render i])
  RefGet n h -> ok . refLines h <$> ExceptT (readRef env n)
  RefSet n e i -> ok . refLines False <$> ExceptT (setRefTo env n e i)
  RefList -> ok . map nameText <$> ExceptT (listRefNames env)
  Search o q -> ok . searchLines <$> ExceptT (searchMemories env o q)
  Neighbours i -> ok . neighbourLines <$> ExceptT (neighboursOf env i)
  GC True -> ok . planLines <$> ExceptT (dryRunGC env)
  GC False -> ok . runLines <$> ExceptT (runGC env)
  Reindex -> ok . syncLines <$> ExceptT (reindexCache env)
  Verify -> do
    r <- ExceptT (verifyStore env)
    pure (Output (encodeUtf8 (T.unlines (verifyLines r))) (verifyOk r))

-- | The program: parse the arguments, find the store, run the command.
main :: IO ()
main = do
  args <- getArgs
  prog <- getProgName
  case parseCli args of
    Success cli -> do
      envRoot <- lookupEnv "AKYUU_ROOT"
      case resolveRoot (cliRoot cli) envRoot of
        Left e -> failWith 2 e
        Right root -> do
          r <- withEnv root (\env -> runCommand env (cliCommand cli))
          case r of
            Left e -> failWith 1 e
            Right o -> do
              BS.putStr (outBytes o)
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
