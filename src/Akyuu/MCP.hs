-- | A Model Context Protocol (MCP) server over stdio.
--
-- The transport is JSON-RPC 2.0: one JSON message on each line of stdin, and
-- one on each line of stdout. Stdout carries only protocol messages. Logs go
-- to stderr.
--
-- The server has tools only: no resources, no prompts, no sampling. The tools
-- are the same operations as the CLI ("Akyuu.Ops"), and their results are the
-- same text ("Akyuu.Render"). An operation that fails gives a tool result
-- with @isError: true@ and the text of 'Akyuu.Error.describe'. A protocol
-- error is only for a message that is wrong in itself: bad JSON, an unknown
-- method, or an unknown tool.
--
-- The protocol part is pure. 'handleMessage' takes the function that runs a
-- tool as an argument, so a test can pass a pure function and check the
-- answers without a store. 'runTool' is the real function, and 'serve' is
-- the loop on stdin and stdout.
--
-- The server keeps no state between messages. It does not check that
-- @initialize@ came first: the client is responsible for the order.
module Akyuu.MCP
  ( -- * Tools
    ToolCall (..),
    ToolResult (..),
    CallError (..),
    toolList,
    parseToolCall,
    runTool,

    -- * Protocol
    McpConfig (..),
    defaultMcpConfig,
    supportedVersions,
    handleMessage,
    handleLine,
    serve,
  )
where

import Akyuu.Check (CheckOptions (hubDegree, nearThreshold), FindingKind, Severity, defaultCheckOptions, filterFindings, kindName, severityName)
import Akyuu.Error (AkyuuError (BadId, BadName), describe)
import Akyuu.Graph (Edge (Edge), EdgeType (About, DerivedFrom, Refines, Supersedes))
import Akyuu.Id (Id)
import Akyuu.Id qualified as Id
import Akyuu.Ops (Env, NewMemory (NewMemory, newAgent, newBody, newEdges, newKind), addMemory, checkField, checkStore, compareMemories, getMemory, listRefValues, neighboursOf, readRef, searchMemories, setRefTo, supersedeMemory)
import Akyuu.Query (SearchOptions (SearchOptions, searchFollow, searchHops, searchLimit), defaultSearchOptions)
import Akyuu.Refs (Expected (MustBe, MustBeAbsent), Name, Ref (current), mkName)
import Akyuu.Render (compareLines, edgeName, findingLines, memoryText, neighbourLines, refLines, refListLines, searchLines)
import Control.Exception (SomeAsyncException, SomeException, displayException, fromException, tryJust)
import Control.Monad (unless)
import Data.Aeson (Value (Array, Bool, Null, Number, Object, String), object, (.=))
import Data.Aeson qualified as A
import Data.Aeson.Key qualified as K
import Data.Aeson.KeyMap (KeyMap)
import Data.Aeson.KeyMap qualified as KM
import Data.Bifunctor (first)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as BL
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (encodeUtf8)
import System.IO (BufferMode (LineBuffering), hFlush, hIsEOF, hPutStrLn, hSetBinaryMode, hSetBuffering, stderr, stdin, stdout)

-- Tools ----------------------------------------------------------------

-- | A tool call, with its arguments checked.
data ToolCall
  = CallAdd NewMemory
  | -- | By 'Id' ('Right') or by the current value of a ref ('Left').
    CallGet (Either Name Id)
  | CallSupersede Name (Maybe Id) NewMemory
  | CallSearch SearchOptions Text
  | CallNeighbours Id
  | -- | Compare two memories by their ids.
    CallCompare Id Id
  | -- | The ref, and 'True' to show the older values too.
    CallRefGet Name Bool
  | CallRefSet Name Expected Id
  | CallRefList
  | -- | The options, the kinds to show (none means all), and the lowest severity.
    CallCheck CheckOptions [FindingKind] (Maybe Severity)
  deriving (Eq, Show)

-- | The result of a tool: text, and whether it is an error.
data ToolResult = ToolResult
  { resultText :: Text,
    resultIsError :: Bool
  }
  deriving (Eq, Show)

