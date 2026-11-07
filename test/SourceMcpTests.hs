{-# LANGUAGE OverloadedStrings #-}

module SourceMcpTests (sourceMcpTests) where

import Akyuu.Graph (Edge (Edge), EdgeType (DerivedFrom))
import Akyuu.Id (Id)
import Akyuu.Id qualified as Id
import Akyuu.MCP (CallError (BadArguments, UnknownTool), McpConfig (mcpSource, mcpToolSet), ToolCall (CallSourceShow), ToolResult (ToolResult), ToolSet (Maintenance, Ordinary, Topic), defaultMcpConfig, handleMessage, parseToolCallFor, runTool, toolsForConfig)
import Akyuu.Ops (Env, NewMemory (NewMemory), addMemory)
import Akyuu.Source (Root (Root), mkPointer, renderPointer)
import Data.Aeson (Value (Array, Bool, Number, Object, String), object, (.=))
import Data.Aeson.Key qualified as K
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString qualified as B
import Data.Functor.Identity (runIdentity)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime)
import OpsTests (withOpsEnv)
import Support (nid, right)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

sourceMcpTests :: TestTree
sourceMcpTests =
  testGroup
    "source_show tool"
    [ testCase "no tool without the flag, in any tool set" $
        mapM_ (\s -> assertBool (show s) ("source_show" `notElem` names (cfg s Nothing))) [Ordinary, Maintenance, Topic],
      testCase "with the flag, every tool set offers it" $
        mapM_ (\s -> assertBool (show s) ("source_show" `elem` names (cfg s (Just [])))) [Ordinary, Maintenance, Topic],
      testCase "the flag does not change the other tools" $
        mapM_ (\s -> filter (/= "source_show") (names (cfg s (Just []))) @?= names (cfg s Nothing)) [Ordinary, Maintenance, Topic],
      testCase "the schema needs an id and allows a window, and refuses other arguments" $ do
        schema <- case [t | t@(Object o) <- toolsForConfig (cfg Ordinary (Just [])), KM.lookup "name" o == Just (String "source_show")] of
          [t] -> maybe (assertFailure "no inputSchema") pure (at ["inputSchema"] t)
          other -> assertFailure ("expected one tool, got " <> show (length other))
        at ["required"] schema @?= Just (Array (pure (String "id")))
        fmap (map K.toText . KM.keys) (at ["properties"] schema >>= asObject) @?= Just ["after", "before", "id"]
        at ["additionalProperties"] schema @?= Just (Bool False),
      testCase "without the flag a call is an unknown tool" $
        parseToolCallFor (cfg Ordinary Nothing) "source_show" (args [("id", String idText)]) @?= Left (UnknownTool "source_show"),
      testCase "with the flag a call parses, with the default window" $
        parseToolCallFor (cfg Ordinary (Just [])) "source_show" (args [("id", String idText)]) @?= Right (CallSourceShow (nid 1) 6 2),
      testCase "the window can be set" $
        parseToolCallFor (cfg Topic (Just [])) "source_show" (args [("id", String idText), ("before", Number 3), ("after", Number 0)]) @?= Right (CallSourceShow (nid 1) 3 0),
      testCase "a negative window is refused" $ do
        assertBad (parseToolCallFor (cfg Ordinary (Just [])) "source_show" (args [("id", String idText), ("before", Number (-1))]))
        assertBad (parseToolCallFor (cfg Ordinary (Just [])) "source_show" (args [("id", String idText), ("after", Number (-2))])),
      testCase "an argument that the schema does not have is refused" $
        assertBad (parseToolCallFor (cfg Ordinary (Just [])) "source_show" (args [("id", String idText), ("limit", Number 3)])),
      testCase "the id is needed" $
        assertBad (parseToolCallFor (cfg Ordinary (Just [])) "source_show" (args [])),
      testCase "tools/list shows the tool with the flag" $ do
        let r = runIdentity (handleMessage (cfg Ordinary (Just [])) (pure . const (ToolResult "" False)) (object ["jsonrpc" .= ("2.0" :: Text), "id" .= Number 1, "method" .= ("tools/list" :: Text)]))
            listed = [n | Just v <- [r], Just (Array ts) <- [at ["result", "tools"] v], Object t <- foldr (:) [] ts, Just (String n) <- [KM.lookup "name" t]]
        assertBool "listed" ("source_show" `elem` listed),
      testCase "run: the records around the time of a pointer, from a live file" $
        withSystemTempDirectory "mcp-src" $ \root -> do
          B.writeFile (root </> "s1.jsonl") transcript
          withOpsEnv $ \_ env -> do
            pid <- addPointer env "s1"
            ToolResult out bad <- runTool (cfg Ordinary (Just [Root "claude-code" root])) env (CallSourceShow pid 6 2)
            bad @?= False
            assertBool "question" ("why did you pick zstd" `T.isInfixOf` out)
            assertBool "answer" ("it compresses these files well" `T.isInfixOf` out),
      testCase "run: a note that derives from a pointer works too" $
        withSystemTempDirectory "mcp-src" $ \root -> do
          B.writeFile (root </> "s1.jsonl") transcript
          withOpsEnv $ \_ env -> do
            pid <- addPointer env "s1"
            note <- right =<< addMemory env (NewMemory "note" "claude" (Set.singleton (Edge DerivedFrom pid)) "we chose zstd" Set.empty)
            ToolResult out bad <- runTool (cfg Ordinary (Just [Root "claude-code" root])) env (CallSourceShow note 6 2)
            bad @?= False
            assertBool "answer" ("it compresses these files well" `T.isInfixOf` out),
      testCase "run: a session that is not here is an error result that says so" $
        withSystemTempDirectory "mcp-src" $ \root ->
          withOpsEnv $ \_ env -> do
            pid <- addPointer env "gone"
            ToolResult out bad <- runTool (cfg Ordinary (Just [Root "claude-code" root])) env (CallSourceShow pid 6 2)
            bad @?= True
            assertBool "says not available" ("not available" `T.isInfixOf` out),
      testCase "run: the flag with no root says that a root is needed" $
        withOpsEnv $ \_ env -> do
          pid <- addPointer env "s1"
          ToolResult out bad <- runTool (cfg Ordinary (Just [])) env (CallSourceShow pid 6 2)
          bad @?= True
          assertBool "mentions the config" ("[source]" `T.isInfixOf` out),
      testCase "run: a memory with no pointer is an error result" $
        withOpsEnv $ \_ env -> do
          plain <- right =<< addMemory env (NewMemory "fact" "claude" Set.empty "no source" Set.empty)
          ToolResult out bad <- runTool (cfg Ordinary (Just [])) env (CallSourceShow plain 6 2)
          bad @?= True
          assertBool "says what is missing" ("pointer" `T.isInfixOf` out)
    ]
  where
    idText = Id.render (nid 1)

