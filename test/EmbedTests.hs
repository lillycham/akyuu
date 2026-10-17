{-# LANGUAGE OverloadedStrings #-}

module EmbedTests (embedTests) where

import Akyuu.Config (Config (cfgEmbed), EmbedSettings (esCommand, esCommandEnv, esKey, esQueryPrefix), loadConfig)
import Akyuu.Embed (Embedder (Embedder, embArgs, embDocumentPrefix, embQueryPrefix, embTimeout), Role (Document, QueryText), chunkText, closeVectors, cosine, decodeVector, encodeVector, fingerprint, fuse, loadVectors, openVectors, parseVector, pruneVectors, putVectors, rankBySimilarity, recordFingerprint, runEmbedder, storedFingerprint)
import Akyuu.Embed qualified
import Akyuu.Ops (EmbedReport (embedChanged, embedded), SearchMode (MeaningOnly, TextOnly), addMemory, embedMissing, searchMemoriesMode)
import Akyuu.Query (Match (matchId), SearchResult (corrections, matches), defaultSearchOptions)
import Akyuu.SearchEval (Case (Case, caseCategory, caseExpect, caseGuess, caseQuery), parseCases, passes)
import Control.Exception (bracket_)
import Data.Either (isLeft)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (diffUTCTime, getCurrentTime)
import OpsTests (note, withOpsEnv)
import Support (nid, right)
import System.Environment (getEnvironment, setEnv, unsetEnv)
import System.FilePath ((</>))
import Test.Tasty (DependencyType (AllFinish), TestTree, dependentTestGroup, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

embedTests :: TestTree
embedTests =
  testGroup
    "Akyuu.Embed"
    [ pureCases,
      evalSetCases,
      commandCases,
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