-- | Why a tool call could not start.
data CallError
  = -- | No tool has this name. This is a protocol error.
    UnknownTool Text
  | -- | The arguments are wrong. This is a tool error, so that the model can
    -- see the text and try again.
    BadArguments Text
  deriving (Eq, Show)

-- | The JSON schema of a string that is an 'Id'.
idSchema :: Text -> Value
idSchema d = object ["type" .= ("string" :: Text), "pattern" .= ("^sha256-[0-9a-f]{64}$" :: Text), "description" .= d]

-- | The JSON schema of a list of 'Id' values.
idsSchema :: Text -> Value
idsSchema d = object ["type" .= ("array" :: Text), "items" .= idSchema "A memory id.", "description" .= d]

stringSchema :: Text -> Value
stringSchema d = object ["type" .= ("string" :: Text), "description" .= d]

refSchema :: Value
refSchema = stringSchema "A ref name, such as claude/notes: parts of a-z, 0-9, '-', '_' and '.', joined with '/'."

-- | The schema of an object with these properties and these required names.
objectSchema :: [(Text, Value)] -> [Text] -> Value
objectSchema props req =
  object
    [ "type" .= ("object" :: Text),
      "properties" .= object [K.fromText k .= v | (k, v) <- props],
      "required" .= req,
      "additionalProperties" .= False
    ]

-- | The properties of a new memory.
memoryProps :: [(Text, Value)]
memoryProps =
  [ ("kind", stringSchema "The kind of memory, for example fact, preference or decision. One line, no space at either end."),
    ("agent", stringSchema "The name of the agent that writes the memory. One line, no space at either end."),
    ("body", stringSchema "The text of the memory. It can have many lines."),
    ("about", idsSchema "Memories that this memory is about."),
    ("derived_from", idsSchema "Memories that this memory comes from."),
    ("refines", idsSchema "Memories that this memory adds detail to.")
  ]

