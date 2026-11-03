{-# LANGUAGE OverloadedStrings #-}

module ReplicaInterfaceTests (replicaInterfaceTests) where

import Akyuu.CLI (BodySource (BodyText), Cli (cliCommand), Command (Mcp, Replica), MemoryArgs (MemoryArgs), Output (outBytes, outOk), ReplicaCommand (ReplicaRead, ReplicaReplace), parseCli, runReplicaCommand)
import Akyuu.MCP (CallError (BadArguments, UnknownTool), McpConfig (mcpAgent, mcpToolSet), ReplicaCall (TopicCreate), ToolCall (CallAddRef, CallReplica), ToolResult (resultIsError), ToolSet (Ordinary, Replicated), defaultMcpConfig, handleMessage, parseToolCallFor, runReplicaTool, toolsFor)
import Akyuu.Ops qualified as Ops
import Akyuu.Sync.State (versionText)
import Akyuu.Sync.Topics (TopicView (viewVersion), createTopic)
import Data.Aeson (Value (Array, Bool, Object, String), eitherDecodeStrict', object, (.=))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.Text (Text)
import Data.Text qualified as T
import Options.Applicative (ParserResult (Success))
import Support (right)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))
import TopicsTests (forkTopic, newTopic, topicName, withLocal)

replicaInterfaceTests :: TestTree
replicaInterfaceTests =
  testGroup
    "replica interfaces"
    [ testCase "replicated tool discovery excludes legacy tools" $ do
        let names = [name | Object tool <- toolsFor Replicated, Just (String name) <- [KM.lookup "name" tool]]
        names @?= ["topic_read", "topic_create", "topic_replace", "topic_resolve", "topic_conflicts", "topic_context", "configured_context", "topic_search", "log_read", "log_append", "log_levels", "log_summarise", "log_resolution", "log_todo", "log_unfold"]
        parseToolCallFor cfg "add" KM.empty @?= Left (UnknownTool "add")
        parseToolCallFor (cfg {mcpToolSet = Ordinary}) "topic_read" (args ["ref" .= ("me/topic" :: Text)]) @?= Left (UnknownTool "topic_read"),
      testCase "unknown arguments and missing versions fail before dispatch" $ do
        assertBad (parseToolCallFor cfg "topic_read" (args ["ref" .= ("me/topic" :: Text), "expect" .= ("wrong" :: Text)]))
        assertBad (parseToolCallFor cfg "topic_replace" (args ["ref" .= ("me/topic" :: Text), "kind" .= ("fact" :: Text), "body" .= ("new" :: Text)]))
        assertBad (parseToolCallFor cfg "topic_replace" (args ["ref" .= ("me/topic" :: Text), "kind" .= ("fact" :: Text), "body" .= ("new" :: Text), "expected" .= ("1234" :: Text)])),
      testCase "configured author is the default for replicated writes" $
        parseToolCallFor cfg "topic_create" (args ["ref" .= ("me/topic" :: Text), "kind" .= ("fact" :: Text), "body" .= ("hello" :: Text)])
          @?= Right (CallReplica (TopicCreate topicName ((newTopic "hello") {Ops.newAgent = "configured"}))),
      testCase "replica read parser and replicated MCP selection" $ do
        case parseCli ["replica", "read", "me/topic", "--json"] of
          Success cli -> cliCommand cli @?= Replica (ReplicaRead topicName True)
          _ -> assertFailure "Replica read parse failed."
        case parseCli ["mcp", "--tool-set", "replicated"] of
          Success cli -> cliCommand cli @?= Mcp Nothing Nothing Replicated
          _ -> assertFailure "Replicated MCP parse failed.",
      testCase "CLI returns conflicts as all heads, with no winner field" $ withLocal $ \root local -> do
        _ <- forkTopic False root local
        output <- runReplicaCommand root (ReplicaRead topicName True) >>= right
        value <- right (eitherDecodeStrict' (outBytes output))
        at ["status"] value @?= Just (String "conflict")
        arrayLength (at ["heads"] value) @?= 2
        at ["current"] value @?= Nothing,
      testCase "CLI JSON stale error includes current heads and exits unsuccessfully" $ withLocal $ \root local -> do
        original <- createTopic local topicName (newTopic "first") >>= right
        let memoryArgs body = MemoryArgs "fact" "test-author" [] [] (BodyText body)
        _ <- runReplicaCommand root (ReplicaReplace topicName (viewVersion original) (memoryArgs "second") True) >>= right
        stale <- runReplicaCommand root (ReplicaReplace topicName (viewVersion original) (memoryArgs "third") True) >>= right
        outOk stale @?= False
        value <- right (eitherDecodeStrict' (outBytes stale))
        at ["error"] value @?= Just (String "stale-version")
        arrayLength (at ["topic", "heads"] value) @?= 1,
      testCase "MCP read has structured conflict data" $ withLocal $ \root local -> do
        _ <- forkTopic False root local
        response <- handleMessage cfg (runReplicaTool cfg local) (request "topic_read" ["ref" .= ("me/topic" :: Text)])
        value <- maybe (assertFailure "No response") pure response
        at ["result", "isError"] value @?= Just (Bool False)
        at ["result", "structuredContent", "status"] value @?= Just (String "conflict")
        arrayLength (at ["result", "structuredContent", "heads"] value) @?= 2,
      testCase "MCP rejects ordinary replacement of a current conflict" $ withLocal $ \root local -> do
        forked <- forkTopic False root local
        response <- handleMessage cfg (runReplicaTool cfg local) (request "topic_replace" ["ref" .= ("me/topic" :: Text), "expected" .= versionText (viewVersion forked), "kind" .= ("fact" :: Text), "body" .= ("overwrite" :: Text)])
        value <- maybe (assertFailure "No response") pure response
        at ["result", "isError"] value @?= Just (Bool True)
        at ["result", "structuredContent", "error"] value @?= Just (String "topic-conflict")
        arrayLength (at ["result", "structuredContent", "topic", "heads"] value) @?= 2,
      testCase "MCP selection rejects mixed content fields" $ withLocal $ \_ local -> do
        created <- createTopic local topicName (newTopic "first") >>= right
        let base = ["ref" .= ("me/topic" :: Text), "expected" .= versionText (viewVersion created), "select" .= ("sha256-" <> T.replicate 64 "0")]
        assertBad (parseToolCallFor cfg "topic_resolve" (args (base <> ["body" .= ("also content" :: Text)]))),
      testCase "replicated runner refuses a manually supplied legacy call" $ withLocal $ \_ local -> do
        result <- runReplicaTool cfg local (CallAddRef topicName (newTopic "legacy"))
        resultIsError result @?= True,
      testCase "explicit MCP context retains missing markers" $ withLocal $ \_ local -> do
        response <- handleMessage cfg (runReplicaTool cfg local) (request "topic_context" ["refs" .= (["me/topic"] :: [Text])])
        value <- maybe (assertFailure "No response") pure response
        arrayLength (at ["result", "structuredContent", "topics"] value) @?= 1
        assertBool "empty context was accepted" (case parseToolCallFor cfg "topic_context" (args ["refs" .= ([] :: [Text])]) of Left (BadArguments _) -> True; _ -> False)
    ]
  where
    cfg = defaultMcpConfig {mcpToolSet = Replicated, mcpAgent = "configured"}
    args fields = case object fields of Object values -> values; _ -> KM.empty
    request name fields = object ["jsonrpc" .= ("2.0" :: Text), "id" .= (1 :: Int), "method" .= ("tools/call" :: Text), "params" .= object ["name" .= (name :: Text), "arguments" .= object fields]]
    assertBad (Left (BadArguments _)) = pure ()
    assertBad value = assertFailure ("Expected bad arguments, got " <> show value)

at :: [Text] -> Value -> Maybe Value
at [] value = Just value
at (key : rest) (Object values) = KM.lookup (Key.fromText key) values >>= at rest
at _ _ = Nothing

arrayLength :: Maybe Value -> Int
arrayLength (Just (Array values)) = foldr (\_ count -> count + 1) 0 values
arrayLength _ = -1
