{-# LANGUAGE OverloadedStrings #-}

module CLITests (cliTests) where

import Akyuu.CLI (BodySource (BodyFile, BodyStdin, BodyText), Check (MustBeAt, MustBeNew, NoCheck), CheckArgs (CheckArgs, caJson, caKinds, caOptions, caSeverity, caStrict), Cli (Cli, cliCommand), Command (Add, Append, CheckStore, Compare, Context, GC, Get, Log, Mcp, Neighbours, Pin, Pins, RefGet, RefList, RefSet, Reindex, Review, Reviews, Search, Serve, Supersede, Unpin, Unreview, Verify, Viz), GetTarget (ById, ByRef), MemoryArgs (MemoryArgs), Output (outBytes, outEndLine, outOk), parseCli, resolveCommand, runCommand, terminalBytes, withNewline)
import Akyuu.Check (FindingKind (Fork), Severity (Problem), defaultCheckOptions)
import Akyuu.Check qualified as Check
import Akyuu.Error (AkyuuError (NoSuchPrefix, StoreFailed))
import Akyuu.GC (Policy (Policy, gracePeriod), defaultPolicy)
import Akyuu.Graph (EdgeType (About, DerivedFrom, Refines))
import Akyuu.Id (render)
import Akyuu.Ops (IdSpec (Full, Prefix), SearchMode (Fused))
import Akyuu.Query (SearchOptions (SearchOptions), defaultSearchOptions)
import Akyuu.Refs (Name, mkName)
import Akyuu.Store (StoreError (NotFound))
import Data.Char (toUpper)
import Data.List (isInfixOf)
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Text.Encoding (decodeUtf8)
import OpsTests (withOpsEnv)
import Options.Applicative (ParserResult (CompletionInvoked, Failure, Success), renderFailure)
import Support (nid, right)
import System.Exit (ExitCode (ExitSuccess))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

cliTests :: TestTree
cliTests =
  testGroup
    "Akyuu.CLI"
    [ parseCases,
      failureCases,
      runCases
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
            (Add (MemoryArgs "fact" "claude" [(About, Full (nid 1)), (Refines, Full (nid 2))] (BodyText "hi"))),
      testCase "serve has a default port, and takes --port 0" $ do
        c <- parses ["serve"]
        cliCommand c @?= Serve 7420
        c0 <- parses ["--root", "/s", "serve", "--port", "0"]
        cliCommand c0 @?= Serve 0,
      testCase "serve refuses a port above 65535" $ do
        (msg, _) <- fails ["serve", "--port", "70000"]
        assertBool msg ("at most 65535" `isInfixOf` msg),
      testCase "viz takes no arguments" $ do
        c <- parses ["viz"]
        cliCommand c @?= Viz,
      testCase "add reads stdin by default" $ do
        c <- parses ["add", "--kind", "fact", "--agent", "claude"]
        c @?= Cli Nothing (Add (MemoryArgs "fact" "claude" [] BodyStdin)),
      testCase "add takes --file" $ do
        c <- parses ["add", "--kind", "fact", "--agent", "claude", "-f", "body.txt"]
        cliCommand c @?= Add (MemoryArgs "fact" "claude" [] (BodyFile "body.txt")),
      testCase "get by id and by ref" $ do
        n <- name "claude/notes"
        a <- parses ["get", i1]
        b <- parses ["get", "--ref", "claude/notes"]
        (cliCommand a, cliCommand b) @?= (Get (ById (Full (nid 1))), Get (ByRef n)),
      testCase "supersede with --expect" $ do
        n <- name "claude/notes"
        c <- parses ["supersede", "claude/notes", "--expect", i1, "--kind", "fact", "--agent", "claude", "--body", "v2"]
        cliCommand c @?= Supersede n (Just (Full (nid 1))) (MemoryArgs "fact" "claude" [] (BodyText "v2")),
      testCase "ref set: unchecked, --new and --expect" $ do
        n <- name "a"
        cs <- traverse parses [["ref", "set", "a", i1], ["ref", "set", "a", i1, "--new"], ["ref", "set", "a", i1, "--expect", i2]]
        map cliCommand cs @?= [RefSet n NoCheck (Full (nid 1)), RefSet n MustBeNew (Full (nid 1)), RefSet n (MustBeAt (Full (nid 2))) (Full (nid 1))],
      testCase "ref get --history and ref list" $ do
        n <- name "a"
        a <- parses ["ref", "get", "a", "--history"]
        b <- parses ["ref", "list"]
        (cliCommand a, cliCommand b) @?= (RefGet n True, RefList),
      testCase "search joins the words and keeps the defaults" $ do
        c <- parses ["search", "lilly", "haskell"]
        cliCommand c @?= Search Fused defaultSearchOptions "lilly haskell",
      testCase "search options" $ do
        c <- parses ["search", "-n", "3", "--hops", "0", "--follow", "about", "--follow", "derived-from", "x"]
        cliCommand c @?= Search Fused (SearchOptions 3 0 (Set.fromList [About, DerivedFrom])) "x",
      testCase "an id can be the start of one, with or without sha256-" $ do
        let pre = take 11 i1
            bare = drop 7 pre
        a <- parses ["get", pre]
        b <- parses ["get", bare]
        c <- parses ["get", map toUpper bare]
        let want = Get (ById (Prefix (T.pack pre)))
        map cliCommand [a, b, c] @?= [want, want, want],
      testCase "a whole id stays a whole id" $ do
        c <- parses ["neighbours", i1]
        cliCommand c @?= Neighbours (Full (nid 1)),
      testCase "an edge option takes a prefix too" $ do
        c <- parses ["add", "--kind", "fact", "--agent", "claude", "--about", take 11 i1, "--body", "x"]
        cliCommand c @?= Add (MemoryArgs "fact" "claude" [(About, Prefix (T.pack (take 11 i1)))] (BodyText "x")),
      testCase "mcp takes a policy ref, and the default is none" $ do
        n <- name "team/how-we-remember"
        a <- parses ["mcp", "--policy-ref", "team/how-we-remember"]
        b <- parses ["mcp"]
        (cliCommand a, cliCommand b) @?= (Mcp (Just n) Nothing, Mcp Nothing Nothing),
      testCase "mcp refuses a policy ref that is not a ref name" $ do
        _ <- fails ["mcp", "--policy-ref", "Not A Name"]
        pure (),
      testCase "compare takes two ids and --json" $ do
        a <- parses ["compare", i1, i2]
        b <- parses ["compare", "--json", take 11 i1, i2]
        (cliCommand a, cliCommand b) @?= (Compare (Full (nid 1)) (Full (nid 2)) False, Compare (Prefix (T.pack (take 11 i1))) (Full (nid 2)) True),
      testCase "compare needs two ids" $ do
        _ <- fails ["compare", i1]
        pure (),
      testCase "review takes two ids, an agent and a note" $ do
        c <- parses ["review", i1, i2, "--agent", "claude", "--note", "both true"]
        cliCommand c @?= Review (Full (nid 1)) (Full (nid 2)) "claude" "both true",
      testCase "review needs an agent" $ do
        _ <- fails ["review", i1, i2]
        pure (),
      testCase "unreview and reviews" $ do
        a <- parses ["unreview", i1, i2]
        b <- parses ["reviews"]
        (cliCommand a, cliCommand b) @?= (Unreview (Full (nid 1)) (Full (nid 2)), Reviews),
      testCase "context takes a tier, refs and a manifest" $ do
        a <- parses ["context"]
        n <- name "claude/projects/akyuu"
        m <- name "team/tiers"
        b <- parses ["context", "--tier", "background", "--ref", "claude/projects/akyuu", "--manifest", "team/tiers"]
        (cliCommand a, cliCommand b) @?= (Context Nothing [] Nothing Nothing Nothing Nothing, Context (Just "background") [n] (Just m) Nothing Nothing Nothing),
      testCase "append takes a ref and the fields of add, and log a ref, a limit and --full" $ do
        n <- name "agent/episodes"
        a <- parses ["append", "agent/episodes", "--kind", "episode", "--agent", "claude", "--body", "x"]
        cliCommand a @?= Append n (MemoryArgs "episode" "claude" [] (BodyText "x"))
        l <- parses ["log", "agent/episodes", "-n", "5", "--full"]
        cliCommand l @?= Log n (Just 5) True
        d <- parses ["log", "agent/episodes"]
        cliCommand d @?= Log n Nothing False,
      testCase "gc takes the policy flags" $ do
        c <- parses ["gc", "--dry-run", "--keep-generations", "2", "--grace", "30m", "--trash-ttl", "1d"]
        cliCommand c @?= GC True (Policy 2 1800 86400),
      testCase "gc flags can come in any order, and each one is optional" $ do
        c <- parses ["gc", "--grace", "0s"]
        cliCommand c @?= GC False defaultPolicy {gracePeriod = 0},
      testCase "check takes the options, kinds and level" $ do
        c <- parses ["check", "--kind", "fork", "--severity", "problem", "--strict", "--json", "--near-threshold", "0.5", "--hub-degree", "9"]
        cliCommand c
          @?= CheckStore
            CheckArgs
              { caOptions = defaultCheckOptions {Check.nearThreshold = 0.5, Check.hubDegree = 9},
                caKinds = [Fork],
                caSeverity = Just Problem,
                caStrict = True,
                caJson = True
              },
      testCase "check refuses a threshold above 1" $ do
        _ <- fails ["check", "--near-threshold", "2"]
        pure (),
      testCase "check refuses a kind that does not exist" $ do
        _ <- fails ["check", "--kind", "nope"]
        pure (),
      testCase "pin, unpin and pins" $ do
        cs <- traverse parses [["pin", i1], ["unpin", i2], ["pins"]]
        map cliCommand cs @?= [Pin (Full (nid 1)), Unpin (Full (nid 2)), Pins],
      testCase "pin takes the start of an id" $ do
        c <- parses ["pin", take 11 i1]
        cliCommand c @?= Pin (Prefix (T.pack (take 11 i1))),
      testCase "pin needs an id" $ do
        _ <- fails ["pin"]
        pure (),
      testCase "gc, gc --dry-run, reindex, verify, neighbours" $ do
        cs <- traverse parses [["gc"], ["gc", "--dry-run"], ["reindex"], ["verify"], ["neighbours", i1]]
        map cliCommand cs @?= [GC False defaultPolicy, GC True defaultPolicy, Reindex, Verify, Neighbours (Full (nid 1))]
    ]

failureCases :: TestTree
failureCases =
  testGroup
    "bad usage"
    [ testCase "a bad id shows the friendly text" $ do
        (msg, code) <- fails ["get", "sha256-zz"]
        assertBool msg ("is not an id or the start of one" `isInfixOf` msg)
        assertBool "not success" (code /= ExitSuccess),
      testCase "a prefix that is too short is refused" $ do
        (msg, _) <- fails ["get", "sha256-08d"]
        assertBool msg ("the first 4 or more characters" `isInfixOf` msg),
      testCase "a prefix with a letter that is not hex is refused" $ do
        _ <- fails ["get", "08dg"]
        pure (),
      testCase "a bad ref name shows the friendly text" $ do
        (msg, _) <- fails ["ref", "get", "Bad"]
        assertBool msg ("is not a valid ref name" `isInfixOf` msg),
      testCase "a kind with a space at the end is refused" $ do
        (msg, _) <- fails ["add", "--kind", "fact ", "--agent", "claude"]
        assertBool msg ("is not valid" `isInfixOf` msg),
      testCase "--new and --expect together are refused" $ do
        _ <- fails ["ref", "set", "a", i1, "--new", "--expect", i2]
        pure (),
      testCase "a negative --hops is refused" $ do
        (msg, _) <- fails ["search", "--hops", "-1", "x"]
        assertBool msg ("at least 0" `isInfixOf` msg),
      testCase "an unknown --follow kind is refused" $ do
        (msg, _) <- fails ["search", "--follow", "likes", "x"]
        assertBool msg ("is not a kind of edge" `isInfixOf` msg),
      testCase "a bad duration shows the friendly text" $ do
        (msg, _) <- fails ["gc", "--grace", "30"]
        assertBool msg ("is not a length of time" `isInfixOf` msg),
      testCase "a negative --keep-generations is refused" $ do
        (msg, _) <- fails ["gc", "--keep-generations", "-1"]
        assertBool msg ("at least 0" `isInfixOf` msg),
      testCase "search needs words" $ do
        _ <- fails ["search"]
        pure (),
      testCase "--help exits with success" $ do
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
          outOk o @?= True,
      testCase "get gives the stored file exactly, to a pipe" $
        withOpsEnv $ \_ env -> do
          o <- right =<< runCommand env (Add (MemoryArgs "fact" "claude" [] (BodyText "body with no line feed")))
          let i = T.strip (decodeUtf8 (outBytes o))
          g <- run env ["get", T.unpack i]
          T.isSuffixOf "\n\nbody with no line feed" (decodeUtf8 (terminalBytes False g)) @?= True
          terminalBytes False g @?= outBytes g,
      testCase "get ends the output with a line feed on a terminal" $
        withOpsEnv $ \_ env -> do
          o <- right =<< runCommand env (Add (MemoryArgs "fact" "claude" [] (BodyText "body with no line feed")))
          let i = T.strip (decodeUtf8 (outBytes o))
          g <- run env ["get", T.unpack i]
          T.isSuffixOf "\n\nbody with no line feed\n" (decodeUtf8 (terminalBytes True g)) @?= True,
      testCase "get does not add a second line feed on a terminal" $
        withOpsEnv $ \_ env -> do
          o <- right =<< runCommand env (Add (MemoryArgs "fact" "claude" [] (BodyText "ends with one\n")))
          let i = T.strip (decodeUtf8 (outBytes o))
          g <- run env ["get", T.unpack i]
          T.isSuffixOf "\n\nends with one\n" (decodeUtf8 (terminalBytes True g)) @?= True,
      testCase "only get asks for the line feed" $
        withOpsEnv $ \_ env -> do
          o <- right =<< runCommand env (Add (MemoryArgs "fact" "claude" [] (BodyText "v")))
          l <- run env ["ref", "list"]
          (outEndLine o, outEndLine l) @?= (False, False),
      testCase "get finds a memory by a prefix of its id" $
        withOpsEnv $ \_ env -> do
          o <- right =<< runCommand env (Add (MemoryArgs "fact" "claude" [] (BodyText "find me")))
          let i = T.strip (decodeUtf8 (outBytes o))
          g <- run env ["get", T.unpack (T.take 12 i)]
          T.isInfixOf "find me" (decodeUtf8 (outBytes g)) @?= True,
      testCase "status counts the memories and says what is missing" $
        withOpsEnv $ \_ env -> do
          _ <- right =<< runCommand env (Add (MemoryArgs "fact" "claude" [] (BodyText "x")))
          o <- run env ["status"]
          let ls = T.lines (decodeUtf8 (outBytes o))
          assertBool "count" ("memories: 1, refs: 0, pins: 0" `elem` ls)
          assertBool "policy missing" (any ("policy policy/memory: missing" `T.isPrefixOf`) ls)
          assertBool "no embedding" ("search by meaning: off (AKYUU_EMBED_COMMAND is not set)" `elem` ls),
      testCase "a prefix that no memory has is an error" $
        withOpsEnv $ \_ env -> do
          _ <- right =<< runCommand env (Add (MemoryArgs "fact" "claude" [] (BodyText "x")))
          c <- parses ["get", "ffffffff"]
          r <- resolveCommand env (cliCommand c)
          r @?= Left (NoSuchPrefix "sha256-ffffffff"),
      testCase "ref list shows the name and the id of each ref" $
        withOpsEnv $ \_ env -> do
          o <- right =<< runCommand env (Add (MemoryArgs "fact" "claude" [] (BodyText "v")))
          let i = T.strip (decodeUtf8 (outBytes o))
          _ <- run env ["ref", "set", "b/x", T.unpack i, "--new"]
          _ <- run env ["ref", "set", "a", T.unpack i, "--new"]
          l <- run env ["ref", "list"]
          T.lines (decodeUtf8 (outBytes l)) @?= ["a  " <> i, "b/x  " <> i],
      testCase "check reports a fork, shows it with --json, and --strict fails on it" $
        withOpsEnv $ \_ env -> do
          let add body es = do
                o <- run env (["add", "--kind", "fact", "--agent", "claude", "--body", body] <> es)
                pure (T.strip (decodeUtf8 (outBytes o)))
          old <- add "the old text" []
          let sup = ["--supersedes", T.unpack old]
          _ <- add "new one" sup
          _ <- add "new two" sup
          plain <- run env ["check"]
          T.isInfixOf "[problem] fork:" (decodeUtf8 (outBytes plain)) @?= True
          outOk plain @?= True
          strict <- run env ["check", "--strict"]
          outOk strict @?= False
          json <- run env ["check", "--json", "--kind", "fork"]
          T.isPrefixOf "[{" (decodeUtf8 (outBytes json)) @?= True
          T.isInfixOf "\"kind\":\"fork\"" (decodeUtf8 (outBytes json)) @?= True
          none <- run env ["check", "--strict", "--severity", "problem", "--kind", "hub"]
          outOk none @?= True
          T.lines (decodeUtf8 (outBytes none)) @?= ["No findings."],
      testCase "compare shows the sentence that only one memory has, and the drop guard" $
        withOpsEnv $ \_ env -> do
          let add body = do
                o <- run env ["add", "--kind", "fact", "--agent", "claude", "--body", body]
                pure (T.strip (decodeUtf8 (outBytes o)))
          a <- add "The port is private. Do not commit game data."
          b <- add "The port is private."
          r <- run env ["compare", T.unpack a, T.unpack b]
          let ls = T.lines (decodeUtf8 (outBytes r))
          assertBool "A has its own sentence" ("  - Do not commit game data." `elem` ls)
          assertBool "A cannot be dropped" (any (T.isPrefixOf "A cannot be dropped") ls)
          assertBool "B can be dropped" (any (T.isPrefixOf "B can be dropped") ls)
          j <- run env ["compare", "--json", T.unpack a, T.unpack b]
          T.isInfixOf "\"canDropB\":true" (decodeUtf8 (outBytes j)) @?= True,
      testCase "review hides a near duplicate from check, and unreview shows it again" $
        withOpsEnv $ \_ env -> do
          let add body = do
                o <- run env ["add", "--kind", "fact", "--agent", "claude", "--body", body]
                pure (T.unpack (T.strip (decodeUtf8 (outBytes o))))
              base = "the quick brown fox jumps over the lazy dog every single morning while the sun comes up over the hills and the farmer walks out to feed the chickens"
          a <- add base
          b <- add (base <> " before breakfast")
          before <- run env ["check", "--kind", "near-duplicate"]
          T.isInfixOf "near-duplicate" (decodeUtf8 (outBytes before)) @?= True
          _ <- run env ["review", a, b, "--agent", "claude", "--note", "two notes"]
          hidden <- run env ["check", "--kind", "near-duplicate"]
          T.lines (decodeUtf8 (outBytes hidden)) @?= ["No findings."]
          listed <- run env ["reviews"]
          T.isInfixOf "two notes" (decodeUtf8 (outBytes listed)) @?= True
          _ <- run env ["unreview", b, a]
          again <- run env ["check", "--kind", "near-duplicate"]
          T.isInfixOf "near-duplicate" (decodeUtf8 (outBytes again)) @?= True,
      testCase "context prints the memories of a tier, a missing ref, and the other refs" $
        withOpsEnv $ \_ env -> do
          let add body = do
                o <- run env ["add", "--kind", "fact", "--agent", "claude", "--body", body]
                pure (T.unpack (T.strip (decodeUtf8 (outBytes o))))
          profile <- add "Lilly likes tea."
          other <- add "Notes about boxes."
          manifest <- add "always: me/profile me/missing\n"
          _ <- run env ["ref", "set", "me/profile", profile, "--new"]
          _ <- run env ["ref", "set", "me/boxes", other, "--new"]
          _ <- run env ["ref", "set", "policy/tiers", manifest, "--new"]
          r <- run env ["context"]
          let ls = T.lines (decodeUtf8 (outBytes r))
          take 1 ls @?= ["tier: always"]
          assertBool "has the profile" ("Lilly likes tea." `elem` ls)
          assertBool "names the missing ref" (any (T.isPrefixOf "== me/missing:") ls)
          drop (length ls - 1) ls @?= ["other refs: me/boxes"]
          more <- run env ["context", "--ref", "me/boxes"]
          assertBool "has the extra ref" ("Notes about boxes." `elem` T.lines (decodeUtf8 (outBytes more)))
          unknown <- parses ["context", "--tier", "nope"]
          c <- right =<< resolveCommand env (cliCommand unknown)
          e <- runCommand env c
          assertBool "an unknown tier is an error" (either (const True) (const False) e),
      testCase "append makes a log, and log prints it newest first" $
        withOpsEnv $ \_ env -> do
          let ap t = run env ["append", "agent/episodes", "--kind", "episode", "--agent", "claude", "--body", t]
          _ <- ap "first thing"
          _ <- ap "second thing"
          l <- run env ["log", "agent/episodes"]
          let ls = T.lines (decodeUtf8 (outBytes l))
          length ls @?= 2
          assertBool "newest first" ("second thing" `T.isSuffixOf` (ls !! 0))
          assertBool "then the older" ("first thing" `T.isSuffixOf` (ls !! 1))
          full <- run env ["log", "agent/episodes", "--full", "-n", "1"]
          let fs = T.lines (decodeUtf8 (outBytes full))
          assertBool "the body is indented under the line" ("  second thing" `elem` fs)
          assertBool "says where the log goes on" (any (T.isPrefixOf "more: ") fs),
      testCase "pin, pins and unpin" $
        withOpsEnv $ \_ env -> do
          o <- right =<< runCommand env (Add (MemoryArgs "fact" "claude" [] (BodyText "keep me")))
          let i = T.strip (decodeUtf8 (outBytes o))
          none <- run env ["pins"]
          outBytes none @?= ""
          p <- run env ["pin", T.unpack (T.take 12 i)]
          T.lines (decodeUtf8 (outBytes p)) @?= ["pinned " <> i]
          l <- run env ["pins"]
          T.lines (decodeUtf8 (outBytes l)) @?= [i]
          u <- run env ["unpin", T.unpack i]
          T.lines (decodeUtf8 (outBytes u)) @?= ["unpinned " <> i]
          l2 <- run env ["pins"]
          outBytes l2 @?= "",
      testCase "pin of an id that is not in the store is an error" $
        withOpsEnv $ \_ env -> do
          c <- parses ["pin", i1]
          c' <- right =<< resolveCommand env (cliCommand c)
          r <- runCommand env c'
          r @?= Left (StoreFailed (NotFound (nid 1))),
      testCase "search marks a match with brackets, and a bracket of the body has a backslash" $
        withOpsEnv $ \_ env -> do
          o <- right =<< runCommand env (Add (MemoryArgs "fact" "claude" [] (BodyText "see [x] and Haskell [y]")))
          let i = T.strip (decodeUtf8 (outBytes o))
          s <- run env ["search", "haskell"]
          T.lines (decodeUtf8 (outBytes s)) @?= [i <> "  see \\[x\\] and [Haskell] \\[y\\]"],
      testCase "withNewline adds a line feed only when it is missing" $ do
        (withNewline "", withNewline "a", withNewline "a\n") @?= ("", "a\n", "a\n")
    ]
  where
    -- Parse the arguments, find the ids, and run the command.
    run env args = do
      c <- parses args
      c' <- right =<< resolveCommand env (cliCommand c)
      right =<< runCommand env c'
