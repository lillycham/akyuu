{-# LANGUAGE OverloadedStrings #-}

module EmbedTests (embedTests) where

import Akyuu.Embed (Embedder (Embedder, embCommand, embModel, embTimeout), Role (Document, QueryText), closeVectors, cosine, decodeVector, embedSettings, encodeVector, fuse, loadVectors, openVectors, parseVector, putVector, rankBySimilarity, runEmbedder)
import Akyuu.Embed qualified
import Akyuu.Ops (EmbedReport (embedded), SearchMode (MeaningOnly, TextOnly), addMemory, embedMissing, searchMemoriesMode)
import Akyuu.Query (Match (matchId), SearchResult (corrections, matches), defaultSearchOptions)
import Akyuu.SearchEval (Case (Case, caseCategory, caseExpect, caseGuess, caseQuery), parseCases, passes)
import Control.Exception (bracket_)
import Data.Either (isLeft)
import Data.Text (Text)
import OpsTests (note, withOpsEnv)
import Support (nid, right)
import System.Environment (setEnv, unsetEnv)
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

fake :: Text -> Embedder
fake c = Embedder c "fake" 5 4000

commandCases :: TestTree
commandCases =
  testGroup
    "the command"
    [ testCase "the text goes in on stdin, the role goes in the environment" $ do
        r <- runEmbedder (fake "if [ \"$AKYUU_EMBED_ROLE\" = query ]; then echo '[9]'; else printf '[%s]' $(wc -c); fi") Document "abcd"
        r @?= Right [4]
        q <- runEmbedder (fake "if [ \"$AKYUU_EMBED_ROLE\" = query ]; then echo '[9]'; fi") QueryText "x"
        q @?= Right [9],
      testCase "a failing command is a Left, not an exception" $ do
        r <- runEmbedder (fake "exit 3") Document "x"
        assertBool "left" (isLeft r)
        r2 <- runEmbedder (fake "no-such-command-akyuu") Document "x"
        assertBool "left" (isLeft r2),
      testCase "a command that takes too long is a Left" $ do
        r <- runEmbedder ((fake "sleep 5; echo '[1]'") {embTimeout = 1}) Document "x"
        assertBool "timeout" (isLeft r)
    ]

tableCases :: TestTree
tableCases =
  testGroup
    "the table"
    [ testCase "a vector is kept for its model only" $
        withOpsEnv $ \dir _ -> do
          vs <- right =<< openVectors (dir </> "embeddings.sqlite")
          putVector vs "m1" (nid 1) [1, 2]
          putVector vs "m2" (nid 1) [3]
          putVector vs "m1" (nid 1) [5, 6]
          loadVectors vs "m1" >>= (@?= [(nid 1, [5, 6])])
          loadVectors vs "m2" >>= (@?= [(nid 1, [3])])
          closeVectors vs
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
      testCase "settings come from a config file, and the environment wins" $
        withOpsEnv $ \dir _ -> do
          let file = dir </> "embed.env"
          writeFile file "# a comment\nAKYUU_EMBED_COMMAND=cat\nAKYUU_EMBED_QUERY_PREFIX=search_query: \nAKYUU_EMBED_MODEL=from-file\n"
          setEnv "AKYUU_CONFIG" file
          setEnv "AKYUU_EMBED_MODEL" "from-env"
          s <- embedSettings
          e <- Akyuu.Embed.embedderFromEnv
          setEnv "AKYUU_CONFIG" "/nonexistent/akyuu-embed.env"
          unsetEnv "AKYUU_EMBED_MODEL"
          lookup "AKYUU_EMBED_QUERY_PREFIX" s @?= Just "search_query: "
          fmap (\x -> (embCommand x, embModel x)) e @?= Just ("cat", "from-env"),
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
    embedderNow = Akyuu.Embed.embedderFromEnv
