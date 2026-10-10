{-# LANGUAGE OverloadedStrings #-}

module CLITests (cliTests) where

import Akyuu.CLI
import Akyuu.Error (AkyuuError (..))
import Akyuu.Graph (EdgeType (..))
import Akyuu.Ops (IdSpec (..))
import Akyuu.Id (render)
import Akyuu.Query (SearchOptions (..), defaultSearchOptions)
import Akyuu.Refs (Name, mkName)
import Data.Char (toUpper)
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
            (Add (MemoryArgs "fact" "claude" [(About, Full (nid 1)), (Refines, Full (nid 2))] (BodyText "hi")))
    , testCase "add reads stdin by default" $ do
        c <- parses ["add", "--kind", "fact", "--agent", "claude"]
        c @?= Cli Nothing (Add (MemoryArgs "fact" "claude" [] BodyStdin))
    , testCase "add takes --file" $ do
        c <- parses ["add", "--kind", "fact", "--agent", "claude", "-f", "body.txt"]
        cliCommand c @?= Add (MemoryArgs "fact" "claude" [] (BodyFile "body.txt"))
    , testCase "get by id and by ref" $ do
        n <- name "claude/notes"
        a <- parses ["get", i1]
        b <- parses ["get", "--ref", "claude/notes"]
        (cliCommand a, cliCommand b) @?= (Get (ById (Full (nid 1))), Get (ByRef n))
    , testCase "supersede with --expect" $ do
        n <- name "claude/notes"
        c <- parses ["supersede", "claude/notes", "--expect", i1, "--kind", "fact", "--agent", "claude", "--body", "v2"]
        cliCommand c @?= Supersede n (Just (Full (nid 1))) (MemoryArgs "fact" "claude" [] (BodyText "v2"))
    , testCase "ref set: unchecked, --new and --expect" $ do
        n <- name "a"
        cs <- traverse parses [["ref", "set", "a", i1], ["ref", "set", "a", i1, "--new"], ["ref", "set", "a", i1, "--expect", i2]]
        map cliCommand cs @?= [RefSet n NoCheck (Full (nid 1)), RefSet n MustBeNew (Full (nid 1)), RefSet n (MustBeAt (Full (nid 2))) (Full (nid 1))]
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
    , testCase "an id can be the start of one, with or without sha256-" $ do
        let pre = take 11 i1
            bare = drop 7 pre
        a <- parses ["get", pre]
        b <- parses ["get", bare]
        c <- parses ["get", map toUpper bare]
        let want = Get (ById (Prefix (T.pack pre)))
        map cliCommand [a, b, c] @?= [want, want, want]
    , testCase "a whole id stays a whole id" $ do
        c <- parses ["neighbours", i1]
        cliCommand c @?= Neighbours (Full (nid 1))
    , testCase "an edge option takes a prefix too" $ do
        c <- parses ["add", "--kind", "fact", "--agent", "claude", "--about", take 11 i1, "--body", "x"]
        cliCommand c @?= Add (MemoryArgs "fact" "claude" [(About, Prefix (T.pack (take 11 i1)))] (BodyText "x"))
    , testCase "gc, gc --dry-run, reindex, verify, neighbours" $ do
        cs <- traverse parses [["gc"], ["gc", "--dry-run"], ["reindex"], ["verify"], ["neighbours", i1]]
        map cliCommand cs @?= [GC False, GC True, Reindex, Verify, Neighbours (Full (nid 1))]
    ]

