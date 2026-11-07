{-# LANGUAGE OverloadedStrings #-}

module SourceCliTests (sourceCliTests) where

import Akyuu.CLI (Cli (cliCommand), Command (SourceAdd, SourceShow, SourceVerify), Output (outBytes, outOk), SourceArgs (SourceArgs), parseCli, runCommand)
import Akyuu.Error (AkyuuError (BadInput))
import Akyuu.Graph (Edge (Edge), EdgeType (DerivedFrom))
import Akyuu.Id (Id)
import Akyuu.Id qualified as Id
import Akyuu.Memory (Memory (memAgent, memBody, memKind))
import Akyuu.Ops (Env, IdSpec (Full), NewMemory (NewMemory), addMemory, getMemory)
import Akyuu.Source (Pointer (pointerAt, pointerSession), parsePointer)
import Control.Exception (bracket)
import Data.ByteString qualified as B
import Data.Either (isLeft)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (decodeUtf8)
import Data.Time (UTCTime, diffUTCTime, getCurrentTime)
import OpsTests (withOpsEnv)
import Options.Applicative (ParserResult (Failure, Success))
import Support (nid, right)
import System.Directory (createDirectoryIfMissing)
import System.Environment (lookupEnv, setEnv, unsetEnv)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty (DependencyType (AllFinish), TestTree, dependentTestGroup, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

sourceCliTests :: TestTree
sourceCliTests = testGroup "source commands" [parseCases, runCases]

parsed :: [String] -> IO (Command IdSpec)
parsed args = case parseCli args of
  Success c -> pure (cliCommand c)
  Failure _ -> assertFailure ("did not parse: " <> unwords args)
  _ -> assertFailure "completion"

rejected :: [String] -> IO ()
rejected args = case parseCli args of
  Failure _ -> pure ()
  _ -> assertFailure ("expected a usage error: " <> unwords args)

t0 :: UTCTime
t0 = read "2026-11-01 19:00:58 UTC"

idStr :: Id -> String
idStr = T.unpack . Id.render

parseCases :: TestTree
parseCases =
  testGroup
    "parse"
    [ testCase "source add takes a session and a time, and the format is claude-code" $ do
        c <- parsed ["source", "add", "--session", "s1", "--at", "2026-11-01T19:00:58Z"]
        c @?= SourceAdd (SourceArgs "claude-code" "s1" (Just t0) Nothing Nothing Nothing Nothing),
      testCase "source add with every option" $ do
        c <- parsed ["source", "add", "--format", "claude-code", "--session", "s1", "--at", "2026-11-01T19:00:58Z", "--from", "u1", "--to", "u2", "--hint", "p/s1.jsonl", "--agent", "codex"]
        c @?= SourceAdd (SourceArgs "claude-code" "s1" (Just t0) (Just "u1") (Just "u2") (Just "p/s1.jsonl") (Just "codex")),
      testCase "source add without a time means now" $ do
        c <- parsed ["source", "add", "--session", "s1"]
        c @?= SourceAdd (SourceArgs "claude-code" "s1" Nothing Nothing Nothing Nothing Nothing),
      testCase "source add needs a session" $ rejected ["source", "add"],
      testCase "source add refuses a time that is not a time" $ rejected ["source", "add", "--session", "s1", "--at", "yesterday"],
      testCase "source show takes an id, and shows 6 records before and 2 after" $ do
        c <- parsed ["source", "show", idStr (nid 1)]
        c @?= SourceShow (Full (nid 1)) 6 2,
      testCase "source show takes the window" $ do
        c <- parsed ["source", "show", idStr (nid 1), "--before", "3", "--after", "1"]
        c @?= SourceShow (Full (nid 1)) 3 1,
      testCase "source verify takes an id" $ do
        c <- parsed ["source", "verify", idStr (nid 1)]
        c @?= SourceVerify (Full (nid 1)),
      testCase "source needs a subcommand" $ rejected ["source"]
    ]

-- | Run an action with a config file that has one source root. The setting
-- that the test run started with is put back.
withRoot :: FilePath -> IO a -> IO a
withRoot root act = withSystemTempDirectory "src-cfg" $ \d -> do
  let cfg = d </> "config.toml"
  B.writeFile cfg ("[source]\nroots = [{ format = \"claude-code\", path = \"" <> encode root <> "\" }]\n")
  withConfig cfg act
  where
    encode = B.pack . map (fromIntegral . fromEnum)

withConfig :: FilePath -> IO a -> IO a
withConfig cfg act =
  bracket
    (lookupEnv "AKYUU_CONFIG" <* setEnv "AKYUU_CONFIG" cfg)
    (maybe (unsetEnv "AKYUU_CONFIG") (setEnv "AKYUU_CONFIG"))
    (const act)

-- | A small transcript: two records, a second apart.
transcript :: B.ByteString
transcript =
  B.intercalate
    "\n"
    [ "{\"type\":\"user\",\"timestamp\":\"2026-11-01T19:00:57Z\",\"uuid\":\"u1\",\"message\":{\"role\":\"user\",\"content\":\"why did you pick zstd\"}}",
      "{\"type\":\"assistant\",\"timestamp\":\"2026-11-01T19:00:58Z\",\"uuid\":\"u2\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"it compresses these files well\"}]}}",
      ""
    ]

text :: Output -> Text
text = decodeUtf8 . outBytes

pointerArgs :: Text -> SourceArgs
pointerArgs session = SourceArgs "claude-code" session (Just t0) Nothing Nothing Nothing Nothing

-- | Run source add and read the id that it prints.
addPointer :: Env -> SourceArgs -> IO Id
addPointer env args = do
  o <- right =<< runCommand env (SourceAdd args)
  case filter (not . T.null) (T.lines (text o)) of
    [i] -> either (assertFailure . show) pure (Id.parse i)
    other -> assertFailure ("expected one line with an id, got " <> show other)

-- | These cases set AKYUU_CONFIG, which is one variable for the whole
-- process, so they run one after another. In parallel one case would read the
-- config of another.
runCases :: TestTree
runCases =
  dependentTestGroup
    "run"
    AllFinish
    [ testCase "source add makes a memory of kind source with the pointer as its body" $
        withOpsEnv $ \_ env -> do
          m <- right =<< getMemory env =<< addPointer env (pointerArgs "s1")
          memKind m @?= "source"
          fmap (\p -> (pointerSession p, pointerAt p)) (parsePointer (memBody m)) @?= Right ("s1", t0),
      testCase "source add uses the agent that is given" $
        withOpsEnv $ \_ env -> do
          m <- right =<< getMemory env =<< addPointer env (SourceArgs "claude-code" "s1" (Just t0) Nothing Nothing Nothing (Just "codex"))
          memAgent m @?= "codex",
      testCase "source add without a time uses now" $
        withOpsEnv $ \_ env -> do
          before <- getCurrentTime
          m <- right =<< getMemory env =<< addPointer env (SourceArgs "claude-code" "s1" Nothing Nothing Nothing Nothing Nothing)
          case parsePointer (memBody m) of
            Left e -> assertFailure (T.unpack e)
            Right p -> assertBool "within a minute of now" (abs (diffUTCTime (pointerAt p) before) < 60),
      testCase "source add refuses a bad session with a message" $
        withOpsEnv $ \_ env -> do
          r <- runCommand env (SourceAdd (pointerArgs "../etc"))
          case r of
            Left (BadInput msg) -> assertBool "says session" ("session" `T.isInfixOf` msg)
            Left e -> assertFailure ("wrong error: " <> show e)
            Right _ -> assertFailure "expected an error",
      testCase "source show of a pointer prints the records around its time" $
        withSystemTempDirectory "src-root" $ \root -> do
          createDirectoryIfMissing True (root </> "p")
          B.writeFile (root </> "p" </> "s1.jsonl") transcript
          withRoot root $ withOpsEnv $ \_ env -> do
            pid <- addPointer env (pointerArgs "s1")
            o <- right =<< runCommand env (SourceShow pid 6 2)
            outOk o @?= True
            assertBool "question" ("why did you pick zstd" `T.isInfixOf` text o)
            assertBool "answer" ("it compresses these files well" `T.isInfixOf` text o)
            assertBool "names the session" ("s1" `T.isInfixOf` text o)
            assertBool "says where it was read" ("live" `T.isInfixOf` text o),
      testCase "source show of a note that derives from a pointer follows the link" $
        withSystemTempDirectory "src-root" $ \root -> do
          B.writeFile (root </> "s1.jsonl") transcript
          withRoot root $ withOpsEnv $ \_ env -> do
            pid <- addPointer env (pointerArgs "s1")
            note <- right =<< addMemory env (NewMemory "note" "claude" (Set.singleton (Edge DerivedFrom pid)) "we chose zstd" Set.empty)
            o <- right =<< runCommand env (SourceShow note 6 2)
            assertBool "answer" ("it compresses these files well" `T.isInfixOf` text o),
      testCase "source show of a memory with no pointer is an error" $
        withSystemTempDirectory "src-root" $ \root ->
          withRoot root $ withOpsEnv $ \_ env -> do
            plain <- right =<< addMemory env (NewMemory "fact" "claude" Set.empty "no source" Set.empty)
            r <- runCommand env (SourceShow plain 6 2)
            assertBool "an error" (isLeft r),
      testCase "source show of a session that is not here says not available, and does not succeed" $
        withSystemTempDirectory "src-root" $ \root ->
          withRoot root $ withOpsEnv $ \_ env -> do
            pid <- addPointer env (pointerArgs "gone")
            o <- right =<< runCommand env (SourceShow pid 6 2)
            outOk o @?= False
            assertBool "says not available" ("not available" `T.isInfixOf` text o),
      testCase "source show with no root set says where to set one" $
        withSystemTempDirectory "src-cfg" $ \d -> do
          let cfg = d </> "config.toml"
          B.writeFile cfg "agent = \"x\"\n"
          withConfig cfg $ withOpsEnv $ \_ env -> do
            pid <- addPointer env (pointerArgs "s1")
            o <- right =<< runCommand env (SourceShow pid 6 2)
            outOk o @?= False
            assertBool "mentions the config" ("[source]" `T.isInfixOf` text o),
      testCase "source verify says where the session is" $
        withSystemTempDirectory "src-root" $ \root -> do
          B.writeFile (root </> "s1.jsonl") transcript
          withRoot root $ withOpsEnv $ \_ env -> do
            pid <- addPointer env (pointerArgs "s1")
            o <- right =<< runCommand env (SourceVerify pid)
            assertBool ("verify said: " <> T.unpack (text o)) (outOk o)
            assertBool "live" ("live" `T.isInfixOf` text o),
      testCase "source verify of a session that is not here does not succeed" $
        withSystemTempDirectory "src-root" $ \root ->
          withRoot root $ withOpsEnv $ \_ env -> do
            pid <- addPointer env (pointerArgs "gone")
            o <- right =<< runCommand env (SourceVerify pid)
            outOk o @?= False
            assertBool "not available" ("not available" `T.isInfixOf` text o)
    ]
