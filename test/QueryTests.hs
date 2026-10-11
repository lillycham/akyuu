{-# LANGUAGE OverloadedStrings #-}

module QueryTests (queryTests) where

import Akyuu.Cache (Hit (Hit, hitId), closeCache, index, openCache)
import Akyuu.Graph (Dir (In, Out), Edge (Edge), EdgeType (About, DerivedFrom, Refines, Supersedes), Graph, predecessors, singleton, successors, withinHops)
import Akyuu.Id (Id)
import Akyuu.Memory (Memory (Memory, memAgent, memBody, memCreated, memEdges, memKind))
import Akyuu.Query (Match (matchId, matchSnippet, matchSupersededBy), Neighbour (Neighbour, neighbourDir, neighbourId, neighbourKind), SearchOptions (SearchOptions, searchFollow, searchHops, searchLimit), SearchResult (SearchResult, context, matches), defaultSearchOptions, headsFirst, neighbourList, neighbours, search, searchResult)
import Akyuu.Store (add, openStore)
import Control.Exception (bracket)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import Support (nid, right, withTempDir)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))
import Test.Tasty.QuickCheck (Gen, Property, Testable, chooseInt, conjoin, counterexample, elements, forAll, listOf, sublistOf, testProperty, (===))

queryTests :: TestTree
queryTests =
  testGroup
    "Akyuu.Query"
    [ searchResultCases,
      headsFirstCases,
      neighbourCases,
      properties,
      ioCases
    ]

-- Helpers --------------------------------------------------------------

a, b, c, d, x :: Id
a = nid 0
b = nid 1
c = nid 2
d = nid 3
x = nid 9 -- never a node

build :: [(Id, [(EdgeType, Id)])] -> Graph
build = foldMap (\(i, es) -> singleton i [Edge k t | (k, t) <- es])

-- d about c, c derived-from b, b supersedes a.
line :: Graph
line = build [(a, []), (b, [(Supersedes, a)]), (c, [(DerivedFrom, b)]), (d, [(About, c)])]

hit :: Id -> Hit
hit i = Hit i "snippet"

hops :: Int -> SearchOptions
hops n = defaultSearchOptions {searchHops = n}

-- searchResult ---------------------------------------------------------

searchResultCases :: TestTree
searchResultCases =
  testGroup
    "searchResult"
    [ testCase "with 0 hops, the context is empty" $
        context (searchResult (hops 0) line [hit c]) @?= Set.empty,
      testCase "with 1 hop, the context holds the memories one edge away" $
        context (searchResult (hops 1) line [hit c]) @?= Set.fromList [b, d],
      testCase "with 2 hops, the context reaches two edges away" $
        context (searchResult (hops 2) line [hit d]) @?= Set.fromList [b, c],
      testCase "the context does not hold a hit" $
        context (searchResult (hops 1) line [hit b, hit c]) @?= Set.fromList [a, d],
      testCase "the context follows only the chosen kinds" $
        let o = (hops 3) {searchFollow = Set.fromList [About, DerivedFrom]}
         in context (searchResult o line [hit d]) @?= Set.fromList [b, c],
      testCase "keeps the order and the snippets of the hits" $
        map (\m -> (matchId m, matchSnippet m)) (matches (searchResult (hops 1) line [Hit c "one", Hit a "two"]))
          @?= [(c, "one"), (a, "two")],
      testCase "marks a hit that a newer memory supersedes" $
        map matchSupersededBy (matches (searchResult (hops 0) line [hit a, hit b]))
          @?= [Set.singleton b, Set.empty],
      testCase "shows a fork: two memories supersede one" $
        let g = line <> build [(x, [(Supersedes, a)])]
         in map matchSupersededBy (matches (searchResult (hops 0) g [hit a])) @?= [Set.fromList [b, x]],
      testCase "no hits give an empty result" $
        searchResult (hops 2) line [] @?= SearchResult [] Set.empty,
      testCase "the context can hold a dangling target" $
        let g = build [(a, [(About, x)])]
         in context (searchResult (hops 1) g [hit a]) @?= Set.singleton x
    ]

-- headsFirst -----------------------------------------------------------

headsFirstCases :: TestTree
headsFirstCases =
  testGroup
    "headsFirst"
    [ testCase "puts a memory that nothing supersedes before one that is replaced" $
        map hitId (headsFirst line [hit a, hit b]) @?= [b, a],
      testCase "keeps the order inside each group" $
        -- a is replaced by b. c and d are not replaced.
        map hitId (headsFirst line [hit a, hit d, hit b, hit c]) @?= [d, b, c, a],
      testCase "does not change a list that has no old version" $
        map hitId (headsFirst line [hit c, hit d]) @?= [c, d],
      testCase "a hit that is not in the graph counts as current" $
        map hitId (headsFirst line [hit a, hit x]) @?= [x, a],
      testCase "keeps every hit" $
        length (headsFirst line [hit a, hit b, hit c, hit d]) @?= 4
    ]

-- neighbourList --------------------------------------------------------

neighbourCases :: TestTree
neighbourCases =
  testGroup
    "neighbourList"
    [ testCase "shows edges in both directions with their kinds" $
        neighbourList c line
          @?= [Neighbour Out DerivedFrom b, Neighbour In About d],
      testCase "puts Out edges before In edges" $
        neighbourList b line
          @?= [Neighbour Out Supersedes a, Neighbour In DerivedFrom c],
      testCase "a memory with no edges has no neighbours" $
        neighbourList a (build [(a, [])]) @?= [],
      testCase "an Id that is not in the graph has no neighbours" $
        neighbourList x line @?= [],
      testCase "a dangling target shows the edges that point at it" $
        neighbourList x (build [(a, [(Refines, x)])]) @?= [Neighbour In Refines a]
    ]

