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
    testCase "another format has no files yet" $
      classify "codex" "s1" "s1.jsonl" @?= Nothing
  ]

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
    testCase "another format has no reader yet" $
      parseRecords "codex" "{}\n" @?= [],
    testCase "a record is shown with its time and speaker, and more lines are indented" $
      renderRecord (Record (read "2026-11-01 19:00:01 UTC") "user" "one\ntwo" Nothing)
        @?= "[2026-11-01T19:00:01Z] user: one\n  two"
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
