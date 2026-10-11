{-# LANGUAGE OverloadedStrings #-}

module MCPTests (mcpTests) where

import Akyuu.Error (AkyuuError (..), describe)
import Akyuu.Graph (Edge (..), EdgeType (..))
import Akyuu.Id (IdParseError (..), render)
import Akyuu.MCP
import Akyuu.Ops (NewMemory (..))
import Akyuu.Query (SearchOptions (..), defaultSearchOptions)
import Akyuu.Refs (Expected (..), mkName)
import Akyuu.Store (StoreError (..))
import Data.Aeson (Value (..), object, (.=))
import Data.Aeson qualified as A
import Data.Aeson.Key qualified as K
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString.Lazy qualified as BL
import Data.Functor.Identity (runIdentity)
import Data.Maybe (isJust, listToMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import OpsTests (withOpsEnv)
import Support (nid, right)
import Test.Tasty
import Test.Tasty.HUnit

mcpTests :: TestTree
mcpTests =
  testGroup
    "Akyuu.MCP"
    [ protocolCases
    , toolCallCases
    , runToolCases
    ]

-- Helpers --------------------------------------------------------------

-- A tool runner that runs nothing. It answers with the Show form of the
-- call, so a test can see which call the handler made.
fake :: ToolCall -> ToolResult
fake tc = ToolResult (T.pack (show tc)) False

-- Answer one message with the fake runner.
answer :: Value -> Maybe Value
answer = runIdentity . handleMessage (pure . fake)

-- A request with an id, a method and params.
req :: Value -> Text -> Value -> Value
req i m p = object ["jsonrpc" .= ("2.0" :: Text), "id" .= i, "method" .= m, "params" .= p]

-- A tools/call request with id 1.
callReq :: Text -> Value -> Value
callReq n as = req (Number 1) "tools/call" (object ["name" .= n, "arguments" .= as])

-- Follow a path of keys into a value.
at :: [Text] -> Value -> Maybe Value
at [] v = Just v
at (k : ks) (Object o) = KM.lookup (K.fromText k) o >>= at ks
at _ _ = Nothing

-- The error code of a response.
errCode :: Maybe Value -> Maybe Value
errCode r = r >>= at ["error", "code"]

-- The text and isError of a tool result.
toolOut :: Maybe Value -> Maybe (Value, Value)
toolOut r = do
  v <- r
  Array cs <- at ["result", "content"] v
  t <- case foldr (:) [] cs of
    [c] -> at ["text"] c
    _ -> Nothing
  e <- at ["result", "isError"] v
  pure (t, e)

-- Protocol -------------------------------------------------------------

protocolCases :: TestTree
protocolCases =
  testGroup
    "handleMessage"
    [ testCase "initialize gives back a supported version" $ do
        let r = answer (req (Number 1) "initialize" (object ["protocolVersion" .= ("2025-06-18" :: Text), "capabilities" .= object [], "clientInfo" .= object ["name" .= ("t" :: Text), "version" .= ("1" :: Text)]]))
        (r >>= at ["result", "protocolVersion"]) @?= Just "2025-06-18"
        (r >>= at ["result", "serverInfo", "name"]) @?= Just "akyuu"
        isJust (r >>= at ["result", "capabilities", "tools"]) @?= True
        (r >>= at ["id"]) @?= Just (Number 1)
    , testCase "initialize tells a client to read the memory policy first" $ do
        let r = answer (req (Number 1) "initialize" (object ["protocolVersion" .= ("2025-06-18" :: Text)]))
        case r >>= at ["result", "instructions"] of
          Just (String t) -> do
            assertBool "names the policy ref" ("claude/memory-policy" `T.isInfixOf` t)
            assertBool "still explains supersede" ("supersede" `T.isInfixOf` t)
          other -> assertFailure ("expected instructions text, got " <> show other)
    , testCase "initialize with an unknown version offers the newest" $
        (answer (req (Number 1) "initialize" (object ["protocolVersion" .= ("1999-01-01" :: Text)])) >>= at ["result", "protocolVersion"])
          @?= fmap String (listToMaybe supportedVersions)
    , testCase "a notification gets no answer" $
        answer (object ["jsonrpc" .= ("2.0" :: Text), "method" .= ("notifications/initialized" :: Text)]) @?= Nothing
    , testCase "an unknown notification gets no answer" $
        answer (object ["jsonrpc" .= ("2.0" :: Text), "method" .= ("notifications/whatever" :: Text)]) @?= Nothing
    , testCase "a response from the client gets no answer" $
        answer (object ["jsonrpc" .= ("2.0" :: Text), "id" .= (5 :: Int), "result" .= object []]) @?= Nothing
    , testCase "ping gives an empty result, with a string id" $ do
        let r = answer (req (String "abc") "ping" (object []))
        (r >>= at ["result"]) @?= Just (object [])
        (r >>= at ["id"]) @?= Just (String "abc")
    , testCase "tools/list lists every tool with a schema" $ do
        let r = answer (req (Number 2) "tools/list" (object []))
        case r >>= at ["result", "tools"] of
          Just (Array ts) -> do
            let names = [n | t <- foldr (:) [] ts, Just (String n) <- [at ["name"] t]]
            Set.fromList names @?= Set.fromList ["add", "get", "supersede", "search", "neighbours", "ref_get", "ref_set", "ref_list"]
            mapM_ (\t -> (at ["inputSchema", "type"] t, isJust (at ["description"] t)) @?= (Just "object", True)) ts
          other -> assertFailure ("no tools: " <> show other)
    , testCase "a tool call runs the tool" $ do
        let r = answer (callReq "neighbours" (object ["id" .= render (nid 1)]))
        toolOut r @?= Just (String (T.pack (show (CallNeighbours (nid 1)))), Bool False)
    , testCase "bad arguments give a tool error with the friendly text" $ do
        let r = answer (callReq "neighbours" (object ["id" .= ("sha256-zz" :: Text)]))
        toolOut r @?= Just (String (describe (BadId "sha256-zz" (BadHex "zz"))), Bool True)
    , testCase "a missing argument gives a tool error" $
        toolOut (answer (callReq "neighbours" (object [])))
          @?= Just (String "The argument 'id' is missing.", Bool True)
    , testCase "an unknown tool gives -32602" $
        errCode (answer (callReq "nope" (object []))) @?= Just (Number (-32602))
    , testCase "tools/call with no params gives -32602" $
        errCode (answer (object ["jsonrpc" .= ("2.0" :: Text), "id" .= (1 :: Int), "method" .= ("tools/call" :: Text)])) @?= Just (Number (-32602))
    , testCase "arguments that are not an object give -32602" $
        errCode (answer (req (Number 1) "tools/call" (object ["name" .= ("ref_list" :: Text), "arguments" .= ([] :: [Int])]))) @?= Just (Number (-32602))
    , testCase "an unknown method gives -32601" $
        errCode (answer (req (Number 1) "resources/list" (object []))) @?= Just (Number (-32601))
    , testCase "a message without jsonrpc 2.0 gives -32600" $
        errCode (answer (object ["id" .= (1 :: Int), "method" .= ("ping" :: Text)])) @?= Just (Number (-32600))
    , testCase "a null id gives -32600" $
        errCode (answer (req Null "ping" (object []))) @?= Just (Number (-32600))
    , testCase "a batch (an array) gives -32600" $
        errCode (answer (A.toJSON [req (Number 1) "ping" (object [])])) @?= Just (Number (-32600))
    , testCase "a line that is not JSON gives -32700 with a null id" $ do
        let r = runIdentity (handleLine (pure . fake) "{not json")
        errCode r @?= Just (Number (-32700))
        (r >>= at ["id"]) @?= Just Null
    , testCase "a blank line gives no answer" $
        runIdentity (handleLine (pure . fake) "  \r") @?= Nothing
    , testCase "every answer is one line of JSON" $ do
        let r = answer (callReq "add" (object ["kind" .= ("fact" :: Text), "agent" .= ("a" :: Text), "body" .= ("two\nlines" :: Text)]))
        fmap (BL.elem 10 . A.encode) r @?= Just False
    ]

-- Tool calls -----------------------------------------------------------

args :: [(Text, Value)] -> KM.KeyMap Value
args kvs = KM.fromList [(K.fromText k, v) | (k, v) <- kvs]

toolCallCases :: TestTree
toolCallCases =
  testGroup
    "parseToolCall"
    [ testCase "add with edges" $
        parseToolCall "add" (args [("kind", "fact"), ("agent", "claude"), ("body", "hi"), ("about", A.toJSON [render (nid 1)]), ("supersedes", A.toJSON [render (nid 2)])])
          @?= Right (CallAdd (NewMemory "fact" "claude" (Set.fromList [Edge About (nid 1), Edge Supersedes (nid 2)]) "hi"))
    , testCase "add checks the kind" $
        parseToolCall "add" (args [("kind", "a\nb"), ("agent", "claude"), ("body", "hi")])
          @?= Left (BadArguments (describe (BadField "kind" "a\nb")))
    , testCase "get needs exactly one of id and ref" $ do
        parseToolCall "get" (args []) @?= Left (BadArguments "Give exactly one of the arguments 'id' and 'ref'.")
        n <- right (mkName "claude/notes")
        parseToolCall "get" (args [("ref", "claude/notes")]) @?= Right (CallGet (Left n))
    , testCase "search fills in the defaults" $
        parseToolCall "search" (args [("query", "haskell")]) @?= Right (CallSearch defaultSearchOptions "haskell")
    , testCase "search reads limit, hops and follow" $
        parseToolCall "search" (args [("query", "x"), ("limit", Number 3), ("hops", Number 0), ("follow", A.toJSON ["about" :: Text])])
          @?= Right (CallSearch (SearchOptions 3 0 (Set.singleton About)) "x")
    , testCase "search refuses a limit of 0 and a fraction" $ do
        parseToolCall "search" (args [("query", "x"), ("limit", Number 0)]) @?= Left (BadArguments "The argument 'limit' must be at least 1.")
        parseToolCall "search" (args [("query", "x"), ("hops", Number 1.5)]) @?= Left (BadArguments "The argument 'hops' must be a whole number.")
    , testCase "ref_set needs expected or create" $ do
        n <- right (mkName "a")
        parseToolCall "ref_set" (args [("ref", "a"), ("id", String (render (nid 1)))])
          @?= Left (BadArguments "Give 'expected' (the id that the ref points to now), or 'create': true for a new ref.")
        parseToolCall "ref_set" (args [("ref", "a"), ("id", String (render (nid 1))), ("create", Bool True)])
          @?= Right (CallRefSet n MustBeAbsent (nid 1))
        parseToolCall "ref_set" (args [("ref", "a"), ("id", String (render (nid 1))), ("expected", String (render (nid 2)))])
          @?= Right (CallRefSet n (MustBe (nid 2)) (nid 1))
    , testCase "an unknown tool" $
        parseToolCall "rm" (args []) @?= Left (UnknownTool "rm")
    ]

-- runTool --------------------------------------------------------------

runToolCases :: TestTree
runToolCases =
  testGroup
    "runTool"
    [ testCase "add, ref_set, get by ref and search" $
        withOpsEnv $ \_ env -> do
          ToolResult i False <- runTool env (CallAdd (NewMemory "fact" "claude" Set.empty "Lilly prefers Haskell"))
          n <- right (mkName "claude/notes")
          ToolResult _ False <- runTool env =<< either (assertFailure . show) pure (parseToolCall "ref_set" (args [("ref", "claude/notes"), ("id", String i), ("create", Bool True)]))
          ToolResult g False <- runTool env (CallGet (Left n))
          T.isSuffixOf "\n\nLilly prefers Haskell" g @?= True
          ToolResult s False <- runTool env (CallSearch defaultSearchOptions "haskell")
          T.isPrefixOf i s @?= True
    , testCase "search text has the same brackets as the CLI" $
        withOpsEnv $ \_ env -> do
          ToolResult i False <- runTool env (CallAdd (NewMemory "fact" "claude" Set.empty "see [x] and Haskell"))
          ToolResult s False <- runTool env (CallSearch defaultSearchOptions "haskell")
          s @?= i <> "  see \\[x\\] and [Haskell]"
    , testCase "a failed operation is a tool error with the CLI text" $
        withOpsEnv $ \_ env -> do
          r <- runTool env (CallGet (Right (nid 7)))
          r @?= ToolResult (describe (StoreFailed (NotFound (nid 7)))) True
    , testCase "an empty search says so" $
        withOpsEnv $ \_ env -> do
          r <- runTool env (CallSearch defaultSearchOptions "nothing")
          r @?= ToolResult "No matches." False
    ]
