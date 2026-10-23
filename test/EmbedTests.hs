{-# LANGUAGE OverloadedStrings #-}

module EmbedTests (embedTests) where

import Akyuu.Config (Config (cfgEmbed), EmbedSettings (esCommand, esCommandEnv, esKey, esQueryPrefix), loadConfig)
import Akyuu.Embed (Embedder (Embedder, embArgs, embDocumentPrefix, embMaxChars, embQueryPrefix, embTimeout), Role (Document, QueryText), chunkText, closeVectors, cosine, decodeVector, encodeVector, fingerprint, fuse, loadVectors, openVectors, parseVector, pruneVectors, putVectors, rankBySimilarity, recordFingerprint, runEmbedder, storedFingerprint)
import Akyuu.Embed qualified
import Akyuu.Ops (EmbedReport (embedChanged, embedded), SearchMode (MeaningOnly, TextOnly), addMemory, embedMissing, searchMemoriesMode)
import Akyuu.Query (Match (matchId), SearchResult (corrections, matches), defaultSearchOptions)
import Akyuu.SearchEval (Case (Case, caseCategory, caseExpect, caseGuess, caseQuery), parseCases, passes)
import Control.Concurrent (forkFinally, killThread, threadDelay)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (AsyncException (ThreadKilled), bracket, bracket_, fromException)
import Control.Monad (unless)
import Data.Either (isLeft)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (diffUTCTime, getCurrentTime)
import Database.SQLite.Simple (execute_, withConnection)
import OpsTests (note, withOpsEnv)
import Support (nid, right, withTempDir)
import System.Directory (doesFileExist)
import System.Environment (getEnvironment, setEnv, unsetEnv)
import System.FilePath ((</>))
import System.Timeout (timeout)
import Test.Tasty (DependencyType (AllFinish), TestTree, dependentTestGroup, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

embedTests :: TestTree
embedTests =
  testGroup
    "Akyuu.Embed"
    [ pureCases,
      evalSetCases,
      commandCases,
      optionalCases,
      tableCases,
      chunkCases,
      searchCases
    ]

pureCases :: TestTree
pureCases =
  testGroup
    "vectors"
    [ testCase "cosine of the same direction is 1, of a right angle 0, of nothing 0" $ do
        abs (cosine [1, 2, 3] [2, 4, 6] - 1) < 1e-9 @?= True
        cosine [1, 0] [0, 1] @?= 0
        cosine [0, 0] [1, 1] @?= 0
        cosine [1, 0] [1, 0, 0] @?= 0,
      testCase "a vector survives encode and decode" $
        decodeVector (encodeVector [0.5, -1.25, 3, 1e-3]) @?= Just [0.5, -1.25, 3, 1e-3],
      testCase "bytes of the wrong length are no vector" $
        decodeVector "abc" @?= Nothing,
      testCase "four output shapes are read" $ do
        parseVector "[1, 2.5]" @?= Right [1, 2.5]
        parseVector "{\"embedding\": [1, 2]}" @?= Right [1, 2]
        parseVector "{\"embeddings\": [[3, 4]]}" @?= Right [3, 4]
        parseVector "{\"data\": [{\"embedding\": [5, 6], \"index\": 0}], \"model\": \"m\"}" @?= Right [5, 6],
      testCase "output that is not a vector is an error" $ do
        assertBool "not json" (isLeft (parseVector "hello"))
        assertBool "empty" (isLeft (parseVector "[]"))
        assertBool "words" (isLeft (parseVector "[\"a\"]"))
        assertBool "object" (isLeft (parseVector "{\"x\": 1}")),
      testCase "similarity ranks the nearest first and leaves out other lengths" $
        map fst (rankBySimilarity [1, 0] [(nid 1, [0, 1]), (nid 2, [1, 0.1]), (nid 3, [1, 0, 0])]) @?= [nid 2, nid 1],
      testCase "fusion puts what both lists have first" $
        fuse [[nid 1, nid 2, nid 3], [nid 3, nid 4, nid 1]] @?= [nid 1, nid 3, nid 2, nid 4]
    ]

evalSetCases :: TestTree
evalSetCases =
  testGroup
    "search set"
    [ testCase "lines are read, notes and guesses are marked" $ do
        let cs = parseCases "Some notes.\nexact | a b => x/y\nparaphrase | c d => p/q r/s (?)\nnone | e =>\nnot a case\n"
        map caseCategory cs @?= ["exact", "paraphrase", "none"]
        map caseExpect cs @?= [["x/y"], ["p/q", "r/s"], []]
        map caseGuess cs @?= [False, True, False]
        map caseQuery cs @?= ["a b", "c d", "e"],
      testCase "a case passes when an expected ref is found, or when none is expected and nothing is found" $ do
        let c = Case "exact" "q" ["x", "y"] False
            n = Case "none" "q" [] False
        passes c ["z", "y"] @?= True
        passes c ["z"] @?= False
        passes n [] @?= True
        passes n ["z"] @?= False
    ]

-- An embedder for a shell command, with the environment of the tests (the
-- command needs PATH).
fake :: Text -> IO Embedder
fake c = (\env -> Embedder c "fake" 5 4000 "" "" Nothing [] env "test") <$> getEnvironment

-- Run a fake command.
runFake :: Text -> Role -> Text -> IO (Either Text [Float])
runFake c role t = fake c >>= \e -> runEmbedder e role t

commandCases :: TestTree
commandCases =
  testGroup
    "the command"
    [ testCase "the text goes in on stdin, the role goes in the environment" $ do
        r <- runFake "if [ \"$AKYUU_EMBED_ROLE\" = query ]; then echo '[9]'; else printf '[%s]' $(wc -c); fi" Document "abcd"
        r @?= Right [4]
        q <- runFake "if [ \"$AKYUU_EMBED_ROLE\" = query ]; then echo '[9]'; fi" QueryText "x"
        q @?= Right [9],
      testCase "akyuu puts the prefix of the role before the text" $ do
        e <- (\x -> x {embQueryPrefix = "q: ", embDocumentPrefix = "document: "}) <$> fake "printf '[%s]' $(wc -c)"
        d <- runEmbedder e Document "abcd"
        d @?= Right [14]
        q <- runEmbedder e QueryText "abcd"
        q @?= Right [7],
      testCase "a failing command is a Left, not an exception" $ do
        r <- runFake "exit 3" Document "x"
        assertBool "left" (isLeft r)
        r2 <- runFake "no-such-command-akyuu" Document "x"
        assertBool "left" (isLeft r2),
      testCase "a timeout stops the children of the command too" $ do
        t0 <- getCurrentTime
        e <- (\x -> x {embTimeout = 1}) <$> fake "sleep 20 | cat; echo '[1]'"
        r <- runEmbedder e Document "x"
        t1 <- getCurrentTime
        assertBool "timeout" (isLeft r)
        assertBool "returns soon, not when the child ends" (diffUTCTime t1 t0 < 10),
      testCase "a command that takes too long is a Left" $ do
        e <- (\x -> x {embTimeout = 1}) <$> fake "sleep 5; echo '[1]'"
        r <- runEmbedder e Document "x"
        assertBool "timeout" (isLeft r),
      testCase "an outer timeout cancels a command even after its stdout closes" $ do
        e <- (\x -> x {embTimeout = 10}) <$> fake "exec 1>&-; sleep 2"
        r <- timeout 100000 (runEmbedder e Document "x")
        r @?= Nothing,
      testCase "a successful command can leave a persistent model process running" $
        withTempDir $ \dir -> do
          let pid = dir </> "pid"
              alive = dir </> "alive"
              command =
                "(sleep 0.2; printf alive > "
                  <> shellQuote alive
                  <> "; exec sleep 20) </dev/null >/dev/null 2>&1 & printf '%s' \"$!\" > "
                  <> shellQuote pid
                  <> "; echo '[1]'"
              cleanup = do
                _ <- runFake ("kill -KILL $(cat " <> shellQuote pid <> ") 2>/dev/null; echo '[1]'") Document ""
                pure ()
          e <- fake command
          bracket_ (pure ()) cleanup $ do
            runEmbedder e Document "x" >>= (@?= Right [1])
            awaitFile alive
            readFile alive >>= (@?= "alive"),
      testCase "a failed command still stops its detached-stdio background children" $
        withTempDir $ \dir -> do
          let survived = dir </> "survived"
              command =
                "(sleep 1; printf survived > "
                  <> shellQuote survived
                  <> ") </dev/null >/dev/null 2>&1 & exit 3"
          e <- fake command
          r <- runEmbedder e Document "x"
          assertBool "the command failed" (isLeft r)
          threadDelay 1200000
          doesFileExist survived >>= (@?= False),
      testCase "cancellation kills children that ignore TERM and propagates to the caller" $
        withTempDir $ \dir -> do
          let ready = dir </> "ready"
              survived = dir </> "survived"
              command =
                "trap '' TERM; (sleep 1; printf survived > "
                  <> shellQuote survived
                  <> ") & printf ready > "
                  <> shellQuote ready
                  <> "; wait"
          e <- (\x -> x {embTimeout = 10}) <$> fake command
          done <- newEmptyMVar
          bracket (forkFinally (runEmbedder e Document "x") (putMVar done)) killThread $ \tid -> do
            awaitFile ready
            t0 <- getCurrentTime
            killThread tid
            result <- timeout 1000000 (takeMVar done)
            t1 <- getCurrentTime
            case result of
              Just (Left ex) -> fromException ex @?= Just ThreadKilled
              _ -> assertFailure ("cancellation did not propagate: " ++ show result)
            assertBool "cleanup is bounded" (diffUTCTime t1 t0 < 1)
          threadDelay 1200000
          doesFileExist survived >>= (@?= False),
      testCase "the fingerprint leaves out the hashes of Nix store paths" $ do
        a <- fake "/nix/store/0123456789abcdfghijklmnpqrsvwxyz-akyuu-embed-llama/bin/akyuu-embed-llama"
        b <- fake "/nix/store/zyxwvsrqpnmlkjihgfdcba9876543210-akyuu-embed-llama/bin/akyuu-embed-llama"
        fingerprint a @?= fingerprint b,
      testCase "the fingerprint changes with a prefix or an argument" $ do
        a <- fake "akyuu-embed-llama"
        fingerprint a == fingerprint a {embQueryPrefix = "search_query: "} @?= False
        fingerprint a == fingerprint a {embArgs = [("gguf", "/models/b.gguf")]} @?= False
        fingerprint a {embArgs = [("a", "1"), ("b", "2")]} @?= fingerprint a {embArgs = [("b", "2"), ("a", "1")]}
    ]

tableCases :: TestTree
tableCases =
  testGroup
    "the table"
    [ testCase "a vector is kept for its model only" $
        withOpsEnv $ \dir _ -> do
          vs <- right =<< openVectors (dir </> "embeddings.sqlite")
          putVectors vs "m1" (nid 1) [[1, 2]]
          putVectors vs "m2" (nid 1) [[3]]
          putVectors vs "m1" (nid 1) [[5, 6], [7, 8]]
          loadVectors vs "m1" >>= (@?= [(nid 1, [5, 6]), (nid 1, [7, 8])])
          loadVectors vs "m2" >>= (@?= [(nid 1, [3])])
          closeVectors vs,
      testCase "prune removes other models and memories that are gone" $
        withOpsEnv $ \dir _ -> do
          vs <- right =<< openVectors (dir </> "embeddings.sqlite")
          putVectors vs "m1" (nid 1) [[1]]
          putVectors vs "m1" (nid 2) [[1]]
          putVectors vs "m2" (nid 1) [[1]]
          n <- pruneVectors vs "m1" (Set.singleton (nid 1))
          n @?= 2
          loadVectors vs "m1" >>= (@?= [(nid 1, [1])])
          loadVectors vs "m2" >>= (@?= [])
          closeVectors vs,
      testCase "the first fingerprint of a key stays, and prune keeps only the key in use" $
        withOpsEnv $ \dir _ -> do
          vs <- right =<< openVectors (dir </> "embeddings.sqlite")
          storedFingerprint vs "m1" >>= (@?= Nothing)
          recordFingerprint vs "m1" "first"
          recordFingerprint vs "m1" "second"
          recordFingerprint vs "m2" "other"
          storedFingerprint vs "m1" >>= (@?= Just "first")
          _ <- pruneVectors vs "m1" Set.empty
          storedFingerprint vs "m1" >>= (@?= Just "first")
          storedFingerprint vs "m2" >>= (@?= Nothing)
          closeVectors vs
    ]

chunkCases :: TestTree
chunkCases =
  testGroup
    "chunks"
    [ testCase "a short text is one chunk" $
        chunkText 10 "short" @?= ["short"],
      testCase "a long text is cut at blank lines, and no chunk is too long" $ do
        let t = "aaaa\n\nbbbb\n\ncccc"
        chunkText 10 t @?= ["aaaa\n\nbbbb", "cccc"]
        all ((<= 10) . T.length) (chunkText 10 t) @?= True,
      testCase "a paragraph longer than a chunk is cut" $
        chunkText 4 "abcdefghij" @?= ["abcd", "efgh", "ij"],
      testCase "the best chunk of a memory gives its rank, and it appears once" $
        rankBySimilarity [1, 0] [(nid 1, [0, 1]), (nid 1, [1, 0]), (nid 2, [1, 1])] @?= [(nid 1, 1), (nid 2, cosine [1, 0] [1, 1])]
    ]

-- Shell paths in these tests can contain spaces or apostrophes.
shellQuote :: FilePath -> Text
shellQuote p = "'" <> T.replace "'" "'\\''" (T.pack p) <> "'"

awaitFile :: FilePath -> IO ()
awaitFile path = do
  r <- timeout 2000000 waitForFile
  assertBool "the process marker appeared" (r == Just ())
  where
    waitForFile = do
      exists <- doesFileExist path
      unless exists (threadDelay 10000 >> waitForFile)

optionalCases :: TestTree
optionalCases =
  testGroup
    "optional embeddings"
    [ testCase "the first failed chunk prevents later command invocations" $
        withTempDir $ \dir -> do
          let calls = dir </> "calls"
          e <- (\x -> x {embMaxChars = 4}) <$> fake ("cat >> " <> shellQuote calls <> "; exit 3")
          r <- Akyuu.Embed.embedText e Document "abcdefghijkl"
          assertBool "the memory failed" (isLeft r)
          readFile calls >>= (@?= "abcd"),
      testCase "all chunks share the configured deadline and no partial vectors are stored" $
        withTempDir $ \dir -> do
          let path = dir </> "embeddings.sqlite"
              completed = dir </> "completed"
              command = "cat >/dev/null; sleep 0.4; printf x >> " <> shellQuote completed <> "; echo '[1]'"
          e <- (\x -> x {embTimeout = 1, embMaxChars = 4}) <$> fake command
          t0 <- getCurrentTime
          Akyuu.Embed.embedOptional path e (nid 1) "abcdefghijklmnop"
          t1 <- getCurrentTime
          assertBool "one deadline, not one timeout per chunk" (diffUTCTime t1 t0 < 1.5)
          completedChunks <- readFile completed
          assertBool "some chunks completed but not the memory" (not (null completedChunks) && length completedChunks < 4)
          bracket (right =<< openVectors path) closeVectors $ \vs ->
            loadVectors vs "fake" >>= (@?= []),
      testCase "a longer configured timeout is capped at five seconds for the whole memory" $
        withTempDir $ \dir -> do
          let path = dir </> "embeddings.sqlite"
          e <- (\x -> x {embTimeout = 30, embMaxChars = 1}) <$> fake "cat >/dev/null; sleep 1; echo '[1]'"
          t0 <- getCurrentTime
          Akyuu.Embed.embedOptional path e (nid 3) "abcdefgh"
          t1 <- getCurrentTime
          assertBool "the optional deadline is capped" (diffUTCTime t1 t0 < 5.5)
          bracket (right =<< openVectors path) closeVectors $ \vs ->
            loadVectors vs "fake" >>= (@?= []),
      testCase "explicit embedding retains a separate timeout for each chunk" $ do
        e <- (\x -> x {embTimeout = 1, embMaxChars = 4}) <$> fake "cat >/dev/null; sleep 0.4; echo '[1]'"
        Akyuu.Embed.embedText e Document "abcdefghijkl" >>= (@?= Right [[1], [1], [1]]),
      testCase "vector write contention cannot add a SQLite busy wait to the deadline" $
        withTempDir $ \dir -> do
          let path = dir </> "embeddings.sqlite"
              completed = dir </> "completed"
          bracket (right =<< openVectors path) closeVectors (const (pure ()))
          e <- (\x -> x {embTimeout = 1}) <$> fake ("cat >/dev/null; printf done > " <> shellQuote completed <> "; echo '[1]'")
          withConnection path $ \other ->
            bracket_ (execute_ other "BEGIN IMMEDIATE") (execute_ other "ROLLBACK") $ do
              t0 <- getCurrentTime
              Akyuu.Embed.embedOptional path e (nid 2) "one chunk"
              t1 <- getCurrentTime
              assertBool "contention is bounded by the whole operation" (diffUTCTime t1 t0 < 1.5)
              readFile completed >>= (@?= "done")
          bracket (right =<< openVectors path) closeVectors $ \vs ->
            loadVectors vs "fake" >>= (@?= [])
    ]

-- A command that puts a text with "tea" at [1,0] and the rest at [0,1], and a
-- query always at [1,0].
teaCommand :: String
teaCommand = "if [ \"$AKYUU_EMBED_ROLE\" = query ]; then echo '[1,0]'; elif grep -q tea; then echo '[1,0]'; else echo '[0,1]'; fi"

withFakeModel :: IO a -> IO a
withFakeModel = bracket_ set unset
  where
    set = setEnv "AKYUU_EMBED_COMMAND" teaCommand >> setEnv "AKYUU_EMBED_MODEL" "fake-tea"
    unset = unsetEnv "AKYUU_EMBED_COMMAND" >> unsetEnv "AKYUU_EMBED_MODEL"

searchCases :: TestTree
searchCases =
  -- These tests set an environment variable, so they run one after another.
  dependentTestGroup
    "search by meaning"
    AllFinish
    [ testCase "a memory with no word of the query is found by its meaning" $
        withOpsEnv $ \_ env -> withFakeModel $ do
          a <- right =<< addMemory env (note "Lilly drinks tea every morning" [])
          _ <- right =<< addMemory env (note "The compiler is GHC" [])
          -- The vector of a new memory was made when it was added.
          r <- right =<< searchMemoriesMode env TextOnly defaultSearchOptions "beverage"
          map matchId (matches r) @?= []
          m <- right =<< searchMemoriesMode env MeaningOnly defaultSearchOptions "beverage"
          take 1 (map matchId (matches m)) @?= [a],
      testCase "embed fills what is missing, and does it once" $
        withOpsEnv $ \_ env -> do
          _ <- right =<< addMemory env (note "one tea" [])
          _ <- right =<< addMemory env (note "two" [])
          rep <- withFakeModel $ do
            e <- maybe (assertFailure "no embedder") pure =<< embedderNow
            first <- right =<< embedMissing env e
            second <- right =<< embedMissing env e
            pure (embedded first, embedded second)
          rep @?= (2, 0),
      testCase "an outer deadline cancels explicit embedding through its vector-store action" $
        withOpsEnv $ \dir env -> do
          _ <- right =<< addMemory env (note "one memory" [])
          e <- (\x -> x {embTimeout = 10}) <$> fake "sleep 2; echo '[1]'"
          r <- timeout 100000 (embedMissing env e)
          case r of
            Nothing -> pure ()
            Just _ -> assertFailure "the outer deadline did not cancel embedding"
          bracket (right =<< openVectors (dir </> "embeddings.sqlite")) closeVectors $ \vs ->
            loadVectors vs "fake" >>= (@?= []),
      testCase "the older embed.env still works, and the environment wins over it" $
        withOpsEnv $ \dir _ -> do
          let file = dir </> "embed.env"
          writeFile file "# a comment\nexport AKYUU_EMBED_COMMAND=cat\r\nAKYUU_EMBED_QUERY_PREFIX=search_query: \nAKYUU_EMBED_MODEL=from-file\nAKYUU_EMBED_URL=\"http://x\"\n"
          setEnv "AKYUU_CONFIG" file
          setEnv "AKYUU_EMBED_MODEL" "from-env"
          rc <- loadConfig
          setEnv "AKYUU_CONFIG" "/nonexistent/akyuu-embed.env"
          unsetEnv "AKYUU_EMBED_MODEL"
          es <- either (assertFailure . show) (maybe (assertFailure "no profile") pure . cfgEmbed) rc
          (esCommand es, esKey es, esQueryPrefix es) @?= ("cat", "from-env", "search_query: ")
          lookup "AKYUU_EMBED_URL" (esCommandEnv es) @?= Just "http://x",
      testCase "embed warns when the vectors of a key came from another embedder" $
        withOpsEnv $ \_ env -> do
          _ <- right =<< addMemory env (note "one tea" [])
          e <- withFakeModel (maybe (assertFailure "no embedder") pure =<< embedderNow)
          first <- right =<< embedMissing env e
          again <- right =<< embedMissing env e {embQueryPrefix = "search_query: "}
          (embedChanged first, embedChanged again) @?= (False, True),
      testCase "a command that fails leaves a text search, with a note" $
        withOpsEnv $ \_ env -> do
          _ <- right =<< addMemory env (note "plain text about tea" [])
          setEnv "AKYUU_EMBED_COMMAND" "exit 1"
          r <- right =<< searchMemoriesMode env MeaningOnly defaultSearchOptions "tea"
          unsetEnv "AKYUU_EMBED_COMMAND"
          length (matches r) @?= 1
          assertBool "has a note" (not (null (corrections r)))
    ]
  where
    embedderNow = Akyuu.Embed.loadEmbedder