-- | The tools, for @tools/list@: name, description and input schema.
toolList :: [Value]
toolList =
  [ tool
      "add"
      "Store a new memory and return its id. A memory never changes after this. To replace the memory of a ref, use supersede. Edges point from the new memory to older ones. This tool moves no ref."
      (objectSchema (memoryProps <> [("supersedes", idsSchema "Memories that this memory replaces. This adds edges only. It moves no ref.")]) ["kind", "agent", "body"]),
    tool
      "get"
      "Read one memory, by id or by the current value of a ref. Give exactly one of id and ref. The result is the stored file: the headers (kind, created, agent, edges), a blank line, then the body."
      (objectSchema [("id", idSchema "The id of the memory."), ("ref", refSchema)] []),
    tool
      "supersede"
      "Replace the memory of a ref with a new memory, and return the new id. The new memory gets a supersedes edge to the old one. Give expected (the id you read) so that the call fails if another agent moved the ref since then."
      ( objectSchema
          (("ref", refSchema) : ("expected", idSchema "The id that the ref must point to now.") : memoryProps)
          ["ref", "kind", "agent", "body"]
      ),
    tool
      "search"
      "Search the bodies of the memories for words. Each hit is a line with its id and a snippet, best first. Square brackets mark the matching words. A square bracket with a backslash before it is part of the text. 'superseded by ID' under a hit means that a newer memory replaces it: read the newer one. After 'context:' come the memories near the hits in the graph."
      ( objectSchema
          [ ("query", stringSchema "The words to find. A memory matches if it has all of them."),
            ("limit", object ["type" .= ("integer" :: Text), "minimum" .= (1 :: Int), "default" .= searchLimit defaultSearchOptions, "description" .= ("The most hits to return." :: Text)]),
            ("hops", object ["type" .= ("integer" :: Text), "minimum" .= (0 :: Int), "default" .= searchHops defaultSearchOptions, "description" .= ("How many edges away from a hit the context reaches. 0 gives no context." :: Text)]),
            ( "follow",
              object
                [ "type" .= ("array" :: Text),
                  "items" .= object ["type" .= ("string" :: Text), "enum" .= map edgeName [minBound .. maxBound :: EdgeType]],
                  "description" .= ("The kinds of edge that the context follows. The default is all kinds." :: Text)
                ]
            )
          ]
          ["query"]
      ),
    tool
      "compare"
      "Compare two memories. It shows the refs that hold each one, how much text they share, the sentences that only A has and the sentences that only B has, and whether either can be dropped in favour of the other. Use it before you decide that two memories are duplicates: a memory that has a sentence the other lacks must not be dropped, because that fact is lost. Merge it or keep both."
      (objectSchema [("a", idSchema "The first memory."), ("b", idSchema "The second memory.")] ["a", "b"]),
    tool
      "neighbours"
      "List the edges of a memory, in both directions. 'out KIND ID' means that this memory points at ID. 'in KIND ID' means that ID points at this memory."
      (objectSchema [("id", idSchema "The id of the memory.")] ["id"]),
    tool
      "ref_get"
      "Read a ref: the id of its current memory. With history, also the older ids, newest first."
      (objectSchema [("ref", refSchema), ("history", object ["type" .= ("boolean" :: Text), "default" .= False])] ["ref"]),
    tool
      "ref_set"
      "Point a ref at a memory that is in the store, and return the new current id. Give expected (the id that the ref points to now), or create: true for a new ref. The call fails if the ref is not as you expect."
      ( objectSchema
          [ ("ref", refSchema),
            ("id", idSchema "The memory that the ref will point to."),
            ("expected", idSchema "The id that the ref must point to now."),
            ("create", object ["type" .= ("boolean" :: Text), "description" .= ("True to make a new ref. The call fails if the ref exists." :: Text)])
          ]
          ["ref", "id"]
      ),
    tool
      "ref_list"
      "List all refs, one on each line: the name, two spaces and the id that the ref points to."
      (objectSchema [] []),
    tool
      "check"
      "Find memories that need attention, without changing anything. It lists stale links (a memory points at an old version, and the finding names the current one), forks, duplicates, near duplicates, memories that nothing keeps, and hubs. Each finding has a severity (problem, suggestion or info), a reason, and the ids. Read the ids with get, then decide: use supersede for a copy or an old text, and ref_set or add with an edge to fix a link."
      ( objectSchema
          [ ("kinds", object ["type" .= ("array" :: Text), "items" .= object ["type" .= ("string" :: Text), "enum" .= map kindName [minBound .. maxBound :: FindingKind]], "description" .= ("Show only these kinds. The default is all kinds." :: Text)]),
            ("severity", object ["type" .= ("string" :: Text), "enum" .= map severityName [minBound .. maxBound :: Severity], "description" .= ("Show this level or a more serious one. The default is all levels." :: Text)]),
            ("near_threshold", object ["type" .= ("number" :: Text), "minimum" .= (0 :: Int), "maximum" .= (1 :: Int), "default" .= nearThreshold defaultCheckOptions, "description" .= ("The share of text that two memories must have in common to be near duplicates." :: Text)]),
            ("hub_degree", object ["type" .= ("integer" :: Text), "minimum" .= (0 :: Int), "default" .= hubDegree defaultCheckOptions, "description" .= ("A memory with more links than this is a hub." :: Text)])
          ]
          []
      )
  ]
  where
    tool :: Text -> Text -> Value -> Value
    tool n d s = object ["name" .= n, "description" .= d, "inputSchema" .= s]

-- Arguments ------------------------------------------------------------

type Args = KeyMap Value

-- | A missing or wrong argument.
argError :: Text -> Text -> Either CallError a
argError k why = Left (BadArguments ("The argument '" <> k <> "' " <> why))

optional' :: Args -> Text -> (Value -> Maybe a) -> Text -> Either CallError (Maybe a)
optional' args k f what = case KM.lookup (K.fromText k) args of
  Nothing -> Right Nothing
  Just Null -> Right Nothing
  Just v -> maybe (argError k ("must be " <> what <> ".")) (Right . Just) (f v)

required :: Args -> Text -> (Value -> Maybe a) -> Text -> Either CallError a
required args k f what = optional' args k f what >>= maybe (argError k "is missing.") Right

