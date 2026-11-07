{-# LANGUAGE OverloadedStrings #-}

module SourceHashTests (sourceHashTests) where

import Akyuu.Source
  ( Located (locatedPath),
    Pointer (pointerSha256),
    Root (Root),
    Stripper,
    Verdict (CannotCheck, Changed, Intact),
    checkHash,
    engiStrip,
    hashSpan,
    mkPointer,
    parsePointer,
    renderPointer,
    sessionHook,
    spanBytes,
    withSha256,
  )
import Crypto.Hash.SHA256 qualified as SHA256
import Data.ByteString (ByteString)
import Data.ByteString qualified as B
import Data.ByteString.Base16 qualified as Base16
import Data.ByteString.Char8 qualified as BC
import Data.Char (isDigit)
import Data.Either (isLeft)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (decodeUtf8)
import Data.Time (UTCTime)
import System.Directory (findExecutable)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

sourceHashTests :: TestTree
sourceHashTests =
  testGroup
    "source hash"
    [ testGroup "session hook" hookCases,
      testGroup "pointer" pointerCases,
      testGroup "span" spanCases,
      testGroup "hash" hashCases,
      testGroup "check" checkCases,
      testGroup "engi" engiCases
    ]

t0 :: UTCTime
t0 = read "2026-11-01 19:00:58 UTC"

-- | The SHA-256 of bytes, in lower case hex.
sha :: ByteString -> Text
sha = decodeUtf8 . Base16.encode . SHA256.hash

-- | A pointer with a range, and no hash yet.
ranged :: Text -> Text -> Text -> Pointer
ranged format from to = either (error . T.unpack) id (mkPointer format "s1" t0 (Just from) (Just to) Nothing)

hashed :: Text -> Pointer -> Pointer
hashed h = either (error . T.unpack) id . withSha256 h

-- | A line of a Claude Code transcript: record number n, with the id r<n>.
rawLine :: Int -> ByteString -> ByteString
rawLine n body =
  BC.pack ("{\"type\":\"user\",\"timestamp\":\"2026-11-01T19:00:0" <> show n <> "Z\",\"uuid\":\"r" <> show n <> "\",\"message\":{\"role\":\"user\",\"content\":\"")
    <> body
    <> "\"}}"

-- | A line that is not conversation, with an id of its own, between r2 and r3.
queueLine :: ByteString
queueLine = "{\"type\":\"queue-operation\",\"timestamp\":\"2026-11-01T19:00:02Z\",\"uuid\":\"q1\"}"

transcriptWith :: ByteString -> ByteString
transcriptWith inside =
  BC.unlines [rawLine 1 "one", rawLine 2 inside, queueLine, rawLine 3 "three", rawLine 4 "four", rawLine 5 "five"]

transcript :: ByteString
transcript = transcriptWith "two"

-- | A stripper for the tests: it removes the digits of a run, like the rule of
-- engi removes the data of an image. It stands in for @engi strip@.
dropDigits :: Stripper
dropDigits b = pure (Right (BC.filter (not . isDigit) b))

failing :: Stripper
failing _ = pure (Left "no stripper here")

-- | What an agent's start hook gets on its standard input, as Claude Code
-- sends it: the id of the session, and more.
hookInput :: ByteString
hookInput = "{\"session_id\":\"0775d85c-5836-4715-a3a7-f306d261bf49\",\"transcript_path\":\"/x/y.jsonl\",\"cwd\":\"/x\",\"hook_event_name\":\"SessionStart\",\"source\":\"startup\"}"

hookCases :: [TestTree]
hookCases =
  [ testCase "the id of the session, the format and the command to run are in the text" $
      case sessionHook "claude-code" hookInput of
        Nothing -> assertFailure "expected a text"
        Just t -> do
          assertBool "id" ("0775d85c-5836-4715-a3a7-f306d261bf49" `T.isInfixOf` t)
          assertBool "format" ("claude-code" `T.isInfixOf` t)
          assertBool "command" ("akyuu source add --format claude-code --session 0775d85c-5836-4715-a3a7-f306d261bf49" `T.isInfixOf` t)
          assertBool "derived_from" ("derived_from" `T.isInfixOf` t),
    testCase "the text for another format names that format" $
      case sessionHook "codex" hookInput of
        Nothing -> assertFailure "expected a text"
        Just t -> assertBool "format" ("--format codex" `T.isInfixOf` t),
    testCase "no session id, an id with a path in it, a format that is not known and JSON that is not JSON give nothing" $ do
      sessionHook "claude-code" "{\"cwd\":\"/x\"}" @?= Nothing
      sessionHook "claude-code" "{\"session_id\":\"../etc\"}" @?= Nothing
      sessionHook "claude-code" "{\"session_id\":\"\"}" @?= Nothing
      sessionHook "claude-code" "{\"session_id\":42}" @?= Nothing
      sessionHook "nope" hookInput @?= Nothing
      sessionHook "claude-code" "not json" @?= Nothing
      sessionHook "claude-code" "" @?= Nothing
  ]

pointerCases :: [TestTree]
pointerCases =
  [ testCase "a pointer made with mkPointer has no hash" $
      pointerSha256 (ranged "claude-code" "r2" "r4") @?= Nothing,
    testCase "a hash is 64 digits of lower case hex" $ do
      assertBool "good" (not (isLeft (withSha256 (sha "x") (ranged "claude-code" "r2" "r4"))))
      assertBool "short" (isLeft (withSha256 "abc" (ranged "claude-code" "r2" "r4")))
      assertBool "upper case" (isLeft (withSha256 (T.toUpper (sha "x")) (ranged "claude-code" "r2" "r4")))
      assertBool "not hex" (isLeft (withSha256 (T.replicate 64 "z") (ranged "claude-code" "r2" "r4"))),
    testCase "the hash survives a round trip and is the last line" $ do
      let p = hashed (sha "x") (ranged "claude-code" "r2" "r4")
      parsePointer (renderPointer p) @?= Right p
      last (T.lines (renderPointer p)) @?= "sha256: " <> sha "x",
    testCase "a hash that is not a hash is refused when a pointer is read" $
      assertBool "refused" (isLeft (parsePointer (renderPointer (ranged "claude-code" "r2" "r4") <> "\nsha256: nope")))
  ]

spanCases :: [TestTree]
spanCases =
  [ testCase "the span is the raw lines from one id to another, with the lines between" $
      spanBytes "claude-code" transcript "r2" "r4" @?= Just (BC.unlines [rawLine 2 "two", queueLine, rawLine 3 "three", rawLine 4 "four"]),
    testCase "one record is a span of one line" $
      spanBytes "claude-code" transcript "r3" "r3" @?= Just (BC.unlines [rawLine 3 "three"]),
    testCase "an id that is not there, or a span that runs backwards, is nothing" $ do
      spanBytes "claude-code" transcript "r2" "r99" @?= Nothing
      spanBytes "claude-code" transcript "r99" "r2" @?= Nothing
      spanBytes "claude-code" transcript "r4" "r2" @?= Nothing,
    testCase "a Codex span runs between ordinals" $ do
      let codex :: Int -> ByteString
          codex n = BC.pack ("{\"timestamp\":\"2026-11-01T21:14:4" <> show n <> "Z\",\"ordinal\":" <> show n <> ",\"type\":\"event_msg\",\"payload\":{}}")
          file = BC.unlines (map codex [1 .. 5 :: Int])
      spanBytes "codex" file "2" "3" @?= Just (BC.unlines [codex 2, codex 3]),
    testCase "an omp span runs between entry ids" $ do
      let omp i = "{\"type\":\"message\",\"id\":\"" <> i <> "\",\"timestamp\":\"2026-11-05T22:14:26Z\",\"message\":{\"role\":\"user\",\"content\":\"x\"}}"
          file = BC.unlines [omp "aa", omp "bb", omp "cc"]
      spanBytes "omp" file "bb" "cc" @?= Just (BC.unlines [omp "bb", omp "cc"])
  ]

hashCases :: [TestTree]
hashCases =
  [ testCase "the hash is over the span after the strip rule, not the raw bytes" $ do
      Right h <- hashSpan dropDigits "claude-code" transcript "r2" "r4"
      Just raw <- pure (spanBytes "claude-code" transcript "r2" "r4")
      h @?= sha (BC.filter (not . isDigit) raw)
      assertBool "not the raw hash" (h /= sha raw),
    testCase "a stripper that fails is an error" $ do
      r <- hashSpan failing "claude-code" transcript "r2" "r4"
      r @?= Left "no stripper here",
    testCase "a span that is not in the file is an error" $ do
      r <- hashSpan dropDigits "claude-code" transcript "r2" "r99"
      assertBool "an error" (isLeft r)
  ]

checkCases :: [TestTree]
checkCases =
  [ testCase "a span that has not changed is intact" $
      withSystemTempDirectory "hash-test" $ \d -> do
        B.writeFile (d </> "s1.jsonl") transcript
        h <- expectedHash transcript
        r <- checkHash dropDigits [Root "claude-code" d] (hashed h (ranged "claude-code" "r2" "r4"))
        fmap snd r @?= Right Intact,
    testCase "a changed byte inside the span is changed" $
      withSystemTempDirectory "hash-test" $ \d -> do
        h <- expectedHash transcript
        B.writeFile (d </> "s1.jsonl") (transcriptWith "TWO")
        r <- checkHash dropDigits [Root "claude-code" d] (hashed h (ranged "claude-code" "r2" "r4"))
        fmap snd r @?= Right Changed,
    testCase "a change outside the span does not matter" $
      withSystemTempDirectory "hash-test" $ \d -> do
        h <- expectedHash transcript
        B.writeFile (d </> "s1.jsonl") (transcript <> rawLine 5 "six" <> "\n")
        r <- checkHash dropDigits [Root "claude-code" d] (hashed h (ranged "claude-code" "r2" "r4"))
        fmap snd r @?= Right Intact,
    testCase "a change that the strip rule removes is not a change" $
      withSystemTempDirectory "hash-test" $ \d -> do
        -- The span has digits in it. The stripper removes digits. The file
        -- later has other digits in the same place.
        B.writeFile (d </> "s1.jsonl") (transcriptWith "two 111")
        Right h <- hashSpan dropDigits "claude-code" (transcriptWith "two 111") "r2" "r4"
        B.writeFile (d </> "s1.jsonl") (transcriptWith "two 999")
        r <- checkHash dropDigits [Root "claude-code" d] (hashed h (ranged "claude-code" "r2" "r4"))
        fmap snd r @?= Right Intact,
    testCase "the verdict says which file was read" $
      withSystemTempDirectory "hash-test" $ \d -> do
        B.writeFile (d </> "s1.jsonl") transcript
        h <- expectedHash transcript
        r <- checkHash dropDigits [Root "claude-code" d] (hashed h (ranged "claude-code" "r2" "r4"))
        fmap (locatedPath . fst) r @?= Right (d </> "s1.jsonl"),
    testCase "a stripper that fails means the check cannot be made" $
      withSystemTempDirectory "hash-test" $ \d -> do
        B.writeFile (d </> "s1.jsonl") transcript
        h <- expectedHash transcript
        r <- checkHash failing [Root "claude-code" d] (hashed h (ranged "claude-code" "r2" "r4"))
        fmap snd r @?= Right (CannotCheck "no stripper here"),
    testCase "a session that is not here is an error that says not available" $
      withSystemTempDirectory "hash-test" $ \d -> do
        r <- checkHash dropDigits [Root "claude-code" d] (hashed (sha "x") (ranged "claude-code" "r2" "r4"))
        case r of
          Left e -> assertBool "says not available" ("not available" `T.isInfixOf` e)
          Right _ -> assertFailure "expected an error",
    testCase "a pointer with no hash cannot be checked" $
      withSystemTempDirectory "hash-test" $ \d -> do
        B.writeFile (d </> "s1.jsonl") transcript
        r <- checkHash dropDigits [Root "claude-code" d] (ranged "claude-code" "r2" "r4")
        assertBool "an error" (isLeft r),
    testCase "a pointer with a hash but no range cannot be checked" $
      withSystemTempDirectory "hash-test" $ \d -> do
        B.writeFile (d </> "s1.jsonl") transcript
        let noRange = hashed (sha "x") (either (error . T.unpack) id (mkPointer "claude-code" "s1" t0 Nothing Nothing Nothing))
        r <- checkHash dropDigits [Root "claude-code" d] noRange
        assertBool "an error" (isLeft r),
    testCase "a span whose ids are not in the file cannot be checked" $
      withSystemTempDirectory "hash-test" $ \d -> do
        B.writeFile (d </> "s1.jsonl") transcript
        r <- checkHash dropDigits [Root "claude-code" d] (hashed (sha "x") (ranged "claude-code" "r2" "r99"))
        assertBool "an error" (isLeft r)
  ]
  where
    -- The hash of the span r2..r4 of a transcript, after dropDigits.
    expectedHash file = either (\e -> assertFailure (T.unpack e)) pure =<< hashSpan dropDigits "claude-code" file "r2" "r4"

engiCases :: [TestTree]
engiCases =
  [ testCase "engi strip applies the rule: an image is replaced and the rest stays" $ do
      me <- findExecutable "engi"
      case me of
        Nothing -> putStrLn "skipped: engi is not on the PATH"
        Just _ -> do
          let image = "{\"type\":\"image\",\"source\":{\"type\":\"base64\",\"data\":\"" <> BC.replicate 300 'A' <> "\",\"media_type\":\"image/png\"}}\n"
          r <- engiStrip image
          case r of
            Left e -> assertFailure (T.unpack e)
            Right out -> do
              assertBool "replaced" ("engi-stripped-v1:300:" `B.isInfixOf` out)
              assertBool "shorter" (B.length out < B.length image),
    testCase "with the real engi, a changed image inside the span is detected, and a changed one outside is not" $ do
      me <- findExecutable "engi"
      case me of
        Nothing -> putStrLn "skipped: engi is not on the PATH"
        Just _ -> withSystemTempDirectory "hash-test" $ \d -> do
          let imageLine :: Int -> Char -> ByteString
              imageLine n c =
                BC.pack ("{\"type\":\"user\",\"timestamp\":\"2026-11-01T19:00:0" <> show n <> "Z\",\"uuid\":\"r" <> show n <> "\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"image\",\"source\":{\"type\":\"base64\",\"data\":\"")
                  <> BC.replicate 300 c
                  <> "\",\"media_type\":\"image/png\"}}]}}"
              file inside outside = BC.unlines [rawLine 1 "one", imageLine 2 inside, rawLine 3 "three", imageLine 4 outside]
          B.writeFile (d </> "s1.jsonl") (file 'A' 'A')
          h <- either (assertFailure . T.unpack) pure =<< hashSpan engiStrip "claude-code" (file 'A' 'A') "r2" "r3"
          let check = checkHash engiStrip [Root "claude-code" d] (hashed h (ranged "claude-code" "r2" "r3"))
          fmap snd <$> check >>= (@?= Right Intact)
          -- The data of an image is not kept, but the placeholder holds its
          -- hash, so another image is another span.
          B.writeFile (d </> "s1.jsonl") (file 'B' 'A')
          fmap snd <$> check >>= (@?= Right Changed)
          B.writeFile (d </> "s1.jsonl") (file 'A' 'B')
          fmap snd <$> check >>= (@?= Right Intact)
  ]
