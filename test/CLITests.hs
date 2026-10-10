{-# LANGUAGE OverloadedStrings #-}

module CLITests (cliTests) where

import Akyuu.CLI
import Akyuu.Graph (Edge (..), EdgeType (..))
import Akyuu.Id (render)
import Akyuu.Query (SearchOptions (..), defaultSearchOptions)
import Akyuu.Refs (Expected (..), Name, mkName)
import Data.ByteString qualified as BS
import Data.List (isInfixOf)
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Text.Encoding (decodeUtf8)
import Options.Applicative (ParserResult (..), renderFailure)
import OpsTests (withOpsEnv)
import Support (nid, right)
import System.Exit (ExitCode (..))
import Test.Tasty
import Test.Tasty.HUnit

cliTests :: TestTree
cliTests =
  testGroup
    "Akyuu.CLI"
    [ parseCases
    , failureCases
    , runCases
    ]

-- Helpers --------------------------------------------------------------

-- The command that the arguments give, or a failed test.
parses :: [String] -> IO Cli
parses args = case parseCli args of
  Success c -> pure c
  Failure f -> assertFailure (fst (renderFailure f "akyuu"))
  CompletionInvoked _ -> assertFailure "completion"

-- The text and exit code of a parse that must fail.
fails :: [String] -> IO (String, ExitCode)
fails args = case parseCli args of
  Failure f -> pure (renderFailure f "akyuu")
  Success c -> assertFailure ("expected a failure, got " <> show c)
  CompletionInvoked _ -> assertFailure "completion"

name :: T.Text -> IO Name
name = right . mkName

i1, i2 :: String
i1 = T.unpack (render (nid 1))
i2 = T.unpack (render (nid 2))

-- Parsing --------------------------------------------------------------

parseCases :: TestTree
parseCases =
  testGroup
    "parseCli"
    [ testCase "add with edges and a body" $ do
        c <- parses ["--root", "/s", "add", "--kind", "fact", "--agent", "claude", "--about", i1, "--refines", i2, "--body", "hi"]
        c
          @?= Cli
            (Just "/s")
            (Add (MemoryArgs "fact" "claude" (Set.fromList [Edge About (nid 1), Edge Refines (nid 2)]) (BodyText "hi")))
    , testCase "add reads stdin by default" $ do
        c <- parses ["add", "--kind", "fact", "--agent", "claude"]
        c @?= Cli Nothing (Add (MemoryArgs "fact" "claude" Set.empty BodyStdin))
    , testCase "add takes --file" $ do
        c <- parses ["add", "--kind", "fact", "--agent", "claude", "-f", "body.txt"]
        cliCommand c @?= Add (MemoryArgs "fact" "claude" Set.empty (BodyFile "body.txt"))
    , testCase "get by id and by ref" $ do
        n <- name "claude/notes"
        a <- parses ["get", i1]
        b <- parses ["get", "--ref", "claude/notes"]
        (cliCommand a, cliCommand b) @?= (Get (ById (nid 1)), Get (ByRef n))
    , testCase "supersede with --expect" $ do
        n <- name "claude/notes"
        c <- parses ["supersede", "claude/notes", "--expect", i1, "--kind", "fact", "--agent", "claude", "--body", "v2"]
        cliCommand c @?= Supersede n (Just (nid 1)) (MemoryArgs "fact" "claude" Set.empty (BodyText "v2"))
    , testCase "ref set: unchecked, --new and --expect" $ do
        n <- name "a"
        cs <- traverse parses [["ref", "set", "a", i1], ["ref", "set", "a", i1, "--new"], ["ref", "set", "a", i1, "--expect", i2]]
        map cliCommand cs @?= [RefSet n Unchecked (nid 1), RefSet n MustBeAbsent (nid 1), RefSet n (MustBe (nid 2)) (nid 1)]
    , testCase "ref get --history and ref list" $ do
        n <- name "a"
        a <- parses ["ref", "get", "a", "--history"]
        b <- parses ["ref", "list"]
        (cliCommand a, cliCommand b) @?= (RefGet n True, RefList)
    , testCase "search joins the words and keeps the defaults" $ do
        c <- parses ["search", "lilly", "haskell"]
        cliCommand c @?= Search defaultSearchOptions "lilly haskell"
    , testCase "search options" $ do
        c <- parses ["search", "-n", "3", "--hops", "0", "--follow", "about", "--follow", "derived-from", "x"]
        cliCommand c @?= Search (SearchOptions 3 0 (Set.fromList [About, DerivedFrom])) "x"
    , testCase "gc, gc --dry-run, reindex, verify, neighbours" $ do
        cs <- traverse parses [["gc"], ["gc", "--dry-run"], ["reindex"], ["verify"], ["neighbours", i1]]
        map cliCommand cs @?= [GC False, GC True, Reindex, Verify, Neighbours (nid 1)]
    ]

failureCases :: TestTree
failureCases =
  testGroup
    "bad usage"
    [ testCase "a bad id shows the friendly text" $ do
        (msg, code) <- fails ["get", "sha256-zz"]
        assertBool msg ("the part after sha256- must be hex digits" `isInfixOf` msg)
        assertBool "not success" (code /= ExitSuccess)
    , testCase "a bad ref name shows the friendly text" $ do
        (msg, _) <- fails ["ref", "get", "Bad"]
        assertBool msg ("is not a valid ref name" `isInfixOf` msg)
    , testCase "a kind with a space at the end is refused" $ do
        (msg, _) <- fails ["add", "--kind", "fact ", "--agent", "claude"]
        assertBool msg ("is not valid" `isInfixOf` msg)
    , testCase "--new and --expect together are refused" $ do
        _ <- fails ["ref", "set", "a", i1, "--new", "--expect", i2]
        pure ()
    , testCase "a negative --hops is refused" $ do
        (msg, _) <- fails ["search", "--hops", "-1", "x"]
        assertBool msg ("at least 0" `isInfixOf` msg)
    , testCase "an unknown --follow kind is refused" $ do
        (msg, _) <- fails ["search", "--follow", "likes", "x"]
        assertBool msg ("is not a kind of edge" `isInfixOf` msg)
    , testCase "search needs words" $ do
        _ <- fails ["search"]
        pure ()
    , testCase "--help exits with success" $ do
        (_, code) <- fails ["--help"]
        code @?= ExitSuccess
    ]

-- Running --------------------------------------------------------------

runCases :: TestTree
runCases =
  testGroup
    "runCommand"
    [ testCase "add prints the id and nothing else" $
        withOpsEnv $ \_ env -> do
          o <- right =<< runCommand env (Add (MemoryArgs "fact" "claude" Set.empty (BodyText "hi")))
          let out = decodeUtf8 (outBytes o)
          T.isPrefixOf "sha256-" out @?= True
          T.lines out @?= [T.strip out]
          outOk o @?= True
    , testCase "get prints the stored file exactly" $
        withOpsEnv $ \_ env -> do
          o <- right =<< runCommand env (Add (MemoryArgs "fact" "claude" Set.empty (BodyText "body with no line feed")))
          let i = T.strip (decodeUtf8 (outBytes o))
          c <- parses ["get", T.unpack i]
          g <- right =<< runCommand env (cliCommand c)
          T.isSuffixOf "\n\nbody with no line feed" (decodeUtf8 (outBytes g)) @?= True
          (BS.length (outBytes g) > 0) @?= True
    ]