asText :: Value -> Maybe Text
asText (String t) = Just t
asText _ = Nothing

asInt :: Value -> Maybe Int
asInt v@(Number _) = case A.fromJSON v of
  A.Success n -> Just n
  A.Error _ -> Nothing
asInt _ = Nothing

asDouble :: Value -> Maybe Double
asDouble v@(Number _) = case A.fromJSON v of
  A.Success x -> Just x
  A.Error _ -> Nothing
asDouble _ = Nothing

asBool :: Value -> Maybe Bool
asBool (Bool b) = Just b
asBool _ = Nothing

asList :: (Value -> Maybe a) -> Value -> Maybe [a]
asList f (Array xs) = traverse f (foldr (:) [] xs)
asList _ _ = Nothing

-- | Turn an 'AkyuuError' from a check into 'BadArguments', with its text.
check :: Either AkyuuError a -> Either CallError a
check = first (BadArguments . describe)

parseId :: Text -> Either CallError Id
parseId t = check (first (BadId t) (Id.parse t))

parseName :: Text -> Either CallError Name
parseName t = check (first (BadName t) (mkName t))

idArg :: Args -> Text -> Either CallError Id
idArg args k = required args k asText "a string" >>= parseId

optIdArg :: Args -> Text -> Either CallError (Maybe Id)
optIdArg args k = optional' args k asText "a string" >>= traverse parseId

refArg :: Args -> Either CallError Name
refArg args = required args "ref" asText "a string" >>= parseName

-- | The edges of a new memory, from the lists of ids.
edgesArg :: Args -> [(Text, EdgeType)] -> Either CallError (Set.Set Edge)
edgesArg args kinds = Set.fromList . concat <$> traverse one kinds
  where
    one (k, kind) = do
      ts <- maybe [] id <$> optional' args k (asList asText) "a list of id strings"
      map (Edge kind) <$> traverse parseId ts

memoryArg :: Args -> [(Text, EdgeType)] -> Either CallError NewMemory
memoryArg args kinds = do
  k <- required args "kind" asText "a string" >>= check . checkField "kind"
  a <- required args "agent" asText "a string" >>= check . checkField "agent"
  b <- required args "body" asText "a string"
  es <- edgesArg args kinds
  pure NewMemory {newKind = k, newAgent = a, newEdges = es, newBody = b}

plainEdges :: [(Text, EdgeType)]
plainEdges = [("about", About), ("derived_from", DerivedFrom), ("refines", Refines)]

