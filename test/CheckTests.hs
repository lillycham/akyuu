{-# LANGUAGE OverloadedStrings #-}

module CheckTests (checkTests) where

import Akyuu.Check (CheckOptions (hubDegree), Finding (findingIds, findingKind, findingRelated, findingSeverity), FindingKind (DuplicateBody, Fork, Hub, NearDuplicate, StaleLink, Unreferenced), Inputs (Inputs), Severity (Info, Problem), check, defaultCheckOptions, jaccard, normalise, shingles)
import Akyuu.GC (Roots (Roots, rootPins, rootRefs, rootTemps))
import Akyuu.Graph (Edge (Edge), EdgeType (About, DerivedFrom, Supersedes), Graph, singleton)
import Akyuu.Id (Id)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Support (nid)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))
import Test.Tasty.QuickCheck (testProperty, (===))

checkTests :: TestTree
checkTests =
  testGroup
    "Akyuu.Check"
    [ staleLinkCases,
      forkCases,
      duplicateCases,
      nearCases,
      unreferencedCases,
      hubCases,
      helperCases,
      properties
    ]

-- Helpers --------------------------------------------------------------

a, b, c, d, e :: Id
a = nid 0
b = nid 1
c = nid 2
d = nid 3
e = nid 4

build :: [(Id, [(EdgeType, Id)])] -> Graph
build = foldMap (\(i, es) -> singleton i [Edge k t | (k, t) <- es])

-- Roots with the given refs.
held :: [Id] -> Roots
held is = Roots {rootRefs = Set.fromList is, rootPins = Set.empty, rootTemps = Set.empty}

run :: Graph -> [(Id, Text)] -> [Id] -> [(FindingKind, [Id])]
run g bs hs = [(findingKind x, findingIds x) | x <- check defaultCheckOptions (Inputs g (Map.fromList bs) (held hs))]

kinds :: Graph -> [(Id, Text)] -> [Id] -> [FindingKind]
kinds g bs hs = map fst (run g bs hs)

sentence :: Text
sentence =
  "the quick brown fox jumps over the lazy dog every single morning while the sun comes up over the hills \
  \and the farmer walks out to feed the chickens before breakfast and then goes back inside to read the paper"

-- Detectors ------------------------------------------------------------

staleLinkCases :: TestTree
staleLinkCases =
  testGroup
    "StaleLink"
    [ testCase "a head with a link to an old version is a problem, and names the new one" $ do
        -- b supersedes a. c is about a.
        let g = build [(a, []), (b, [(Supersedes, a)]), (c, [(About, a)])]
            fs = check defaultCheckOptions (Inputs g Map.empty (held [b, c]))
        [(findingKind x, findingSeverity x, findingIds x, findingRelated x) | x <- fs]
          @?= [(StaleLink, Problem, [c, a], [b])],
      testCase "a link to a current memory is fine" $
        kinds (build [(a, []), (c, [(About, a)])]) [] [a, c] @?= [],
      testCase "a link to a deleted memory with a successor is stale" $
        -- a is not a node. b names it with Supersedes, c is about it.
        kinds (build [(b, [(Supersedes, a)]), (c, [(About, a)])]) [] [b, c] @?= [StaleLink],
      testCase "a link to a deleted memory with no successor is not this finding" $
        kinds (build [(c, [(About, a)])]) [] [c] @?= [],
      testCase "a Supersedes edge is not a stale link" $
        kinds (build [(a, []), (b, [(Supersedes, a)])]) [] [b] @?= [],
      testCase "an old version that links to an old version is not reported" $
        -- c is superseded by d, so it is not a head.
        kinds (build [(a, []), (b, [(Supersedes, a)]), (c, [(About, a)]), (d, [(Supersedes, c), (About, b)])]) [] [b, d] @?= []
    ]

forkCases :: TestTree
forkCases =
  testGroup
    "Fork"
    [ testCase "two heads that supersede one memory are a fork" $ do
        let g = build [(a, []), (b, [(Supersedes, a)]), (c, [(Supersedes, a)])]
            fs = check defaultCheckOptions (Inputs g Map.empty (held [b, c]))
        [(findingKind x, findingIds x, findingRelated x) | x <- fs] @?= [(Fork, [a], [b, c])],
      testCase "a chain is not a fork" $
        kinds (build [(a, []), (b, [(Supersedes, a)]), (c, [(Supersedes, b)])]) [] [c] @?= [],
      testCase "a fork of a deleted memory is found" $
        kinds (build [(b, [(Supersedes, a)]), (c, [(Supersedes, a)])]) [] [b, c] @?= [Fork],
      testCase "a fork that one later memory joins is not a fork any more" $
        kinds (build [(a, []), (b, [(Supersedes, a)]), (c, [(Supersedes, a)]), (d, [(Supersedes, b), (Supersedes, c)])]) [] [d] @?= []
    ]

duplicateCases :: TestTree
duplicateCases =
  testGroup
    "DuplicateBody"
    [ testCase "the same text apart from white space and case is a duplicate" $
        run (build [(a, []), (b, [])]) [(a, "Hello   World\n"), (b, "hello world")] [a, b]
          @?= [(DuplicateBody, [a, b])],
      testCase "different texts are not duplicates" $
        kinds (build [(a, []), (b, [])]) [(a, "one"), (b, "two")] [a, b] @?= [],
      testCase "old and new version of one text are not duplicates" $
        kinds (build [(a, []), (b, [(Supersedes, a)])]) [(a, "same"), (b, "same")] [b] @?= [],
      testCase "an old version is not a candidate, only the heads" $
        -- a is superseded by c. b has the text of a.
        kinds (build [(a, []), (b, []), (c, [(Supersedes, a)])]) [(a, "same"), (b, "same"), (c, "other")] [b, c] @?= [],
      testCase "three copies are one finding" $
        run (build [(a, []), (b, []), (c, [])]) [(a, "x y"), (b, "x y"), (c, "X  Y")] [a, b, c]
          @?= [(DuplicateBody, [a, b, c])]
    ]