-- Properties -----------------------------------------------------------

universe :: [Id]
universe = map nid [0 .. 5]

kinds :: [EdgeType]
kinds = [minBound .. maxBound]

genGraph :: Gen Graph
genGraph = build <$> listOf ((,) <$> elements universe <*> listOf ((,) <$> elements kinds <*> elements universe))

genHits :: Gen [Hit]
genHits = map hit . Set.toList . Set.fromList <$> sublistOf universe

genFollow :: Gen (Set EdgeType)
genFollow = Set.fromList <$> sublistOf kinds

forAllCase :: (Testable p) => (Graph -> [Hit] -> Set EdgeType -> p) -> Property
forAllCase f =
  forAll genGraph $ \g ->
    forAll genHits $ \hs ->
      forAll genFollow $ \ks -> f g hs ks

properties :: TestTree
properties =
  testGroup
    "properties"
    [ testProperty "with 0 hops, the neighbourhood is the hits" $
        forAllCase $ \g hs ks ->
          context (searchResult (SearchOptions 10 0 ks) g hs) === Set.empty,
      testProperty "hits and context together are withinHops" $
        forAllCase $ \g hs ks -> forAll (chooseInt (0, 4)) $ \n ->
          let r = searchResult (SearchOptions 10 n ks) g hs
              ids = Set.fromList (map hitId hs)
           in (Set.fromList (map matchId (matches r)) <> context r)
                === withinHops n (`Set.member` ks) ids g,
      testProperty "the context and the hits do not overlap" $
        forAllCase $ \g hs ks -> forAll (chooseInt (0, 4)) $ \n ->
          let r = searchResult (SearchOptions 10 n ks) g hs
           in Set.disjoint (context r) (Set.fromList (map hitId hs)),
      testProperty "one more hop only adds to the context" $
        forAllCase $ \g hs ks -> forAll (chooseInt (0, 4)) $ \n ->
          let near k = context (searchResult (SearchOptions 10 k ks) g hs)
           in near n `Set.isSubsetOf` near (n + 1),
      testProperty "each neighbour edge has the right direction" $
        forAll genGraph $ \g -> forAll (elements (x : universe)) $ \i ->
          conjoin
            [ counterexample (show nb) $ case neighbourDir nb of
                Out -> neighbourId nb `Set.member` successors (neighbourKind nb) i g
                In -> neighbourId nb `Set.member` predecessors (neighbourKind nb) i g
            | nb <- neighbourList i g
            ],
      testProperty "neighbourList lists every successor and predecessor" $
        forAll genGraph $ \g -> forAll (elements universe) $ \i ->
          length (neighbourList i g)
            === sum [Set.size (successors k i g) + Set.size (predecessors k i g) | k <- kinds]
    ]

-- I/O ------------------------------------------------------------------

memWith :: Text -> [Edge] -> Memory
memWith body es =
  Memory
    { memKind = "fact",
      memCreated = posixSecondsToUTCTime 1791201600,
      memAgent = "claude",
      memEdges = Set.fromList es,
      memBody = body
    }

ioCases :: TestTree
ioCases =
  testGroup
    "search and neighbours on a cache"
    [ testCase "search widens a text hit to its neighbours" $
        withTempDir $ \dir -> do
          s <- right =<< openStore dir
          bracket (right =<< openCache dir) closeCache $ \cache -> do
            let m1 = memWith "Lilly prefers Haskell" []
            i1 <- right =<< add s m1
            right =<< index cache i1 m1
            let m2 = memWith "a note on the tooling" [Edge About i1]
            i2 <- right =<< add s m2
            right =<< index cache i2 m2
            r <- right =<< search cache defaultSearchOptions "haskell"
            map matchId (matches r) @?= [i1]
            context r @?= Set.singleton i2
            ns <- right =<< neighbours cache i2
            ns @?= [Neighbour Out About i1],
      testCase "search with no match gives an empty result" $
        withTempDir $ \dir ->
          bracket (right =<< openCache dir) closeCache $ \cache -> do
            r <- right =<< search cache defaultSearchOptions "nothing"
            r @?= SearchResult [] Set.empty,
      testCase "search with a limit of 1 gives the current memory, not the old version" $
        withTempDir $ \dir -> do
          s <- right =<< openStore dir
          bracket (right =<< openCache dir) closeCache $ \cache -> do
            let old = memWith "Lilly prefers Nix" []
            iOld <- right =<< add s old
            right =<< index cache iOld old
            let new = memWith "Lilly prefers Nix, and never Homebrew" [Edge Supersedes iOld]
            iNew <- right =<< add s new
            right =<< index cache iNew new
            r <- right =<< search cache (defaultSearchOptions {searchLimit = 1}) "nix"
            map matchId (matches r) @?= [iNew]
            map matchSupersededBy (matches r) @?= [Set.empty],
      testCase "search keeps an old version if there are not enough current memories" $
        withTempDir $ \dir -> do
          s <- right =<< openStore dir
          bracket (right =<< openCache dir) closeCache $ \cache -> do
            let old = memWith "Lilly prefers Nix" []
            iOld <- right =<< add s old
            right =<< index cache iOld old
            let new = memWith "a replacement without the word" [Edge Supersedes iOld]
            iNew <- right =<< add s new
            right =<< index cache iNew new
            r <- right =<< search cache defaultSearchOptions "nix"
            map matchId (matches r) @?= [iOld]
            map matchSupersededBy (matches r) @?= [Set.singleton iNew]
    ]
