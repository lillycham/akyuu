{-# LANGUAGE OverloadedStrings #-}

module SourceTests (sourceTests) where

import Akyuu.Source
  ( Located (locatedPath, locatedWhere),
    Pointer (pointerAt, pointerFormat, pointerFrom, pointerHint, pointerSession, pointerTo),
    Record (Record, recordId, recordRole, recordText, recordTime),
    Root (Root),
    Shown (shownRecords),
    Where (Archived, Live),
    Window (Window),
    classify,
    locate,
    mkPointer,
    parsePointer,
    parseRecords,
    renderPointer,
    renderRecord,
    selectRange,
    selectWindow,
    showPointer,
  )
import Control.Monad (forM_)
import Data.ByteString (ByteString)
import Data.ByteString qualified as B
import Data.ByteString.Char8 qualified as BC
import Data.Either (isLeft, isRight)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime)
import System.Directory (createDirectoryIfMissing, createFileLink, findExecutable)
import System.FilePath (takeDirectory, takeFileName, (</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Process (callProcess)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

at :: Text -> UTCTime
at t = read (T.unpack (T.replace "T" " " (T.dropWhileEnd (== 'Z') t)) <> " UTC")

-- | A pointer that is known to be valid.
mk :: Text -> Text -> UTCTime -> Maybe Text -> Maybe Text -> Maybe Text -> Pointer
mk format session time from to hint = either (error . T.unpack) id (mkPointer format session time from to hint)

-- | The only record of a list. A test that expects one fails loudly if it
-- gets another number.
one :: [Record] -> Record
one [r] = r
one rs = error ("expected one record, got " <> show (length rs))

ptr :: Pointer
ptr = mk "claude-code" "0775d85c-5836-4715-a3a7-f306d261bf49" (at "2026-11-01T19:00:58") Nothing Nothing Nothing

sourceTests :: TestTree
sourceTests =
  testGroup
    "source"
    [ testGroup "pointer" pointerCases,
      testGroup "names" nameCases,
      testGroup "locate" locateCases,
      testGroup "records" recordCases,
      testGroup "codex" codexCases,
      testGroup "omp" ompCases,
      testGroup "window" windowCases,
      testGroup "show" showCases
    ]

pointerCases :: [TestTree]
pointerCases =
  [ testCase "a pointer is written as key: value lines in a fixed order" $
      renderPointer ptr
        @?= T.intercalate
          "\n"
          [ "format: claude-code",
            "session: 0775d85c-5836-4715-a3a7-f306d261bf49",
            "at: 2026-11-01T19:00:58Z"
          ],
    testCase "every field survives a round trip" $ do
      let p = mk "claude-code" "s1" (at "2026-11-01T19:00:58") (Just "u1") (Just "u2") (Just "projects/app/s1.jsonl")
      parsePointer (renderPointer p) @?= Right p,
    testCase "a trailing line feed is accepted" $
      parsePointer (renderPointer ptr <> "\n") @?= Right ptr,
    testCase "a field that a later version adds is ignored" $
      parsePointer (renderPointer ptr <> "\nsha256: abc") @?= Right ptr,
    testCase "a missing field is an error" $ do
      assertBool "no session" (isLeft (parsePointer "format: claude-code\nat: 2026-11-01T19:00:58Z"))
      assertBool "no format" (isLeft (parsePointer "session: s1\nat: 2026-11-01T19:00:58Z"))
      assertBool "no at" (isLeft (parsePointer "format: claude-code\nsession: s1")),
    testCase "a repeated field is an error" $
      assertBool "duplicate" (isLeft (parsePointer (renderPointer ptr <> "\nsession: other"))),
    testCase "an unknown format is refused" $
      assertBool "format" (isLeft (mkPointer "nope" "s1" (at "2026-11-01T19:00:58") Nothing Nothing Nothing)),
    testCase "a session with a path in it is refused" $ do
      forM_ ["../x", "a/b", "", "a b", "a\nb"] $ \s ->
        assertBool (T.unpack s) (isLeft (mkPointer "claude-code" s (at "2026-11-01T19:00:58") Nothing Nothing Nothing)),
    testCase "a hint must be relative and stay below its root" $ do
      assertBool "absolute" (isLeft (mkPointer "claude-code" "s1" (at "2026-11-01T19:00:58") Nothing Nothing (Just "/Users/me/x.jsonl")))
      assertBool "up" (isLeft (mkPointer "claude-code" "s1" (at "2026-11-01T19:00:58") Nothing Nothing (Just "a/../../x")))
      assertBool "relative is fine" (isRight (mkPointer "claude-code" "s1" (at "2026-11-01T19:00:58") Nothing Nothing (Just "projects/x.jsonl"))),
    testCase "the fields can be read back" $ do
      let p = mk "claude-code" "s1" (at "2026-11-01T19:00:58") (Just "u1") (Just "u2") (Just "h/s1.jsonl")
      (pointerFormat p, pointerSession p, pointerAt p) @?= ("claude-code", "s1", at "2026-11-01T19:00:58")
      (pointerFrom p, pointerTo p, pointerHint p) @?= (Just "u1", Just "u2", Just "h/s1.jsonl")
  ]

nameCases :: [TestTree]
nameCases =
  [ testCase "a live file is named for the session" $
      classify "claude-code" "s1" "s1.jsonl" @?= Just Live,
    testCase "the first archived copy has no number" $
      classify "claude-code" "s1" "s1.jsonl.zst" @?= Just (Archived 1),
    testCase "a later archived copy has a number" $
      classify "claude-code" "s1" "s1.3.jsonl.zst" @?= Just (Archived 3),
    testCase "another session, a partial name and other files do not match" $ do
      classify "claude-code" "s1" "s10.jsonl" @?= Nothing
      classify "claude-code" "s1" "xs1.jsonl" @?= Nothing
      classify "claude-code" "s1" "s1.txt" @?= Nothing
      classify "claude-code" "s1" "s1.x.jsonl.zst" @?= Nothing
      classify "claude-code" "s1" "s1.jsonl.zst.age" @?= Nothing
      classify "claude-code" "s1" "s1.jsonl.tmp" @?= Nothing,
    testCase "a format that akyuu does not know has no files" $
      classify "nope" "s1" "s1.jsonl" @?= Nothing,
    testCase "a Codex file is named rollout-, a time and the session id" $ do
      classify "codex" codexId ("rollout-2026-11-01T21-14-40-" <> T.unpack codexId <> ".jsonl") @?= Just Live
      classify "codex" codexId ("rollout-2026-11-01T21-14-40-" <> T.unpack codexId <> ".jsonl.zst") @?= Just (Archived 1)
      classify "codex" codexId ("rollout-2026-11-01T21-14-40-" <> T.unpack codexId <> ".2.jsonl.zst") @?= Just (Archived 2),
    testCase "a Codex file of another session, or with a part of the id, does not match" $ do
      classify "codex" codexId "rollout-2026-11-01T21-14-40-01a198f6-e81f-70e1-a1bc-000000000000.jsonl" @?= Nothing
      -- The last group of the id is not the whole id.
      classify "codex" "ad78fe0c9eaf" ("rollout-2026-11-01T21-14-40-" <> T.unpack codexId <> ".jsonl") @?= Nothing
      classify "codex" codexId "rollout-2026-11-01T21-14-40-xx.jsonl" @?= Nothing,
    testCase "an omp file is a time, an underscore and the session id" $ do
      classify "omp" ompId ("2026-11-05T22-13-52-910Z_" <> T.unpack ompId <> ".jsonl") @?= Just Live
      classify "omp" ompId ("2026-11-05T22-13-52-910Z_" <> T.unpack ompId <> ".jsonl.zst") @?= Just (Archived 1),
    testCase "an omp session with a name is found by its name" $
      classify "omp" "AssessTopicsEval" "AssessTopicsEval.jsonl" @?= Just Live,
    testCase "an omp file of another session, or with a part of the id, does not match" $ do
      classify "omp" ompId "2026-11-05T22-13-52-910Z_01a1adc6-8c8e-7721-925d-000000000000.jsonl" @?= Nothing
      classify "omp" "925d-c6b31dde4473" ("2026-11-05T22-13-52-910Z_" <> T.unpack ompId <> ".jsonl") @?= Nothing
  ]

codexId, ompId :: Text
codexId = "01a198f6-e81f-70e1-a1bc-ad78fe0c9eaf"
ompId = "01a1adc6-8c8e-7721-925d-c6b31dde4473"

-- | Write a file below a root, with its folders.
putFile :: FilePath -> FilePath -> ByteString -> IO ()
putFile root rel bytes = do
  let p = root </> rel
  createDirectoryIfMissing True (takeDirectory p)
  B.writeFile p bytes

locateCases :: [TestTree]
locateCases =
  [ testCase "a session is found in a folder below a root" $
      withSystemTempDirectory "src-test" $ \d -> do
        putFile d ("proj" </> "deep" </> "s1.jsonl") "{}\n"
        putFile d ("proj" </> "other.jsonl") "{}\n"
        found <- locate [Root "claude-code" d] (pointerOf "s1")
        map (takeFileName . locatedPath) found @?= ["s1.jsonl"],
    testCase "a live file comes before an archived one" $
      withSystemTempDirectory "src-test" $ \d -> do
        putFile (d </> "live") "s1.jsonl" "{}\n"
        putFile (d </> "arc") ("claude" </> "s1.jsonl.zst") "x"
        found <- locate [Root "claude-code" (d </> "arc"), Root "claude-code" (d </> "live")] (pointerOf "s1")
        map locatedWhere found @?= [Live, Archived 1],
    testCase "the newest archived version comes first" $
      withSystemTempDirectory "src-test" $ \d -> do
        putFile d ("a" </> "s1.jsonl.zst") "x"
        putFile d ("a" </> "s1.2.jsonl.zst") "x"
        putFile d ("a" </> "s1.10.jsonl.zst") "x"
        found <- locate [Root "claude-code" d] (pointerOf "s1")
        map locatedWhere found @?= [Archived 10, Archived 2, Archived 1],
    testCase "of two live copies the larger one comes first" $
      withSystemTempDirectory "src-test" $ \d -> do
        putFile d ("a" </> "s1.jsonl") "{}\n"
        putFile d ("b" </> "s1.jsonl") "{}\n{}\n{}\n"
        found <- locate [Root "claude-code" d] (pointerOf "s1")
        map (takeFileName . takeDirectory . locatedPath) found @?= ["b", "a"],
    testCase "a root of another format is not searched" $
      withSystemTempDirectory "src-test" $ \d -> do
        putFile d "s1.jsonl" "{}\n"
        found <- locate [Root "codex" d] (pointerOf "s1")
        found @?= [],
    testCase "a root that does not exist has nothing" $
      withSystemTempDirectory "src-test" $ \d -> do
        found <- locate [Root "claude-code" (d </> "missing")] (pointerOf "s1")
        found @?= [],
    testCase "a symbolic link is not followed" $
      withSystemTempDirectory "src-test" $ \d -> do
        putFile (d </> "real") "s1.jsonl" "{}\n"
        createDirectoryIfMissing True (d </> "root")
        createFileLink (d </> "real" </> "s1.jsonl") (d </> "root" </> "s1.jsonl")
        found <- locate [Root "claude-code" (d </> "root")] (pointerOf "s1")
        found @?= []
  ]
  where
    pointerOf s = mk "claude-code" s (at "2026-11-01T19:00:58") Nothing Nothing Nothing

-- | A line of a Claude Code transcript. The id is made from the time, like
-- the dash-and-hex id of a real one: letters and digits, no colons.
line :: Text -> Text -> Text -> ByteString
line typ time message =
  BC.pack
    ( "{\"type\":\""
        <> T.unpack typ
        <> "\",\"timestamp\":\""
        <> T.unpack time
        <> "\",\"uuid\":\""
        <> T.unpack (idAt time)
        <> "\",\"message\":"
        <> T.unpack message
        <> "}"
    )

-- | The id that 'line' gives to the record at a time.
idAt :: Text -> Text
idAt time = "u-" <> T.filter (`notElem` (":-." :: String)) time

recordCases :: [TestTree]
recordCases =
  [ testCase "a user message with text is a user record" $
      map (\r -> (recordRole r, recordText r)) (parseRecords "claude-code" (line "user" "2026-11-01T19:00:01.250Z" "{\"role\":\"user\",\"content\":\"hello there\"}"))
        @?= [("user", "hello there")],
    testCase "the time has milliseconds and the id is the uuid" $ do
      let r = one $ parseRecords "claude-code" (line "user" "2026-11-01T19:00:01.250Z" "{\"role\":\"user\",\"content\":\"x\"}")
      recordTime r @?= read "2026-11-01 19:00:01.25 UTC"
      recordId r @?= Just (idAt "2026-11-01T19:00:01.250Z"),
    testCase "an assistant reply keeps its text and shows a tool call" $ do
      let content = "{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"I will run it\"},{\"type\":\"tool_use\",\"name\":\"Bash\",\"input\":{\"command\":\"ls\"}}]}"
          r = one $ parseRecords "claude-code" (line "assistant" "2026-11-01T19:00:02Z" content)
      recordRole r @?= "assistant"
      assertBool "text" ("I will run it" `T.isInfixOf` recordText r)
      assertBool "tool" ("[tool_use Bash]" `T.isInfixOf` recordText r)
      assertBool "input" ("ls" `T.isInfixOf` recordText r),
    testCase "thinking text is kept and marked" $ do
      let content = "{\"role\":\"assistant\",\"content\":[{\"type\":\"thinking\",\"thinking\":\"let me think\",\"signature\":\"engi-stripped-v1:300:abc\"}]}"
          r = one $ parseRecords "claude-code" (line "assistant" "2026-11-01T19:00:03Z" content)
      assertBool "marked" ("[thinking] let me think" `T.isInfixOf` recordText r)
      assertBool "no signature" (not ("engi-stripped" `T.isInfixOf` recordText r)),
    testCase "a user record that holds only a tool result is a tool record" $ do
      let content = "{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"t1\",\"content\":\"file.txt\"}]}"
          r = one $ parseRecords "claude-code" (line "user" "2026-11-01T19:00:04Z" content)
      recordRole r @?= "tool"
      assertBool "result" ("[tool_result] file.txt" `T.isInfixOf` recordText r),
    testCase "a tool result with blocks shows its text" $ do
      let content = "{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"content\":[{\"type\":\"text\",\"text\":\"done\"},{\"type\":\"image\",\"source\":{}}]}]}"
          r = one $ parseRecords "claude-code" (line "user" "2026-11-01T19:00:04Z" content)
      assertBool "text" ("done" `T.isInfixOf` recordText r)
      assertBool "image" ("[image]" `T.isInfixOf` recordText r),
    testCase "records that are not conversation are skipped" $
      parseRecords "claude-code" (BC.unlines ["{\"type\":\"queue-operation\",\"timestamp\":\"2026-11-01T19:00:00Z\"}", "{\"type\":\"attachment\",\"timestamp\":\"2026-11-01T19:00:00Z\"}", "{\"type\":\"system\",\"timestamp\":\"2026-11-01T19:00:00Z\"}"])
        @?= [],
    testCase "a line that is not JSON, and a record with no time, are skipped" $
      parseRecords "claude-code" (BC.unlines ["not json", "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"no time\"}}", "{}", ""])
        @?= [],
    testCase "a long record is cut" $ do
      let long = T.replicate 5000 "x"
          r = one $ parseRecords "claude-code" (line "user" "2026-11-01T19:00:01Z" ("{\"role\":\"user\",\"content\":\"" <> long <> "\"}"))
      assertBool "cut" (T.length (recordText r) < 1000)
      assertBool "marked" ("…" `T.isSuffixOf` recordText r),
    testCase "a format that akyuu does not know has no records" $
      parseRecords "nope" "{}\n" @?= [],
    testCase "a record is shown with its time and speaker, and more lines are indented" $
      renderRecord (Record (read "2026-11-01 19:00:01 UTC") "user" "one\ntwo" Nothing)
        @?= "[2026-11-01T19:00:01Z] user: one\n  two"
  ]

-- | A line of a Codex rollout: a record with an ordinal, a type and a payload.
codexLine :: Int -> Text -> Text -> Text -> ByteString
codexLine ordinal typ time payload =
  BC.pack
    ( "{\"timestamp\":\""
        <> T.unpack time
        <> "\",\"ordinal\":"
        <> show ordinal
        <> ",\"type\":\""
        <> T.unpack typ
        <> "\",\"payload\":"
        <> T.unpack payload
        <> "}"
    )

-- | A response item of a Codex rollout.
codexItem :: Int -> Text -> Text -> ByteString
codexItem ordinal time = codexLine ordinal "response_item" time

codexCases :: [TestTree]
codexCases =
  [ testCase "a user message is a user record, and its id is its ordinal" $ do
      let r = one $ parseRecords "codex" (codexItem 7 "2026-11-01T21:14:41.538Z" "{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"check it\"},{\"type\":\"input_text\",\"text\":\"then develop it\"}]}")
      (recordRole r, recordText r, recordId r) @?= ("user", "check it\nthen develop it", Just "7")
      recordTime r @?= read "2026-11-01 21:14:41.538 UTC",
    testCase "an assistant message is an assistant record" $ do
      let r = one $ parseRecords "codex" (codexItem 8 "2026-11-01T21:14:44Z" "{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"done\"}]}")
      (recordRole r, recordText r) @?= ("assistant", "done"),
    testCase "a developer message is left out: it is instructions that the host adds" $
      parseRecords "codex" (codexItem 1 "2026-11-01T21:14:41Z" "{\"type\":\"message\",\"role\":\"developer\",\"content\":[{\"type\":\"input_text\",\"text\":\"rules\"}]}") @?= [],
    testCase "reasoning with a summary is shown as thinking, and with none is left out" $ do
      let withSummary = one $ parseRecords "codex" (codexItem 2 "2026-11-01T21:14:42Z" "{\"type\":\"reasoning\",\"summary\":[{\"type\":\"summary_text\",\"text\":\"weighing two options\"}],\"encrypted_content\":\"x\"}")
      recordText withSummary @?= "[thinking] weighing two options"
      parseRecords "codex" (codexItem 3 "2026-11-01T21:14:43Z" "{\"type\":\"reasoning\",\"summary\":[],\"encrypted_content\":\"x\"}") @?= [],
    testCase "a function call and its output" $ do
      let call = one $ parseRecords "codex" (codexItem 4 "2026-11-01T21:14:45Z" "{\"type\":\"function_call\",\"name\":\"exec_command\",\"arguments\":\"{\\\"cmd\\\":\\\"ls\\\"}\",\"call_id\":\"c1\"}")
          out = one $ parseRecords "codex" (codexItem 5 "2026-11-01T21:14:46Z" "{\"type\":\"function_call_output\",\"call_id\":\"c1\",\"output\":\"file.txt\"}")
      (recordRole call, "[tool_use exec_command]" `T.isInfixOf` recordText call, "ls" `T.isInfixOf` recordText call) @?= ("assistant", True, True)
      (recordRole out, recordText out) @?= ("tool", "[tool_result] file.txt"),
    testCase "a custom tool call and an output made of blocks" $ do
      let call = one $ parseRecords "codex" (codexItem 6 "2026-11-01T21:14:47Z" "{\"type\":\"custom_tool_call\",\"name\":\"apply_patch\",\"input\":\"*** Begin Patch\",\"call_id\":\"c2\"}")
          out = one $ parseRecords "codex" (codexItem 7 "2026-11-01T21:14:48Z" "{\"type\":\"custom_tool_call_output\",\"call_id\":\"c2\",\"output\":[{\"type\":\"input_text\",\"text\":\"patched\"}]}")
      assertBool "call" ("[tool_use apply_patch] *** Begin Patch" `T.isInfixOf` recordText call)
      recordText out @?= "[tool_result] patched",
    testCase "a message from one agent to another shows who wrote it and who reads it" $ do
      let r = one $ parseRecords "codex" (codexItem 9 "2026-11-01T21:14:49Z" "{\"type\":\"agent_message\",\"author\":\"/root/a\",\"recipient\":\"/root\",\"content\":[{\"type\":\"input_text\",\"text\":\"ready\"}]}")
      (recordRole r, recordText r) @?= ("agent", "[/root/a -> /root] ready"),
    testCase "records that are not response items are left out" $
      parseRecords "codex" (BC.unlines [codexLine 0 "session_meta" "2026-11-01T21:14:40Z" "{\"id\":\"x\"}", codexLine 1 "event_msg" "2026-11-01T21:14:41Z" "{\"type\":\"token_count\"}", codexLine 2 "turn_context" "2026-11-01T21:14:41Z" "{}"]) @?= [],
    testCase "a line that is not JSON, or has no time, is left out" $
      parseRecords "codex" (BC.unlines ["not json", "{\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"no time\"}]}}"]) @?= [],
    testCase "a record without an ordinal has no id" $ do
      let r = one $ parseRecords "codex" "{\"timestamp\":\"2026-11-01T21:14:41Z\",\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"x\"}]}}"
      recordId r @?= Nothing,
    testCase "a long Codex record is cut" $ do
      let long = T.replicate 5000 "y"
          r = one $ parseRecords "codex" (codexItem 1 "2026-11-01T21:14:41Z" ("{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"" <> long <> "\"}]}"))
      assertBool "cut" (T.length (recordText r) < 1000)
  ]

-- | A message entry of an omp or pi session.
ompMessage :: Text -> Text -> Text -> ByteString
ompMessage entryId time message =
  BC.pack
    ( "{\"type\":\"message\",\"id\":\""
        <> T.unpack entryId
        <> "\",\"parentId\":null,\"timestamp\":\""
        <> T.unpack time
        <> "\",\"message\":"
        <> T.unpack message
        <> "}"
    )

ompCases :: [TestTree]
ompCases =
  [ testCase "a user message is a user record, and its id is the id of the entry" $ do
      let r = one $ parseRecords "omp" (ompMessage "85f60b36" "2026-11-05T22:14:26.023Z" "{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"why this design\"}]}")
      (recordRole r, recordText r, recordId r) @?= ("user", "why this design", Just "85f60b36")
      recordTime r @?= read "2026-11-05 22:14:26.023 UTC",
    testCase "a user message can be a plain string" $
      map recordText (parseRecords "omp" (ompMessage "a1" "2026-11-05T22:14:26Z" "{\"role\":\"user\",\"content\":\"plain\"}")) @?= ["plain"],
    testCase "an assistant message shows its text, its thinking and its tool calls" $ do
      let content = "{\"role\":\"assistant\",\"content\":[{\"type\":\"thinking\",\"thinking\":\"let me look\",\"thinkingSignature\":\"engi-stripped-v1:300:abc\"},{\"type\":\"text\",\"text\":\"I will read it\"},{\"type\":\"toolCall\",\"id\":\"t1\",\"name\":\"read\",\"arguments\":{\"path\":\"/a/b.hs\"},\"intent\":\"reading\"}]}"
          r = one $ parseRecords "omp" (ompMessage "4d779922" "2026-11-05T22:14:28Z" content)
      recordRole r @?= "assistant"
      assertBool "thinking" ("[thinking] let me look" `T.isInfixOf` recordText r)
      assertBool "text" ("I will read it" `T.isInfixOf` recordText r)
      assertBool "tool" ("[tool_use read] /a/b.hs" `T.isInfixOf` recordText r)
      assertBool "no signature" (not ("engi-stripped" `T.isInfixOf` recordText r)),
    testCase "a tool result is a tool record" $ do
      let r = one $ parseRecords "omp" (ompMessage "r1" "2026-11-05T22:14:29Z" "{\"role\":\"toolResult\",\"toolCallId\":\"t1\",\"toolName\":\"read\",\"isError\":false,\"content\":[{\"type\":\"text\",\"text\":\"module X\"},{\"type\":\"image\",\"data\":\"blob:sha256:abc\"}]}")
      recordRole r @?= "tool"
      assertBool "text" ("[tool_result] module X" `T.isInfixOf` recordText r)
      assertBool "image" ("[image]" `T.isInfixOf` recordText r),
    testCase "a system message is left out" $
      parseRecords "omp" (ompMessage "s1" "2026-11-05T22:14:30Z" "{\"role\":\"system\",\"content\":[{\"type\":\"text\",\"text\":\"you are\"}]}") @?= [],
    testCase "entries that are not messages are left out" $
      parseRecords "omp" (BC.unlines ["{\"type\":\"session\",\"version\":3,\"id\":\"x\",\"timestamp\":\"2026-11-05T22:13:52Z\"}", "{\"type\":\"model_usage\",\"timestamp\":\"2026-11-05T22:13:53Z\"}", "{\"type\":\"custom\",\"timestamp\":\"2026-11-05T22:13:54Z\"}"]) @?= [],
    testCase "a line that is not JSON, or has no time, is left out" $
      parseRecords "omp" (BC.unlines ["nope", "{\"type\":\"message\",\"id\":\"a\",\"message\":{\"role\":\"user\",\"content\":\"no time\"}}"]) @?= []
  ]

rec :: Text -> Text -> Record
rec time t = Record (at time) "user" t (Just ("id-" <> t))

windowCases :: [TestTree]
windowCases =
  [ testCase "the records before the time, and a few after" $ do
      let rs = [rec ("2026-11-01T19:00:0" <> T.pack (show n) <> "Z") (T.pack (show n)) | n <- [1 .. 9 :: Int]]
      map recordText (selectWindow (Window 3 2) (at "2026-11-01T19:00:05Z") rs) @?= ["3", "4", "5", "6", "7"],
    testCase "fewer records before the time than asked for" $ do
      let rs = [rec ("2026-11-01T19:00:0" <> T.pack (show n) <> "Z") (T.pack (show n)) | n <- [1 .. 3 :: Int]]
      map recordText (selectWindow (Window 5 1) (at "2026-11-01T19:00:02Z") rs) @?= ["1", "2", "3"],
    testCase "a time before every record shows the first ones after it" $ do
      let rs = [rec ("2026-11-01T19:00:0" <> T.pack (show n) <> "Z") (T.pack (show n)) | n <- [5 .. 9 :: Int]]
      map recordText (selectWindow (Window 3 2) (at "2026-11-01T19:00:01Z") rs) @?= ["5", "6"],
    testCase "no records is an empty window" $
      selectWindow (Window 3 2) (at "2026-11-01T19:00:01Z") [] @?= [],
    testCase "a range runs from one record id to another, both included" $ do
      let rs = [rec ("2026-11-01T19:00:0" <> T.pack (show n) <> "Z") (T.pack (show n)) | n <- [1 .. 6 :: Int]]
      fmap (map recordText) (selectRange "id-2" "id-4" rs) @?= Just ["2", "3", "4"],
    testCase "a range with an unknown end, or backwards, is nothing" $ do
      let rs = [rec ("2026-11-01T19:00:0" <> T.pack (show n) <> "Z") (T.pack (show n)) | n <- [1 .. 6 :: Int]]
      fmap (map recordText) (selectRange "id-2" "id-99" rs) @?= Nothing
      fmap (map recordText) (selectRange "id-4" "id-2" rs) @?= Nothing
  ]

-- | A small Claude Code transcript with five records, one second apart.
transcript :: ByteString
transcript =
  BC.unlines
    [ "{\"type\":\"queue-operation\",\"timestamp\":\"2026-11-01T19:00:00Z\"}",
      line "user" "2026-11-01T19:00:01Z" "{\"role\":\"user\",\"content\":\"first question\"}",
      line "assistant" "2026-11-01T19:00:02Z" "{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"first answer\"}]}",
      line "user" "2026-11-01T19:00:03Z" "{\"role\":\"user\",\"content\":\"second question\"}",
      line "assistant" "2026-11-01T19:00:04Z" "{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"second answer\"}]}",
      line "user" "2026-11-01T19:00:09Z" "{\"role\":\"user\",\"content\":\"much later\"}"
    ]

showCases :: [TestTree]
showCases =
  [ testCase "the records around a time are shown from a live file" $
      withSystemTempDirectory "src-test" $ \d -> do
        putFile d ("p" </> "s1.jsonl") transcript
        r <- showPointer [Root "claude-code" d] (Window 2 1) (pointerAtTime (at "2026-11-01T19:00:04Z"))
        case r of
          Left e -> assertFailure (T.unpack e)
          Right s -> map recordText (shownRecords s) @?= ["second question", "second answer", "much later"],
    testCase "a pointer with a range shows that range" $
      withSystemTempDirectory "src-test" $ \d -> do
        putFile d "s1.jsonl" transcript
        let p = mk "claude-code" "s1" (at "2026-11-01T19:00:09Z") (Just (idAt "2026-11-01T19:00:02Z")) (Just (idAt "2026-11-01T19:00:03Z")) Nothing
        r <- showPointer [Root "claude-code" d] (Window 1 1) p
        case r of
          Left e -> assertFailure (T.unpack e)
          Right s -> map recordText (shownRecords s) @?= ["first answer", "second question"],
    testCase "a Codex session is found by the id in its name and shown" $
      withSystemTempDirectory "src-test" $ \d -> do
        putFile d ("2026" </> "11" </> "01" </> ("rollout-2026-11-01T21-14-40-" <> T.unpack codexId <> ".jsonl")) $
          BC.unlines
            [ codexLine 0 "session_meta" "2026-11-01T21:14:40Z" "{\"id\":\"x\"}",
              codexItem 1 "2026-11-01T21:14:41Z" "{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"why this design\"}]}",
              codexItem 2 "2026-11-01T21:14:42Z" "{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"because it is simple\"}]}"
            ]
        let p = mk "codex" codexId (at "2026-11-01T21:14:42Z") Nothing Nothing Nothing
        r <- showPointer [Root "codex" d] (Window 1 0) p
        case r of
          Left e -> assertFailure (T.unpack e)
          Right s -> map recordText (shownRecords s) @?= ["because it is simple"],
    testCase "a Codex pointer with a range of ordinals shows that range" $
      withSystemTempDirectory "src-test" $ \d -> do
        putFile d ("rollout-2026-11-01T21-14-40-" <> T.unpack codexId <> ".jsonl") $
          BC.unlines [codexItem n (T.pack ("2026-11-01T21:14:4" <> show n <> "Z")) ("{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"m" <> T.pack (show n) <> "\"}]}") | n <- [1 .. 5 :: Int]]
        let p = mk "codex" codexId (at "2026-11-01T21:14:45Z") (Just "2") (Just "4") Nothing
        r <- showPointer [Root "codex" d] (Window 0 0) p
        case r of
          Left e -> assertFailure (T.unpack e)
          Right s -> map recordText (shownRecords s) @?= ["m2", "m3", "m4"],
    testCase "an omp session is found by the id in its name and shown" $
      withSystemTempDirectory "src-test" $ \d -> do
        putFile d ("-devel-akyuu" </> ("2026-11-05T22-13-52-910Z_" <> T.unpack ompId <> ".jsonl")) $
          BC.unlines
            [ "{\"type\":\"session\",\"version\":3,\"id\":\"" <> BC.pack (T.unpack ompId) <> "\",\"timestamp\":\"2026-11-05T22:13:52.910Z\"}",
              ompMessage "a1" "2026-11-05T22:14:26Z" "{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"why this design\"}]}",
              ompMessage "a2" "2026-11-05T22:14:28Z" "{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"because it is simple\"}]}"
            ]
        let p = mk "omp" ompId (at "2026-11-05T22:14:28Z") Nothing Nothing Nothing
        r <- showPointer [Root "omp" d] (Window 1 0) p
        case r of
          Left e -> assertFailure (T.unpack e)
          Right s -> map recordText (shownRecords s) @?= ["because it is simple"],
    testCase "every known format can be named in a pointer" $
      mapM_ (\f -> assertBool (T.unpack f) (isRight (mkPointer f "s1" (at "2026-11-01T19:00:58") Nothing Nothing Nothing))) ["claude-code", "codex", "omp"],
    testCase "a session that is not under any root is not available" $
      withSystemTempDirectory "src-test" $ \d -> do
        r <- showPointer [Root "claude-code" d] (Window 2 1) (pointerAtTime (at "2026-11-01T19:00:04Z"))
        case r of
          Left e -> assertBool "says not available" ("not available" `T.isInfixOf` e)
          Right _ -> assertFailure "expected not available",
    testCase "no roots at all is not available, and says that no root is set" $ do
      r <- showPointer [] (Window 2 1) (pointerAtTime (at "2026-11-01T19:00:04Z"))
      case r of
        Left e -> assertBool "mentions roots" ("root" `T.isInfixOf` e)
        Right _ -> assertFailure "expected an error",
    testCase "a file with no conversation is an error that says so" $
      withSystemTempDirectory "src-test" $ \d -> do
        putFile d "s1.jsonl" "{\"type\":\"queue-operation\",\"timestamp\":\"2026-11-01T19:00:00Z\"}\n"
        r <- showPointer [Root "claude-code" d] (Window 2 1) (pointerAtTime (at "2026-11-01T19:00:04Z"))
        assertBool "an error" (isLeft r),
    testCase "an archived file is read with zstd" $ do
      mz <- findExecutable "zstd"
      case mz of
        Nothing -> putStrLn "skipped: zstd is not on the PATH"
        Just _ -> withSystemTempDirectory "src-test" $ \d -> do
          putFile d "plain.jsonl" transcript
          createDirectoryIfMissing True (d </> "arc" </> "claude")
          callProcess "zstd" ["-q", "-o", d </> "arc" </> "claude" </> "s1.jsonl.zst", d </> "plain.jsonl"]
          r <- showPointer [Root "claude-code" (d </> "arc")] (Window 1 0) (pointerAtTime (at "2026-11-01T19:00:02Z"))
          case r of
            Left e -> assertFailure (T.unpack e)
            Right s -> map recordText (shownRecords s) @?= ["first answer"],
    testCase "a damaged archive file is an error" $ do
      mz <- findExecutable "zstd"
      case mz of
        Nothing -> putStrLn "skipped: zstd is not on the PATH"
        Just _ -> withSystemTempDirectory "src-test" $ \d -> do
          putFile d ("arc" </> "s1.jsonl.zst") "this is not zstd"
          r <- showPointer [Root "claude-code" (d </> "arc")] (Window 1 1) (pointerAtTime (at "2026-11-01T19:00:02Z"))
          assertBool "an error" (isLeft r)
  ]
  where
    pointerAtTime t = mk "claude-code" "s1" t Nothing Nothing Nothing