-- | Check the arguments of a tool call. This function is pure.
--
-- A name that is not a tool gives 'UnknownTool'. Every other problem gives
-- 'BadArguments' with a text for the model. An argument that the tool does
-- not know is ignored.
parseToolCall :: Text -> Args -> Either CallError ToolCall
parseToolCall n args = case n of
  "add" -> CallAdd <$> memoryArg args (plainEdges <> [("supersedes", Supersedes)])
  "get" -> do
    i <- optIdArg args "id"
    r <- optional' args "ref" asText "a string" >>= traverse parseName
    case (i, r) of
      (Just x, Nothing) -> pure (CallGet (Right x))
      (Nothing, Just x) -> pure (CallGet (Left x))
      _ -> Left (BadArguments "Give exactly one of the arguments 'id' and 'ref'.")
  "supersede" -> CallSupersede <$> refArg args <*> optIdArg args "expected" <*> memoryArg args plainEdges
  "search" -> do
    q <- required args "query" asText "a string"
    l <- optional' args "limit" asInt "a whole number"
    h <- optional' args "hops" asInt "a whole number"
    f <- optional' args "follow" (asList asText) "a list of strings"
    limit <- atLeast "limit" 1 (maybe (searchLimit defaultSearchOptions) id l)
    hops <- atLeast "hops" 0 (maybe (searchHops defaultSearchOptions) id h)
    follow <- maybe (pure (searchFollow defaultSearchOptions)) (fmap Set.fromList . traverse kindOf) f
    pure (CallSearch (SearchOptions limit hops follow) q)
  "neighbours" -> CallNeighbours <$> idArg args "id"
  "compare" -> CallCompare <$> idArg args "a" <*> idArg args "b"
  "ref_get" -> CallRefGet <$> refArg args <*> (maybe False id <$> optional' args "history" asBool "true or false")
  "ref_set" -> do
    r <- refArg args
    i <- idArg args "id"
    e <- optIdArg args "expected"
    c <- maybe False id <$> optional' args "create" asBool "true or false"
    ex <- case (e, c) of
      (Just x, False) -> pure (MustBe x)
      (Nothing, True) -> pure MustBeAbsent
      (Just _, True) -> Left (BadArguments "Give 'expected' or 'create', not both.")
      (Nothing, False) -> Left (BadArguments "Give 'expected' (the id that the ref points to now), or 'create': true for a new ref.")
    pure (CallRefSet r ex i)
  "ref_list" -> pure CallRefList
  "check" -> do
    ks <- maybe [] id <$> optional' args "kinds" (asList asText) "a list of strings"
    s <- optional' args "severity" asText "a string"
    t <- optional' args "near_threshold" asDouble "a number"
    h <- optional' args "hub_degree" asInt "a whole number"
    kinds <- traverse kindName' ks
    sev <- traverse severityOf s
    thr <- maybe (pure (nearThreshold defaultCheckOptions)) (\x -> if x >= 0 && x <= 1 then Right x else argError "near_threshold" "must be from 0 to 1.") t
    hub <- atLeast "hub_degree" 0 (maybe (hubDegree defaultCheckOptions) id h)
    pure (CallCheck defaultCheckOptions {nearThreshold = thr, hubDegree = hub} kinds sev)
  _ -> Left (UnknownTool n)
  where
    atLeast k lo v
      | v >= lo = Right v
      | otherwise = argError k ("must be at least " <> T.pack (show lo) <> ".")
    kindName' t =
      maybe
        (argError "kinds" ("has '" <> t <> "', which is not a kind of finding."))
        Right
        (lookup t [(kindName k, k) | k <- [minBound .. maxBound]])
    severityOf t =
      maybe
        (argError "severity" ("is '" <> t <> "'. Use problem, suggestion or info."))
        Right
        (lookup t [(severityName s, s) | s <- [minBound .. maxBound]])
    kindOf t =
      maybe
        (argError "follow" ("has '" <> t <> "', which is not a kind of edge."))
        Right
        (lookup t [(edgeName k, k) | k <- [minBound .. maxBound]])

-- Running tools --------------------------------------------------------

-- | Run a tool call against an open store. An error of the operation becomes
-- a result with 'resultIsError' and the text of 'describe'.
runTool :: Env -> ToolCall -> IO ToolResult
runTool env c = either failed id <$> go
  where
    failed e = ToolResult (describe e) True
    okText = ToolResult
    lines' empty ls = okText (if null ls then empty else T.intercalate "\n" ls) False
    go = case c of
      CallAdd n -> fmap (\i -> okText (Id.render i) False) <$> addMemory env n
      CallGet t -> do
        i <- either (fmap (fmap current) . readRef env) (pure . Right) t
        case i of
          Left e -> pure (Left e)
          Right x -> fmap (\m -> okText (memoryText m) False) <$> getMemory env x
      CallSupersede n old m -> fmap (\i -> okText (Id.render i) False) <$> supersedeMemory env n old m
      CallSearch o q -> fmap (lines' "No matches." . searchLines) <$> searchMemories env o q
      CallNeighbours i -> fmap (lines' "This memory has no edges." . neighbourLines) <$> neighboursOf env i
      CallCompare a b -> fmap (\r -> okText (T.intercalate "\n" (compareLines r)) False) <$> compareMemories env a b
      CallRefGet n h -> fmap (lines' "" . refLines h) <$> readRef env n
      CallRefSet n e i -> fmap (lines' "" . refLines False) <$> setRefTo env n e i
      CallRefList -> fmap (lines' "There are no refs." . refListLines) <$> listRefValues env
      CallCheck o ks s -> do
        r <- checkStore env o
        refs <- listRefValues env
        pure ((\fs rs -> okText (T.intercalate "\n" (findingLines rs (filterFindings ks s fs))) False) <$> r <*> refs)

-- Protocol -------------------------------------------------------------

-- | The protocol versions that this server can speak, newest first. The
-- server uses only tools with text content, which all of them have.
supportedVersions :: [Text]
supportedVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

-- | A JSON-RPC response with a result.
response :: Value -> Value -> Value
response i r = object ["jsonrpc" .= ("2.0" :: Text), "id" .= i, "result" .= r]

-- | A JSON-RPC error response.
errorResponse :: Value -> Int -> Text -> Value
errorResponse i code msg =
  object ["jsonrpc" .= ("2.0" :: Text), "id" .= i, "error" .= object ["code" .= code, "message" .= msg]]

parseError, invalidRequest, methodNotFound, invalidParams :: Int
parseError = -32700
invalidRequest = -32600
methodNotFound = -32601
invalidParams = -32602

-- | What the server tells a client about this store.
newtype McpConfig = McpConfig
  { -- | The name of the ref that holds the policy for this store: how the
    -- store is used for memory. The instructions of the server name it, so a
    -- client reads it first. The server does not check that the ref exists.
    mcpPolicyRef :: Text
  }
  deriving (Eq, Show)

-- | The policy ref is @policy/memory@. This is a plain name, not the name of
-- one agent. A store that uses another name sets it with @--policy-ref@ or
-- @AKYUU_POLICY_REF@.
defaultMcpConfig :: McpConfig
defaultMcpConfig = McpConfig "policy/memory"

-- | The result of @initialize@.
initializeResult :: McpConfig -> Maybe Text -> Value
initializeResult cfg asked =
  object
    [ "protocolVersion" .= version,
      "capabilities" .= object ["tools" .= object ["listChanged" .= False]],
      "serverInfo" .= object ["name" .= ("akyuu" :: Text), "version" .= ("0.1.0.0" :: Text)],
      "instructions"
        .= ( "akyuu is a content-addressed memory store. A memory never changes. \
             \A ref (such as me/notes) names the current memory of a topic. \
             \To change a memory, read its ref, then call supersede with the id that you read as expected. \
             \Search shows when a hit is superseded: read the newer memory. \
             \If the store has the ref "
               <> mcpPolicyRef cfg
               <> ", read it first: \
                  \it says how this store is used for memory, and which refs to read at the start of work."
           )
    ]
  where
    version = case asked of
      Just v | v `elem` supportedVersions -> v
      _ -> head' supportedVersions
    head' (v : _) = v
    head' [] = ""

-- | The result of a tool, as JSON.
toolResultValue :: ToolResult -> Value
toolResultValue r =
  object
    [ "content" .= [object ["type" .= ("text" :: Text), "text" .= resultText r]],
      "isError" .= resultIsError r
    ]

-- | Answer one JSON-RPC message.
--
-- The first argument runs a tool. Returns 'Nothing' for a notification, and
-- for a message with no method (a response from the client: this server
-- sends no requests, so it ignores them).
--
-- * A message that is not a JSON-RPC 2.0 object gives @-32600@.
-- * An unknown method gives @-32601@.
-- * Bad @params@ of @tools/call@, or an unknown tool, give @-32602@.
-- * Bad arguments of a known tool give a tool result with @isError@, so the
--   model sees the text and can try again.
handleMessage :: (Monad m) => McpConfig -> (ToolCall -> m ToolResult) -> Value -> m (Maybe Value)
handleMessage cfg run msg = case msg of
  Object o
    | KM.lookup "jsonrpc" o /= Just (String "2.0") -> pure (Just (errorResponse (idOf o) invalidRequest "Invalid Request: jsonrpc must be \"2.0\"."))
    | otherwise -> case (KM.lookup "method" o, KM.lookup "id" o) of
        (Nothing, _) -> pure Nothing
        (Just (String _), Nothing) -> pure Nothing -- a notification: no answer
        (Just (String m), Just i)
          | validId i -> Just <$> request i m (params o)
          | otherwise -> pure (Just (errorResponse Null invalidRequest "Invalid Request: id must be a string or a number."))
        (Just _, _) -> pure (Just (errorResponse (idOf o) invalidRequest "Invalid Request: method must be a string."))
  _ -> pure (Just (errorResponse Null invalidRequest "Invalid Request: a message must be a JSON object."))
  where
    idOf o = case KM.lookup "id" o of
      Just i | validId i -> i
      _ -> Null
    validId (String _) = True
    validId (Number _) = True
    validId _ = False
    params o = case KM.lookup "params" o of
      Just (Object p) -> Just p
      _ -> Nothing
    request i m p = case m of
      "initialize" -> pure (response i (initializeResult cfg (p >>= KM.lookup "protocolVersion" >>= asText)))
      "ping" -> pure (response i (object []))
      "tools/list" -> pure (response i (object ["tools" .= toolList]))
      "tools/call" -> call i p
      _ -> pure (errorResponse i methodNotFound ("Method not found: " <> m))
    call i p = case p of
      Nothing -> pure (errorResponse i invalidParams "Invalid params: tools/call needs params with a name.")
      Just ps -> case (KM.lookup "name" ps, KM.lookup "arguments" ps) of
        (Just (String n), args) -> case argsOf args of
          Nothing -> pure (errorResponse i invalidParams "Invalid params: arguments must be an object.")
          Just a -> case parseToolCall n a of
            Left (UnknownTool t) -> pure (errorResponse i invalidParams ("Unknown tool: " <> t))
            Left (BadArguments t) -> pure (response i (toolResultValue (ToolResult t True)))
            Right tc -> response i . toolResultValue <$> run tc
        _ -> pure (errorResponse i invalidParams "Invalid params: name must be a string.")
    argsOf Nothing = Just KM.empty
    argsOf (Just Null) = Just KM.empty
    argsOf (Just (Object a)) = Just a
    argsOf _ = Nothing

-- | Answer one line of input. A line that is not JSON gives @-32700@.
-- A blank line gives no answer.
handleLine :: (Monad m) => McpConfig -> (ToolCall -> m ToolResult) -> BS.ByteString -> m (Maybe Value)
handleLine cfg run line
  | BC.all (`elem` (" \t\r" :: String)) line = pure Nothing
  | otherwise = case A.eitherDecodeStrict line of
      Left _ -> pure (Just (errorResponse Null parseError "Parse error: the line is not JSON."))
      Right v -> handleMessage cfg run v

-- | Serve the protocol on stdin and stdout until stdin ends.
--
-- Each answer is one line of JSON on stdout, and stdout is flushed after
-- each one. A tool that throws an exception (a bug) gives an error result,
-- and the server goes on. Logs go to stderr.
serve :: McpConfig -> Env -> IO ()
serve cfg env = do
  hSetBinaryMode stdin True
  hSetBinaryMode stdout True
  hSetBuffering stdout LineBuffering
  logLine "akyuu mcp: ready on stdio"
  loop
  logLine "akyuu mcp: stdin closed, stopping"
  where
    loop = do
      eof <- hIsEOF stdin
      unless eof $ do
        line <- BC.hGetLine stdin
        answer <- handleLine cfg safeRun line
        mapM_ (\v -> BL.hPut stdout (A.encode v <> "\n") >> hFlush stdout) answer
        loop
    safeRun tc = do
      r <- tryJust notAsync (runTool env tc)
      case r of
        Right x -> pure x
        Left e -> do
          logLine ("akyuu mcp: a tool threw: " <> T.pack (displayException e))
          pure (ToolResult ("The tool failed with an internal error: " <> T.pack (displayException e)) True)
    notAsync :: SomeException -> Maybe SomeException
    notAsync e = case fromException e :: Maybe SomeAsyncException of
      Just _ -> Nothing
      Nothing -> Just e
    logLine t = BS.hPut stderr (encodeUtf8 t) >> hPutStrLn stderr "" >> hFlush stderr
