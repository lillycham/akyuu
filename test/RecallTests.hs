{-# LANGUAGE OverloadedStrings #-}

-- | Tests of fuzzy search and of the ranking of hits.
module RecallTests (recallTests) where

import Akyuu.Cache (Correction (PrefixOf, SpelledAs), Hit (Hit, hitId), closeCache, createdTimes, index, openCache, searchFuzzy)
import Akyuu.Cache qualified
import Akyuu.Fuzzy (editDistance, maxEdits, nearTerms)
import Akyuu.Id (Id)
import Akyuu.Memory (Memory, memoryId)
import Akyuu.Query (Boost (Boost, boostHeld, boostNow), SearchOptions, SearchResult (corrections, matches), Tuning (Tuning, tuneBoost, tuneFuzzy), defaultSearchOptions, defaultTuning, matchId, noBoost, rankHits, searchWith)
import Control.Exception (bracket)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified
import Data.Time (UTCTime, addUTCTime)
import Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import Support (nid, right, testMemory, withTempDir)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))
import Test.Tasty.QuickCheck (testProperty, (===))

recallTests :: TestTree
recallTests = testGroup "fuzzy search and ranking" [distanceCases, nearCases, cacheCases, rankCases]

-- Helpers --------------------------------------------------------------

t0 :: UTCTime
t0 = posixSecondsToUTCTime 1791201600

mem :: Text -> UTCTime -> Memory
mem body t = testMemory "fact" t "claude" Set.empty body

