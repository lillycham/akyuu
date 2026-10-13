{-# LANGUAGE OverloadedStrings #-}

module MCPTests (mcpTests) where

import Akyuu.Check (CheckOptions (hubDegree, nearThreshold), FindingKind (Fork), Severity (Problem), defaultCheckOptions)
import Akyuu.Error (AkyuuError (BadField, BadId, StoreFailed), describe)
import Akyuu.Graph (Edge (Edge), EdgeType (About, Supersedes))
import Akyuu.Id (IdParseError (BadHex), parse, render)
import Akyuu.MCP (CallError (BadArguments, UnknownTool), McpConfig (mcpAgent, mcpPlace, mcpPolicyRef), ToolCall (CallAdd, CallAppend, CallCheck, CallCompare, CallContext, CallGet, CallLog, CallNeighbours, CallNote, CallRefList, CallRefSet, CallReview, CallSearch, CallSearchMode), ToolResult (ToolResult), clientAgent, defaultMcpConfig, expandCall, handleLine, handleMessage, parseToolCall, resolvePrefix, runTool, supportedVersions)
import Akyuu.Ops (NewMemory (NewMemory), SearchMode (TextOnly))
import Akyuu.Query (SearchOptions (SearchOptions), defaultSearchOptions)
import Akyuu.Refs (Expected (MustBe, MustBeAbsent), mkName)
import Akyuu.Render (shortIds)
import Akyuu.Store (StoreError (NotFound))
import Akyuu.Tier (Place (Place))
import Data.Aeson (Value (Array, Bool, Null, Number, Object, String), object, (.=))
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
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

mcpTests :: TestTree
mcpTests =
  testGroup
    "Akyuu.MCP"
    [ protocolCases,
      toolCallCases,
      runToolCases
    ]

-- Helpers --------------------------------------------------------------

-- A tool runner that runs nothing. It answers with the Show form of the
-- call, so a test can see which call the handler made.
fake :: ToolCall -> ToolResult
fake tc = ToolResult (T.pack (show tc)) False

-- Answer one message with the fake runner.
answer :: Value -> Maybe Value
answer = runIdentity . handleMessage defaultMcpConfig (pure . fake)

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
        (r >>= at ["id"]) @?= Just (Number 1),
      testCase "initialize tells a client to read the memory policy first" $ do
        let r = answer (req (Number 1) "initialize" (object ["protocolVersion" .= ("2025-06-18" :: Text)]))
        case r >>= at ["result", "instructions"] of
          Just (String t) -> do
            assertBool "names the policy ref" ("policy/memory" `T.isInfixOf` t)
            assertBool "does not name one agent" (not ("claude" `T.isInfixOf` t))
            assertBool "still explains supersede" ("supersede" `T.isInfixOf` t)
          other -> assertFailure ("expected instructions text, got " <> show other),
      testCase "the policy ref comes from the config" $ do
        let r = runIdentity (handleMessage (defaultMcpConfig {mcpPolicyRef = "team/how-we-remember"}) (pure . fake) (req (Number 1) "initialize" (object [])))
        case r >>= at ["result", "instructions"] of
          Just (String t) -> do
            assertBool "names the configured ref" ("team/how-we-remember" `T.isInfixOf` t)
            assertBool "not the default" (not ("policy/memory" `T.isInfixOf` t))
          other -> assertFailure ("expected instructions text, got " <> show other),
      testCase "initialize with an unknown version offers the newest" $
        (answer (req (Number 1) "initialize" (object ["protocolVersion" .= ("1999-01-01" :: Text)])) >>= at ["result", "protocolVersion"])
          @?= fmap String (listToMaybe supportedVersions),
      testCase "a notification gets no answer" $
        answer (object ["jsonrpc" .= ("2.0" :: Text), "method" .= ("notifications/initialized" :: Text)]) @?= Nothing,
      testCase "an unknown notification gets no answer" $
        answer (object ["jsonrpc" .= ("2.0" :: Text), "method" .= ("notifications/whatever" :: Text)]) @?= Nothing,
      testCase "a response from the client gets no answer" $
        answer (object ["jsonrpc" .= ("2.0" :: Text), "id" .= (5 :: Int), "result" .= object []]) @?= Nothing,
      testCase "ping gives an empty result, with a string id" $ do
        let r = answer (req (String "abc") "ping" (object []))
        (r >>= at ["result"]) @?= Just (object [])
        (r >>= at ["id"]) @?= Just (String "abc"),
      testCase "tools/list lists every tool with a schema" $ do
        let r = answer (req (Number 2) "tools/list" (object []))
        case r >>= at ["result", "tools"] of
          Just (Array ts) -> do
            let names = [n | t <- foldr (:) [] ts, Just (String n) <- [at ["name"] t]]
            Set.fromList names @?= Set.fromList ["add", "get", "supersede", "search", "neighbours", "ref_get", "ref_set", "ref_list", "check", "compare", "review", "context", "append", "log", "amend", "note"]
            mapM_ (\t -> (at ["inputSchema", "type"] t, isJust (at ["description"] t)) @?= (Just "object", True)) ts
          other -> assertFailure ("no tools: " <> show other),
      testCase "a tool call runs the tool" $ do
        let r = answer (callReq "neighbours" (object ["id" .= render (nid 1)]))
        toolOut r @?= Just (String (T.pack (show (CallNeighbours (nid 1)))), Bool False),
      testCase "bad arguments give a tool error with the friendly text" $ do
        let r = answer (callReq "neighbours" (object ["id" .= ("sha256-zz" :: Text)]))
        toolOut r @?= Just (String (describe (BadId "sha256-zz" (BadHex "zz"))), Bool True),
      testCase "a missing argument gives a tool error" $
        toolOut (answer (callReq "neighbours" (object [])))
          @?= Just (String "The argument 'id' is missing.", Bool True),
      testCase "an unknown tool gives -32602" $
        errCode (answer (callReq "nope" (object []))) @?= Just (Number (-32602)),
      testCase "tools/call with no params gives -32602" $
        errCode (answer (object ["jsonrpc" .= ("2.0" :: Text), "id" .= (1 :: Int), "method" .= ("tools/call" :: Text)])) @?= Just (Number (-32602)),
      testCase "arguments that are not an object give -32602" $
        errCode (answer (req (Number 1) "tools/call" (object ["name" .= ("ref_list" :: Text), "arguments" .= ([] :: [Int])]))) @?= Just (Number (-32602)),
      testCase "an unknown method gives -32601" $
        errCode (answer (req (Number 1) "resources/list" (object []))) @?= Just (Number (-32601)),
      testCase "a message without jsonrpc 2.0 gives -32600" $
        errCode (answer (object ["id" .= (1 :: Int), "method" .= ("ping" :: Text)])) @?= Just (Number (-32600)),
      testCase "a null id gives -32600" $
        errCode (answer (req Null "ping" (object []))) @?= Just (Number (-32600)),
      testCase "a batch (an array) gives -32600" $
        errCode (answer (A.toJSON [req (Number 1) "ping" (object [])])) @?= Just (Number (-32600)),
      testCase "a line that is not JSON gives -32700 with a null id" $ do
        let r = runIdentity (handleLine defaultMcpConfig (pure . fake) "{not json")
        errCode r @?= Just (Number (-32700))
        (r >>= at ["id"]) @?= Just Null,
      testCase "a blank line gives no answer" $
        runIdentity (handleLine defaultMcpConfig (pure . fake) "  \r") @?= Nothing,
      testCase "every answer is one line of JSON" $ do
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
          @?= Right (CallAdd (NewMemory "fact" "claude" (Set.fromList [Edge About (nid 1), Edge Supersedes (nid 2)]) "hi")),
      testCase "add checks the kind" $
        parseToolCall "add" (args [("kind", "a\nb"), ("agent", "claude"), ("body", "hi")])
          @?= Left (BadArguments (describe (BadField "kind" "a\nb"))),
      testCase "get needs exactly one of id and ref" $ do
        parseToolCall "get" (args []) @?= Left (BadArguments "Give exactly one of the arguments 'id' and 'ref'.")
        n <- right (mkName "claude/notes")
        parseToolCall "get" (args [("ref", "claude/notes")]) @?= Right (CallGet (Left n)),
      testCase "search fills in the defaults" $
        parseToolCall "search" (args [("query", "haskell")]) @?= Right (CallSearch defaultSearchOptions "haskell"),
      testCase "search reads limit, hops and follow" $
        parseToolCall "search" (args [("query", "x"), ("limit", Number 3), ("hops", Number 0), ("follow", A.toJSON ["about" :: Text])])
          @?= Right (CallSearch (SearchOptions 3 0 (Set.singleton About)) "x"),
      testCase "search refuses a limit of 0 and a fraction" $ do
        parseToolCall "search" (args [("query", "x"), ("limit", Number 0)]) @?= Left (BadArguments "The argument 'limit' must be at least 1.")
        parseToolCall "search" (args [("query", "x"), ("hops", Number 1.5)]) @?= Left (BadArguments "The argument 'hops' must be a whole number."),
      testCase "ref_set needs expected or create" $ do
        n <- right (mkName "a")
        parseToolCall "ref_set" (args [("ref", "a"), ("id", String (render (nid 1)))])
          @?= Left (BadArguments "Give 'expected' (the id that the ref points to now), or 'create': true for a new ref.")
        parseToolCall "ref_set" (args [("ref", "a"), ("id", String (render (nid 1))), ("create", Bool True)])
          @?= Right (CallRefSet n MustBeAbsent (nid 1))
        parseToolCall "ref_set" (args [("ref", "a"), ("id", String (render (nid 1))), ("expected", String (render (nid 2)))])
          @?= Right (CallRefSet n (MustBe (nid 2)) (nid 1)),
      testCase "check fills in the defaults" $
        parseToolCall "check" (args []) @?= Right (CallCheck defaultCheckOptions [] Nothing),
      testCase "check reads kinds, severity and the options" $
        parseToolCall "check" (args [("kinds", A.toJSON ["fork" :: Text]), ("severity", "problem"), ("near_threshold", Number 0.5), ("hub_degree", Number 9)])
          @?= Right (CallCheck defaultCheckOptions {nearThreshold = 0.5, hubDegree = 9} [Fork] (Just Problem)),
      testCase "check refuses a kind that does not exist and a threshold above 1" $ do
        parseToolCall "check" (args [("kinds", A.toJSON ["nope" :: Text])])
          @?= Left (BadArguments "The argument 'kinds' has 'nope', which is not a kind of finding.")
        parseToolCall "check" (args [("near_threshold", Number 2)])
          @?= Left (BadArguments "The argument 'near_threshold' must be from 0 to 1."),
      testCase "compare needs both ids" $ do
        parseToolCall "compare" (args [("a", String (render (nid 1))), ("b", String (render (nid 2)))])
          @?= Right (CallCompare (nid 1) (nid 2))
        parseToolCall "compare" (args [("a", String (render (nid 1)))])
          @?= Left (BadArguments "The argument 'b' is missing."),
      testCase "review needs a, b and agent" $ do
        parseToolCall "review" (args [("a", String (render (nid 1))), ("b", String (render (nid 2))), ("agent", "claude")])
          @?= Right (CallReview (nid 1) (nid 2) "claude" "")
        parseToolCall "review" (args [("a", String (render (nid 1))), ("b", String (render (nid 2)))])
          @?= Left (BadArguments "The argument 'agent' is missing."),
      testCase "append and log read their arguments" $ do
        n <- right (mkName "agent/episodes")
        parseToolCall "append" (args [("ref", "agent/episodes"), ("kind", "episode"), ("agent", "claude"), ("body", "x")])
          @?= Right (CallAppend n (NewMemory "episode" "claude" Set.empty "x"))
        parseToolCall "log" (args [("ref", "agent/episodes"), ("limit", Number 3), ("full", Bool True)])
          @?= Right (CallLog n (Just 3) True Nothing),
      testCase "context reads the tier and the refs" $ do
        parseToolCall "context" (args []) @?= Right (CallContext Nothing Nothing [] Nothing Nothing)
        n <- right (mkName "claude/projects/x")
        parseToolCall "context" (args [("tier", "background"), ("refs", A.toJSON ["claude/projects/x" :: Text])])
          @?= Right (CallContext (Just "background") Nothing [n] Nothing Nothing),
      testCase "an unknown tool" $
        parseToolCall "rm" (args []) @?= Left (UnknownTool "rm")
    ]