cfg :: ToolSet -> Maybe [Root] -> McpConfig
cfg set roots = defaultMcpConfig {mcpToolSet = set, mcpSource = roots}

names :: McpConfig -> [Text]
names c = [n | t <- toolsForConfig c, Just (String n) <- [at ["name"] t]]

at :: [Text] -> Value -> Maybe Value
at [] v = Just v
at (k : ks) (Object o) = KM.lookup (K.fromText k) o >>= at ks
at _ _ = Nothing

asObject :: Value -> Maybe (KM.KeyMap Value)
asObject (Object o) = Just o
asObject _ = Nothing

args :: [(Text, Value)] -> KM.KeyMap Value
args kvs = KM.fromList [(K.fromText k, v) | (k, v) <- kvs]

assertBad :: Either CallError ToolCall -> IO ()
assertBad (Left (BadArguments _)) = pure ()
assertBad r = assertFailure ("expected bad arguments, got " <> show r)

t0 :: UTCTime
t0 = read "2026-11-01 19:00:58 UTC"

-- | Add a pointer to a session, and give its id.
addPointer :: Env -> Text -> IO Id
addPointer env session = case mkPointer "claude-code" session t0 Nothing Nothing Nothing of
  Left e -> assertFailure (T.unpack e)
  Right p -> right =<< addMemory env (NewMemory "source" "claude" Set.empty (renderPointer p) Set.empty)

-- | A small transcript: two records, a second apart.
transcript :: B.ByteString
transcript =
  B.intercalate
    "\n"
    [ "{\"type\":\"user\",\"timestamp\":\"2026-11-01T19:00:57Z\",\"uuid\":\"u1\",\"message\":{\"role\":\"user\",\"content\":\"why did you pick zstd\"}}",
      "{\"type\":\"assistant\",\"timestamp\":\"2026-11-01T19:00:58Z\",\"uuid\":\"u2\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"it compresses these files well\"}]}}",
      ""
    ]