-- Index these memories in a new cache and give the ids.
withIndexed :: [(Text, UTCTime)] -> (Cache' -> [Id] -> IO a) -> IO a
withIndexed bodies act = withTempDir $ \dir ->
  bracket (right =<< openCache dir) closeCache $ \c -> do
    ids <-
      mapM
        ( \(b, t) -> do
            let m = mem b t
            right =<< index c (memoryId m) m
            pure (memoryId m)
        )
        bodies
    act c ids

type Cache' = Akyuu.Cache.Cache

-- Edit distance --------------------------------------------------------

distanceCases :: TestTree
distanceCases =
  testGroup
    "edit distance"
    [ testCase "equal texts are at distance 0" $ editDistance "haskell" "haskell" @?= 0,
      testCase "one insertion, deletion or substitution is 1" $ do
        editDistance "haskell" "haskel" @?= 1
        editDistance "haskel" "haskell" @?= 1
        editDistance "haskell" "haskall" @?= 1,
      testCase "a swap of two neighbours is 1" $ editDistance "haksell" "haskell" @?= 1,
      testCase "an empty text is the length of the other" $ do
        editDistance "" "abc" @?= 3
        editDistance "abc" "" @?= 3,
      testCase "a different text is far" $ editDistance "kitten" "sitting" @?= 3,
      testProperty "the distance is symmetric" $ \a b -> editDistance (t a) (t b) === editDistance (t b) (t a),
      testProperty "the distance is 0 only for equal texts" $ \a -> editDistance (t a) (t a) === 0,
      testProperty "the distance is at most the longer length" $ \a b ->
        editDistance (t a) (t b) <= max (length a) (length b)
    ]
  where
    t = textOf

textOf :: String -> Text
textOf = fromString'
  where
    fromString' = Data.Text.pack

-- Near terms -----------------------------------------------------------

nearCases :: TestTree
nearCases =
  testGroup
    "near terms"
    [ testCase "a short word gets no corrections" $ maxEdits "nix" @?= 0,
      testCase "a longer word gets one or two" $ do
        maxEdits "nixos" @?= 1
        maxEdits "haskell" @?= 2,
      testCase "a transposition is near, the word itself is not a result" $
        nearTerms 4 "haksell" [("haskel", 3), ("haksell", 1), ("nix", 9)] @?= ["haskel"],
      testCase "the nearest term comes first, then the most used" $ do
        nearTerms 4 "storag" [("storage", 1), ("storags", 5), ("stora", 9)] @?= ["stora", "storags", "storage"]
        nearTerms 4 "haksell" [("a", 9), ("is", 9), ("haskel", 1)] @?= ["haskel"],
      testCase "a stem is near the start of a longer word" $
        nearTerms 4 "derivation" [("deriv", 2)] @?= ["deriv"],
      testCase "a short stem or one with another start is not near a long word" $ do
        nearTerms 4 "persnoa" [("perl", 3)] @?= []
        nearTerms 4 "xerivation" [("deriv", 2)] @?= [],
      testCase "a far term is not near" $ nearTerms 4 "haskell" [("python", 5)] @?= []
    ]

-- Fuzzy search on a cache ---------------------------------------------

cacheCases :: TestTree
cacheCases =
  testGroup
    "searchFuzzy"
    [ testCase "words that exist give the hits of search, and no correction" $
        withIndexed [("Lilly prefers Haskell", t0)] $ \c ids -> do
          (hits, notes) <- right =<< searchFuzzy c "haskell" 10
          map hitId hits @?= ids
          notes @?= [],
      testCase "the start of a word is a prefix" $
        withIndexed [("Lilly prefers Haskell", t0)] $ \c ids -> do
          (hits, notes) <- right =<< searchFuzzy c "hask" 10
          map hitId hits @?= ids
          notes @?= [PrefixOf "hask"],
      testCase "a typing mistake finds the word, and says so" $
        withIndexed [("Lilly prefers Haskell", t0)] $ \c ids -> do
          (hits, notes) <- right =<< searchFuzzy c "haksell" 10
          map hitId hits @?= ids
          case notes of
            [SpelledAs "haksell" ts] -> ts @?= ["haskel"]
            other -> error ("unexpected corrections: " <> show other),
      testCase "every word is still needed" $
        withIndexed [("Lilly prefers Haskell", t0), ("Nix and tea", t0)] $ \c ids -> do
          (hits, _) <- right =<< searchFuzzy c "haksell prefers" 10
          map hitId hits @?= take 1 ids,
      testCase "a word with no near term finds nothing, and changes nothing" $
        withIndexed [("Lilly prefers Haskell", t0)] $ \c _ -> do
          (hits, notes) <- right =<< searchFuzzy c "zzzzzzzz" 10
          hits @?= []
          notes @?= [],
      testCase "a limit of 0 or an empty query gives nothing" $
        withIndexed [("Lilly prefers Haskell", t0)] $ \c _ -> do
          a <- right =<< searchFuzzy c "haskell" 0
          b <- right =<< searchFuzzy c "   " 10
          (a, b) @?= (([], []), ([], [])),
      testCase "createdTimes gives the time of each memory in the cache" $
        withIndexed [("one", t0), ("two", addUTCTime 3600 t0)] $ \c ids -> do
          m <- right =<< createdTimes c ids
          map (`Map.lookup` m) ids @?= [Just t0, Just (addUTCTime 3600 t0)]
          e <- right =<< createdTimes c []
          Map.null e @?= True
    ]

-- Ranking --------------------------------------------------------------

rankCases :: TestTree
rankCases =
  testGroup
    "rankHits"
    [ testCase "no boost keeps the order" $
        rankHits noBoost Map.empty hits @?= hits,
      testCase "a memory that a ref holds moves up one place" $
        map hitId (rankHits (noBoost {boostHeld = Set.singleton (nid 3)}) Map.empty hits) @?= [nid 1, nid 3, nid 2, nid 4],
      testCase "a held memory far down does not jump to the top" $
        map hitId (rankHits (noBoost {boostHeld = Set.singleton (nid 4)}) Map.empty hits) @?= [nid 1, nid 2, nid 4, nid 3],
      testCase "one signal alone does not pass the best match from the next place" $
        map hitId (rankHits (noBoost {boostHeld = Set.singleton (nid 2)}) Map.empty (take 2 hits)) @?= [nid 1, nid 2],
      testCase "a held and new memory passes an old best match from the next place" $
        let created = Map.fromList [(nid 1, addUTCTime (-86400 * 400) now), (nid 2, now)]
         in map hitId (rankHits (Boost {boostNow = Just now, boostHeld = Set.singleton (nid 2)}) created (take 2 hits)) @?= [nid 2, nid 1],
      testCase "the text match is still the main signal" $
        let created = Map.fromList [(nid 1, addUTCTime (-86400 * 3) now), (nid 4, now)]
         in head' (map hitId (rankHits (Boost {boostNow = Just now, boostHeld = Set.empty}) created hits)) @?= nid 1,
      testCase "a search with a boost uses it, and says what it corrected" $
        withTempDir $ \dir ->
          bracket (right =<< openCache dir) closeCache $ \c -> do
            let a = mem "tea is a drink" (addUTCTime (-86400 * 400) t0)
                b = mem "tea and haskell" (addUTCTime 86400 t0)
            right =<< index c (memoryId a) a
            right =<< index c (memoryId b) b
            plain <- right =<< searchWith c defaultTuning defaultSearchOptions "tea"
            boosted <- right =<< searchWith c defaultTuning {tuneBoost = Boost {boostNow = Just (addUTCTime 86400 t0), boostHeld = Set.singleton (memoryId b)}} defaultSearchOptions "tea"
            Set.fromList (map matchId (matches plain)) @?= Set.fromList [memoryId a, memoryId b]
            head' (map matchId (matches boosted)) @?= memoryId b
            typo <- right =<< searchWith c defaultTuning defaultSearchOptions "haksell"
            map matchId (matches typo) @?= [memoryId b]
            length (corrections typo) @?= 1
            off <- right =<< searchWith c defaultTuning {tuneFuzzy = False} defaultSearchOptions "haksell"
            matches off @?= []
    ]
  where
    hits = [Hit (nid n) "" | n <- [1 .. 4]]
    now = addUTCTime (86400 * 100) t0
    head' (x : _) = x
    head' [] = error "no hits"