failureCases :: TestTree
failureCases =
  testGroup
    "bad usage"
    [ testCase "a bad id shows the friendly text" $ do
        (msg, code) <- fails ["get", "sha256-zz"]
        assertBool msg ("is not an id or the start of one" `isInfixOf` msg)
        assertBool "not success" (code /= ExitSuccess)
    , testCase "a prefix that is too short is refused" $ do
        (msg, _) <- fails ["get", "sha256-08d"]
        assertBool msg ("the first 4 or more characters" `isInfixOf` msg)
    , testCase "a prefix with a letter that is not hex is refused" $ do
        _ <- fails ["get", "08dg"]
        pure ()
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
          o <- right =<< runCommand env (Add (MemoryArgs "fact" "claude" [] (BodyText "hi")))
          let out = decodeUtf8 (outBytes o)
          T.isPrefixOf "sha256-" out @?= True
          T.lines out @?= [T.strip out]
          outOk o @?= True
    , testCase "get gives the stored file exactly, to a pipe" $
        withOpsEnv $ \_ env -> do
          o <- right =<< runCommand env (Add (MemoryArgs "fact" "claude" [] (BodyText "body with no line feed")))
          let i = T.strip (decodeUtf8 (outBytes o))
          g <- run env ["get", T.unpack i]
          T.isSuffixOf "\n\nbody with no line feed" (decodeUtf8 (terminalBytes False g)) @?= True
          terminalBytes False g @?= outBytes g
    , testCase "get ends the output with a line feed on a terminal" $
        withOpsEnv $ \_ env -> do
          o <- right =<< runCommand env (Add (MemoryArgs "fact" "claude" [] (BodyText "body with no line feed")))
          let i = T.strip (decodeUtf8 (outBytes o))
          g <- run env ["get", T.unpack i]
          T.isSuffixOf "\n\nbody with no line feed\n" (decodeUtf8 (terminalBytes True g)) @?= True
    , testCase "get does not add a second line feed on a terminal" $
        withOpsEnv $ \_ env -> do
          o <- right =<< runCommand env (Add (MemoryArgs "fact" "claude" [] (BodyText "ends with one\n")))
          let i = T.strip (decodeUtf8 (outBytes o))
          g <- run env ["get", T.unpack i]
          T.isSuffixOf "\n\nends with one\n" (decodeUtf8 (terminalBytes True g)) @?= True
    , testCase "only get asks for the line feed" $
        withOpsEnv $ \_ env -> do
          o <- right =<< runCommand env (Add (MemoryArgs "fact" "claude" [] (BodyText "v")))
          l <- run env ["ref", "list"]
          (outEndLine o, outEndLine l) @?= (False, False)
    , testCase "get finds a memory by a prefix of its id" $
        withOpsEnv $ \_ env -> do
          o <- right =<< runCommand env (Add (MemoryArgs "fact" "claude" [] (BodyText "find me")))
          let i = T.strip (decodeUtf8 (outBytes o))
          g <- run env ["get", T.unpack (T.take 12 i)]
          T.isInfixOf "find me" (decodeUtf8 (outBytes g)) @?= True
    , testCase "a prefix that no memory has is an error" $
        withOpsEnv $ \_ env -> do
          _ <- right =<< runCommand env (Add (MemoryArgs "fact" "claude" [] (BodyText "x")))
          c <- parses ["get", "ffffffff"]
          r <- resolveCommand env (cliCommand c)
          r @?= Left (NoSuchPrefix "sha256-ffffffff")
    , testCase "ref list shows the name and the id of each ref" $
        withOpsEnv $ \_ env -> do
          o <- right =<< runCommand env (Add (MemoryArgs "fact" "claude" [] (BodyText "v")))
          let i = T.strip (decodeUtf8 (outBytes o))
          _ <- run env ["ref", "set", "b/x", T.unpack i, "--new"]
          _ <- run env ["ref", "set", "a", T.unpack i, "--new"]
          l <- run env ["ref", "list"]
          T.lines (decodeUtf8 (outBytes l)) @?= ["a  " <> i, "b/x  " <> i]
    , testCase "withNewline adds a line feed only when it is missing" $ do
        (withNewline "", withNewline "a", withNewline "a\n") @?= ("", "a\n", "a\n")
    ]
  where
    -- Parse the arguments, find the ids, and run the command.
    run env args = do
      c <- parses args
      c' <- right =<< resolveCommand env (cliCommand c)
      right =<< runCommand env c'