nearCases :: TestTree
nearCases =
  testGroup
    "NearDuplicate"
    [ testCase "a text with one more sentence is a near duplicate" $
        kinds
          (build [(a, []), (b, [])])
          [(a, sentence), (b, sentence <> " and then it sleeps")]
          [a, b]
          @?= [NearDuplicate],
      testCase "an unrelated text is not" $
        kinds
          (build [(a, []), (b, [])])
          [(a, sentence), (b, "Pack my box with five dozen liquor jugs and send it away today")]
          [a, b]
          @?= [],
      testCase "identical texts are a duplicate and not a near duplicate" $
        kinds (build [(a, []), (b, [])]) [(a, sentence), (b, sentence)] [a, b] @?= [DuplicateBody],
      testCase "two heads of one fork are not reported as near duplicates" $
        -- c and d both supersede a: one line of versions.
        kinds
          (build [(a, []), (c, [(Supersedes, a)]), (d, [(Supersedes, a)])])
          [(a, "old"), (c, sentence), (d, sentence <> " and then it sleeps")]
          [c, d]
          @?= [Fork],
      testCase "a short text is skipped" $
        kinds (build [(a, []), (b, [])]) [(a, "one two three"), (b, "one two three four")] [a, b] @?= [],
      testCase "the ultrakill case: an unlinked copy of the current memory" $
        -- e is an old import of the topic. c is the current head. a was superseded by c.
        let g = build [(a, []), (c, [(Supersedes, a)]), (e, [])]
            long = sentence
         in kinds g [(a, long), (c, long <> " do not commit game data"), (e, long)] [c]
              @?= [NearDuplicate, Unreferenced]
    ]

unreferencedCases :: TestTree
unreferencedCases =
  testGroup
    "Unreferenced"
    [ testCase "a head under a ref is kept" $
        kinds (build [(a, [])]) [] [a] @?= [],
      testCase "a head that nothing keeps is reported" $
        run (build [(a, [])]) [] [] @?= [(Unreferenced, [a])],
      testCase "a head that a live memory links to is kept" $
        kinds (build [(a, []), (b, [(DerivedFrom, a)])]) [] [b] @?= [],
      testCase "a pin keeps a head" $
        check defaultCheckOptions (Inputs (build [(a, [])]) Map.empty (held []) {rootPins = Set.singleton a}) @?= [],
      testCase "an old version is not reported: GC reports it" $
        kinds (build [(a, []), (b, [(Supersedes, a)])]) [] [b] @?= []
    ]

hubCases :: TestTree
hubCases =
  testGroup
    "Hub"
    [ testCase "a memory with more links than the limit is a hub" $ do
        let ms = [nid n | n <- [10 .. 16]]
            g = build ((a, []) : [(m, [(About, a)]) | m <- ms])
            fs = check defaultCheckOptions (Inputs g Map.empty (held (a : ms)))
        [(findingKind x, findingSeverity x, findingIds x) | x <- fs] @?= [(Hub, Info, [a])],
      testCase "a memory at the limit is not" $ do
        let ms = [nid n | n <- [10 .. 14]]
            g = build ((a, []) : [(m, [(About, a)]) | m <- ms])
        kinds g [] (a : ms) @?= [],
      testCase "the limit is an option" $ do
        let g = build [(a, []), (b, [(About, a)]), (c, [(About, a)])]
            fs = check defaultCheckOptions {hubDegree = 1} (Inputs g Map.empty (held [a, b, c]))
        map findingKind fs @?= [Hub]
    ]

-- Helpers and properties -----------------------------------------------

helperCases :: TestTree
helperCases =
  testGroup
    "helpers"
    [ testCase "normalise folds white space and case" $
        normalise "  A\tb \n C " @?= "a b c",
      testCase "shingles are triples of words" $
        shingles "a b c d" @?= Set.fromList ["a b c", "b c d"],
      testCase "a text of two words is one shingle" $
        shingles "a b" @?= Set.singleton "a b",
      testCase "jaccard of equal sets is 1 and of disjoint sets is 0" $ do
        jaccard (Set.fromList [1 :: Int, 2]) (Set.fromList [1, 2]) @?= 1
        jaccard (Set.fromList [1 :: Int]) (Set.fromList [2]) @?= 0
        jaccard (Set.empty :: Set.Set Int) Set.empty @?= 0
    ]

properties :: TestTree
properties =
  testGroup
    "properties"
    [ testProperty "check does not depend on the order of the inputs" $ \xs ->
        let ids = [nid (n `mod` 8) | n <- xs :: [Int]]
            g = foldMap (\i -> build [(i, [(About, nid ((fromEnum (show i /= "")) + 1))])]) ids
            bodies = Map.fromList [(i, sentence) | i <- ids]
         in check defaultCheckOptions (Inputs g bodies (held ids))
              === check defaultCheckOptions (Inputs g bodies (held (reverse ids)))
    ]
