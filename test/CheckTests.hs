{-# LANGUAGE OverloadedStrings #-}

module CheckTests (checkTests) where

import Akyuu.Check (CheckOptions (hubDegree, longLog), Finding (findingIds, findingKind, findingRelated, findingSeverity), FindingKind (DuplicateBody, Fork, Hub, LongLog, MissingRef, NearDuplicate, StaleLink, Unreferenced), Inputs (Inputs), Severity (Info, Problem), check, defaultCheckOptions, findingWhy, jaccard, normalise, shingles)
import Akyuu.GC (Roots (Roots, rootPins, rootRefs, rootTemps))
import Akyuu.Graph (Edge (Edge), EdgeType (About, DerivedFrom, Follows, Refines, Supersedes), Graph, singleton)
import Akyuu.Id (Id)
import Akyuu.Refs (Name, mkName)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
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
      longLogCases,
      episodeCases,
      aboutRefCases,
      reviewedCases,
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

-- | The inputs of a check with no about-ref links and no refs by name.
inputs :: Graph -> Map.Map Id Text -> Roots -> Set.Set (Id, Id) -> Inputs
inputs g bs r v = Inputs g bs r v Map.empty Map.empty

run :: Graph -> [(Id, Text)] -> [Id] -> [(FindingKind, [Id])]
run g bs hs = [(findingKind x, findingIds x) | x <- check defaultCheckOptions (inputs g (Map.fromList bs) (held hs) Set.empty)]

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
            fs = check defaultCheckOptions (inputs g Map.empty (held [b, c]) Set.empty)
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

aboutRefCases :: TestTree
aboutRefCases =
  testGroup
    "about-ref"
    [ testCase "a derived-from edge to an old version is evidence, not a stale link" $
        kinds (build [(a, []), (b, [(Supersedes, a)]), (c, [(DerivedFrom, a)])]) [] [b, c] @?= [],
      testCase "a refines edge to an old version is a stale link" $
        kinds (build [(a, []), (b, [(Supersedes, a)]), (c, [(Refines, a)])]) [] [b, c] @?= [StaleLink],
      testCase "a stale link names the ref that holds the current memory" $ do
        let g = build [(a, []), (b, [(Supersedes, a)]), (c, [(About, a)])]
            fs = check defaultCheckOptions (Inputs g Map.empty (held [b, c]) Set.empty Map.empty (Map.fromList [(ref "me/topic", b), (ref "me/linker", c)]))
        map (T.isInfixOf "about-ref me/topic" . findingWhy) fs @?= [True],
      testCase "a stale link to a memory that no ref holds names no ref" $ do
        let g = build [(a, []), (b, [(Supersedes, a)]), (c, [(About, a)])]
            fs = check defaultCheckOptions (Inputs g Map.empty (held [b, c]) Set.empty Map.empty Map.empty)
        map (T.isInfixOf "about-ref" . findingWhy) fs @?= [False],
      testCase "a link to a ref that does not exist is a problem" $ do
        let g = build [(a, [])]
            fs = check defaultCheckOptions (Inputs g Map.empty (held [a]) Set.empty (Map.singleton a (Set.fromList [ref "me/gone", ref "me/here"])) (Map.singleton (ref "me/here") a))
        [(findingKind x, findingSeverity x, findingIds x) | x <- fs] @?= [(MissingRef, Problem, [a])]
        map (T.isInfixOf "me/gone" . findingWhy) fs @?= [True],
      testCase "a link to a ref that exists is fine" $
        check defaultCheckOptions (Inputs (build [(a, []), (b, [])]) Map.empty (held [a, b]) Set.empty (Map.singleton a (Set.singleton (ref "me/b"))) (Map.singleton (ref "me/b") b)) @?= [],
      testCase "an old version with a missing ref is not reported" $ do
        let g = build [(a, []), (b, [(Supersedes, a)])]
        map findingKind (check defaultCheckOptions (Inputs g Map.empty (held [b]) Set.empty (Map.singleton a (Set.singleton (ref "me/gone"))) Map.empty)) @?= []
    ]
  where
    ref :: Text -> Name
    ref t = either (error . show) id (mkName t)

forkCases :: TestTree
forkCases =
  testGroup
    "Fork"
    [ testCase "two heads that supersede one memory are a fork" $ do
        let g = build [(a, []), (b, [(Supersedes, a)]), (c, [(Supersedes, a)])]
            fs = check defaultCheckOptions (inputs g Map.empty (held [b, c]) Set.empty)
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
        check defaultCheckOptions (inputs (build [(a, [])]) Map.empty (held []) {rootPins = Set.singleton a} Set.empty) @?= [],
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
            fs = check defaultCheckOptions (inputs g Map.empty (held (a : ms)) Set.empty)
        [(findingKind x, findingSeverity x, findingIds x) | x <- fs] @?= [(Hub, Info, [a])],
      testCase "a memory at the limit is not" $ do
        let ms = [nid n | n <- [10 .. 14]]
            g = build ((a, []) : [(m, [(About, a)]) | m <- ms])
        kinds g [] (a : ms) @?= [],
      testCase "the limit is an option" $ do
        let g = build [(a, []), (b, [(About, a)]), (c, [(About, a)])]
            fs = check defaultCheckOptions {hubDegree = 1} (inputs g Map.empty (held [a, b, c]) Set.empty)
        map findingKind fs @?= [Hub]
    ]

longLogCases :: TestTree
longLogCases =
  testGroup
    "LongLog"
    [ testCase "a chain longer than the limit is a long log, named by its newest episode" $ do
        let g = build [(a, []), (b, [(DerivedFrom, a)]), (c, [(DerivedFrom, b)]), (d, [(DerivedFrom, c)])]
            fs = check defaultCheckOptions {longLog = 3} (inputs g Map.empty (held [d]) Set.empty)
        [(findingKind x, findingIds x) | x <- fs] @?= [(LongLog, [d])],
      testCase "a chain at the limit is not long, and an older value of the ref is not counted again" $ do
        let g = build [(a, []), (b, [(DerivedFrom, a)]), (c, [(DerivedFrom, b)])]
        check defaultCheckOptions {longLog = 3} (inputs g Map.empty (held [c, b]) Set.empty) @?= []
        map findingKind (check defaultCheckOptions {longLog = 2} (inputs g Map.empty (held [c, b]) Set.empty)) @?= [LongLog],
      testCase "a chain of follows edges is a log" $ do
        let g = build [(a, []), (b, [(Follows, a)]), (c, [(Follows, b), (DerivedFrom, e)]), (e, [])]
            fs = check defaultCheckOptions {longLog = 2} (inputs g Map.empty (held [c, e]) Set.empty)
        [(findingKind x, findingIds x) | x <- fs] @?= [(LongLog, [c])]
    ]

episodeCases :: TestTree
episodeCases =
  testGroup
    "episodes"
    [ testCase "a stale link from an episode of a follows log is not reported" $
        -- t2 supersedes t1. Episode b of the log c-b-a is about t1.
        kinds (build [(t1, []), (t2, [(Supersedes, t1)]), (a, []), (b, [(Follows, a), (About, t1)]), (c, [(Follows, b)])]) [] [t2, c] @?= [],
      testCase "a stale link from an episode of an old derived_from log is not reported" $
        kinds (build [(t1, []), (t2, [(Supersedes, t1)]), (a, [(About, t1)]), (b, [(DerivedFrom, a)]), (c, [(DerivedFrom, b)])]) [] [t2, c] @?= [],
      testCase "an old chain of two is not a log: it looks like a fact with evidence" $
        kinds (build [(t1, []), (t2, [(Supersedes, t1)]), (a, []), (b, [(DerivedFrom, a), (About, t1)])]) [] [t2, b] @?= [StaleLink],
      testCase "a fact that supersedes is not an episode, though it has one derived_from edge" $
        -- f2 supersedes f1 and comes from episode b of the log b-a.
        kinds (build [(t1, []), (t2, [(Supersedes, t1)]), (a, []), (b, [(DerivedFrom, a)]), (f1, []), (f2, [(Supersedes, f1), (DerivedFrom, b), (About, t1)])]) [] [t2, f2] @?= [StaleLink]
    ]
  where
    t1 = nid 10
    t2 = nid 11
    f1 = nid 12
    f2 = nid 13

-- | Findings with a set of reviewed pairs.
runReviewed :: Graph -> [(Id, Text)] -> [(Id, Id)] -> [FindingKind]
runReviewed g bs rs = [findingKind x | x <- check defaultCheckOptions (inputs g (Map.fromList bs) (held [a, b, c, d]) (Set.fromList rs))]

reviewedCases :: TestTree
reviewedCases =
  testGroup
    "reviewed pairs"
    [ testCase "a reviewed near duplicate is left out" $ do
        let g = build [(a, []), (b, [])]
            bs = [(a, sentence), (b, sentence <> " and then it sleeps")]
        runReviewed g bs [] @?= [NearDuplicate]
        runReviewed g bs [(a, b)] @?= [],
      testCase "a reviewed duplicate is left out" $ do
        let g = build [(a, []), (b, [])]
        runReviewed g [(a, "x y"), (b, "X Y")] [(a, b)] @?= [],
      testCase "a group is left out only when every pair is reviewed" $ do
        let g = build [(a, []), (b, []), (c, [])]
            bs = [(a, "x y"), (b, "x y"), (c, "x y")]
        runReviewed g bs [(a, b)] @?= [DuplicateBody]
        runReviewed g bs [(a, b), (a, c), (b, c)] @?= [],
      testCase "a reviewed fork is left out" $ do
        let g = build [(a, []), (b, [(Supersedes, a)]), (c, [(Supersedes, a)])]
        runReviewed g [] [] @?= [Fork]
        runReviewed g [] [(b, c)] @?= [],
      testCase "a review does not hide a stale link" $ do
        let g = build [(a, []), (b, [(Supersedes, a)]), (c, [(About, a)])]
        runReviewed g [] [(a, c), (b, c)] @?= [StaleLink]
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
         in check defaultCheckOptions (inputs g bodies (held ids) Set.empty)
              === check defaultCheckOptions (inputs g bodies (held (reverse ids)) Set.empty)
    ]