-- runTool --------------------------------------------------------------

runToolCases :: TestTree
runToolCases =
  testGroup
    "runTool"
    [ testCase "add, ref_set, get by ref and search" $
        withOpsEnv $ \_ env -> do
          ToolResult i False <- runTool defaultMcpConfig env (CallAdd (NewMemory "fact" "claude" Set.empty "Lilly prefers Haskell"))
          n <- right (mkName "claude/notes")
          ToolResult _ False <- runTool defaultMcpConfig env =<< either (assertFailure . show) pure (parseToolCall "ref_set" (args [("ref", "claude/notes"), ("id", String i), ("create", Bool True)]))
          ToolResult g False <- runTool defaultMcpConfig env (CallGet (Left n))
          T.isSuffixOf "\n\nLilly prefers Haskell" g @?= True
          ToolResult s False <- runTool defaultMcpConfig env (CallSearch defaultSearchOptions "haskell")
          T.isPrefixOf (shortIds i) s @?= True,
      testCase "search text has the same brackets as the CLI" $
        withOpsEnv $ \_ env -> do
          ToolResult i False <- runTool defaultMcpConfig env (CallAdd (NewMemory "fact" "claude" Set.empty "see [x] and Haskell"))
          ToolResult s False <- runTool defaultMcpConfig env (CallSearch defaultSearchOptions "haskell")
          s @?= shortIds i <> "  see \\[x\\] and [Haskell]",
      testCase "a failed operation is a tool error with the CLI text" $
        withOpsEnv $ \_ env -> do
          r <- runTool defaultMcpConfig env (CallGet (Right (nid 7)))
          r @?= ToolResult (describe (StoreFailed (NotFound (nid 7)))) True,
      testCase "check shows a fork and says when there is nothing" $
        withOpsEnv $ \_ env -> do
          ToolResult none False <- runTool defaultMcpConfig env (CallCheck defaultCheckOptions [] Nothing)
          none @?= "No findings."
          ToolResult old False <- runTool defaultMcpConfig env (CallAdd (NewMemory "fact" "claude" Set.empty "the old text"))
          let oldId = either (error . show) id (parse old)
              sup = Set.singleton (Edge Supersedes oldId)
          _ <- runTool defaultMcpConfig env (CallAdd (NewMemory "fact" "claude" sup "new one"))
          _ <- runTool defaultMcpConfig env (CallAdd (NewMemory "fact" "claude" sup "new two"))
          ToolResult r False <- runTool defaultMcpConfig env (CallCheck defaultCheckOptions [Fork] (Just Problem))
          T.isPrefixOf "[problem] fork:" r @?= True,
      testCase "compare says what each memory has alone" $
        withOpsEnv $ \_ env -> do
          ToolResult a False <- runTool defaultMcpConfig env (CallAdd (NewMemory "fact" "claude" Set.empty "Shared one. Mine."))
          ToolResult b False <- runTool defaultMcpConfig env (CallAdd (NewMemory "fact" "claude" Set.empty "Shared one. Yours."))
          let ida = either (error . show) id (parse a)
              idb = either (error . show) id (parse b)
          ToolResult r False <- runTool defaultMcpConfig env (CallCompare ida idb)
          let ls = T.lines r
          assertBool "A alone" ("  - Mine." `elem` ls)
          assertBool "B alone" ("  - Yours." `elem` ls),
      testCase "search names the refs that hold a hit, and ref_list shows the first line" $
        withOpsEnv $ \_ env -> do
          ToolResult i False <- runTool defaultMcpConfig env (CallAdd (NewMemory "fact" "claude" Set.empty "Lilly likes tea\nand more"))
          n <- right (mkName "claude/tea")
          _ <- runTool defaultMcpConfig env (CallRefSet n MustBeAbsent (either (error . show) id (parse i)))
          ToolResult s False <- runTool defaultMcpConfig env (CallSearch defaultSearchOptions "tea")
          assertBool "held by" ("  held by claude/tea" `elem` T.lines s)
          ToolResult l False <- runTool defaultMcpConfig env CallRefList
          l @?= "claude/tea  " <> shortIds i <> "  Lilly likes tea",
      testCase "a prefix of 8 digits names the memory, and a shared prefix is an error" $
        withOpsEnv $ \_ env -> do
          ToolResult i False <- runTool defaultMcpConfig env (CallAdd (NewMemory "fact" "claude" Set.empty "one"))
          let short = T.take (7 + 8) i
              call = BL.toStrict (A.encode (callReq "get" (object ["id" .= short])))
          Right out <- expandCall (resolvePrefix env) call
          (A.decodeStrict out >>= at ["params", "arguments", "id"]) @?= Just (String i)
          -- 4 digits are too few to look up: the normal check gives the error.
          let few = BL.toStrict (A.encode (callReq "get" (object ["id" .= T.take 11 i])))
          Right out2 <- expandCall (resolvePrefix env) few
          (A.decodeStrict out2 >>= at ["params", "arguments", "id"]) @?= Just (String (T.take 11 i))
          -- No memory has this prefix.
          Left bad <- expandCall (resolvePrefix env) (BL.toStrict (A.encode (callReq "get" (object ["id" .= ("sha256-00000000" :: Text)]))))
          (at ["result", "isError"] bad) @?= Just (Bool True),
      testCase "a notification with a bad prefix gets no answer" $
        withOpsEnv $ \_ env -> do
          let note' = BL.toStrict (A.encode (object ["jsonrpc" .= ("2.0" :: Text), "method" .= ("tools/call" :: Text), "params" .= object ["name" .= ("get" :: Text), "arguments" .= object ["id" .= ("sha256-00000000" :: Text)]]]))
          r <- expandCall (resolvePrefix env) note'
          r @?= Right note',
      testCase "the name of the client becomes an agent name" $ do
        let ini n = BL.toStrict (A.encode (req (Number 1) "initialize" (object ["clientInfo" .= object ["name" .= (n :: Text), "version" .= ("1" :: Text)]])))
        clientAgent (ini "claude-code") @?= Just "claude-code"
        clientAgent (ini "Claude Desktop") @?= Just "claude-desktop"
        clientAgent (ini "") @?= Nothing
        clientAgent "{not json" @?= Nothing,
      testCase "shortIds cuts whole ids and leaves the rest" $ do
        let full = "sha256-" <> T.replicate 64 "a"
        shortIds ("x " <> full <> " y sha256-abc") @?= "x sha256-" <> T.replicate 12 "a" <> " y sha256-abc",
      testCase "amend changes one passage, keeps the edges and moves the ref" $
        withOpsEnv $ \_ env -> do
          ToolResult t False <- runTool defaultMcpConfig env (CallAdd (NewMemory "fact" "claude" Set.empty "target"))
          let tid = either (error . show) id (parse t)
          ToolResult i False <- runTool defaultMcpConfig env (CallAdd (NewMemory "fact" "claude" (Set.singleton (Edge About tid)) "Lilly likes tea."))
          n <- right (mkName "claude/tea")
          _ <- runTool defaultMcpConfig env (CallRefSet n MustBeAbsent (either (error . show) id (parse i)))
          call <- either (assertFailure . show) pure (parseToolCall "amend" (args [("ref", "claude/tea"), ("replace", Array (pure (object ["from" .= ("tea" :: Text), "to" .= ("coffee" :: Text)])))]))
          ToolResult new False <- runTool defaultMcpConfig env call
          ToolResult g False <- runTool defaultMcpConfig env (CallGet (Left n))
          assertBool "new text" ("\n\nLilly likes coffee." `T.isSuffixOf` g)
          assertBool "edge kept" (("about: " <> t) `T.isInfixOf` g)
          assertBool "replaces" (("supersedes: " <> i) `T.isInfixOf` g)
          assertBool "a new memory" (new /= i)
          -- A text that is not there is an error, and the ref stays.
          bad <- either (assertFailure . show) pure (parseToolCall "amend" (args [("ref", "claude/tea"), ("replace", Array (pure (object ["from" .= ("milk" :: Text), "to" .= ("x" :: Text)])))]))
          ToolResult _ True <- runTool defaultMcpConfig env bad
          ToolResult g2 False <- runTool defaultMcpConfig env (CallGet (Left n))
          g2 @?= g,
      testCase "context adds the refs of a directory, and note goes to its log" $
        withOpsEnv $ \_ env -> do
          let cfg = defaultMcpConfig {mcpPlace = Just (Place "/h" "/h/devel/p/src"), mcpAgent = "me"}
              addRef r t = do
                ToolResult i False <- runTool cfg env (CallAdd (NewMemory "fact" "claude" Set.empty t))
                n <- right (mkName r)
                _ <- runTool cfg env (CallRefSet n MustBeAbsent (either (error . show) id (parse i)))
                pure ()
          addRef "claude/profile" "profile text"
          n0 <- right (mkName "claude/long")
          addRef "claude/proj" "project text"
          addRef "policy/tiers" "always: claude/profile\nat ~/devel/p: claude/proj\nlog *: claude/log/general\nlog ~/devel/p: claude/log/p"
          ToolResult c False <- runTool cfg env (CallContext Nothing Nothing [] Nothing Nothing)
          assertBool "profile" ("profile text" `T.isInfixOf` c)
          assertBool "project" ("project text" `T.isInfixOf` c)
          ToolResult c2 False <- runTool cfg env (CallContext Nothing (Just "/elsewhere") [] Nothing Nothing)
          -- With a budget, a memory that does not fit is one line and a pointer.
          addRef "claude/long" (T.replicate 300 "long text ")
          ToolResult c3 False <- runTool cfg env (CallContext Nothing Nothing [n0] (Just 700) Nothing)
          assertBool "under the budget" (T.length c3 <= 700)
          assertBool "points at the next page" ("more on page 2: claude/long" `T.isInfixOf` c3 && not ("long text long text" `T.isInfixOf` c3))
          ToolResult c4 False <- runTool cfg env (CallContext Nothing Nothing [n0] (Just 700) (Just 2))
          assertBool "page 2 has the long memory, cut" ("== claude/long" `T.isInfixOf` c4 && "Read it with get" `T.isInfixOf` c4 && T.length c4 < 1500)
          ToolResult c5 False <- runTool cfg env (CallContext Nothing Nothing [n0] (Just 700) (Just 9))
          c5 @?= ""
          assertBool "short memory still in full" ("profile text" `T.isInfixOf` c3)
          assertBool "no project elsewhere" (not ("project text" `T.isInfixOf` c2))
          ToolResult r False <- runTool cfg env (CallNote Nothing Nothing (NewMemory "note" "" Set.empty "a small thing"))
          assertBool "named log" ("noted in claude/log/p " `T.isPrefixOf` r)
          ToolResult l False <- runTool cfg env =<< either (assertFailure . show) pure (parseToolCall "log" (args [("ref", "claude/log/p")]))
          assertBool "agent and text" ("me  note  a small thing" `T.isInfixOf` l)
          ToolResult r2 False <- runTool cfg env (CallNote (Just "/tmp") (Just "x") (NewMemory "note" "" Set.empty "other"))
          assertBool "default log" ("noted in claude/log/general " `T.isPrefixOf` r2),
      testCase "add with a ref makes the ref, and refuses a ref that exists" $
        withOpsEnv $ \_ env -> do
          c1 <- either (assertFailure . show) pure (parseToolCall "add" (args [("kind", "fact"), ("agent", "claude"), ("body", "first"), ("ref", "claude/new")]))
          ToolResult i False <- runTool defaultMcpConfig env c1
          n <- right (mkName "claude/new")
          ToolResult g False <- runTool defaultMcpConfig env (CallGet (Left n))
          assertBool "the ref holds it" ("\n\nfirst" `T.isSuffixOf` g)
          c2 <- either (assertFailure . show) pure (parseToolCall "add" (args [("kind", "fact"), ("agent", "claude"), ("body", "second"), ("ref", "claude/new")]))
          ToolResult why True <- runTool defaultMcpConfig env c2
          assertBool "says to supersede" ("supersede" `T.isInfixOf` why)
          ToolResult s False <- runTool defaultMcpConfig env (CallSearch defaultSearchOptions "second")
          s @?= "No matches."
          assertBool "id printed" ("sha256-" `T.isPrefixOf` i),
      testCase "search takes a mode" $ do
        parseToolCall "search" (args [("query", "x"), ("mode", "text")]) @?= Right (CallSearchMode TextOnly defaultSearchOptions "x")
        parseToolCall "search" (args [("query", "x"), ("mode", "fused")]) @?= Right (CallSearch defaultSearchOptions "x")
        assertBool "bad mode" (either (const True) (const False) (parseToolCall "search" (args [("query", "x"), ("mode", "vibes")]))),
      testCase "an empty search says so" $
        withOpsEnv $ \_ env -> do
          r <- runTool defaultMcpConfig env (CallSearch defaultSearchOptions "nothing")
          r @?= ToolResult "No matches." False
    ]
