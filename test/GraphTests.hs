module GraphTests (graphTests) where

import Akyuu.Graph
import Akyuu.Id (Id, fromDigest)
import Control.Exception (evaluate)
import Data.ByteString qualified as BS
import Data.Maybe (fromMaybe)
import Data.Set (Set)
import Data.Set qualified as Set
import System.Timeout (timeout)
import Test.Tasty
import Test.Tasty.HUnit
import Test.Tasty.QuickCheck

graphTests :: TestTree
graphTests =
  testGroup
    "Akyuu.Graph"
    [ constructionTests
    , monoidTests
    , queryTests
    , traversalTests
    , supersessionTests
    , modelTests
    ]

-- A memory is an Id and its edges. The generators use six Ids only, so edges
-- often share a target and a memory often appears twice.
type Memory = (Id, [(EdgeType, Id)])

nid :: Int -> Id
nid n = fromMaybe (error "nid: not 32 bytes") (fromDigest (BS.replicate 32 (fromIntegral n)))

a, b, c, x :: Id
a = nid 0
b = nid 1
c = nid 2
x = nid 3 -- never a node in the hand-built graphs

universe :: [Id]
universe = map nid [0 .. 5]

kinds :: [EdgeType]
kinds = [minBound .. maxBound]

build :: [Memory] -> Graph
build = foldMap (\(i, es) -> singleton i [Edge k t | (k, t) <- es])

-- A chain: b supersedes a, and c supersedes b.
chain :: Graph
chain = build [(a, []), (b, [(Supersedes, a)]), (c, [(Supersedes, b)])]

-- The store cannot make a cycle. The traversals must still survive one.
cycleGraph :: Graph
cycleGraph = build [(a, [(About, b)]), (b, [(About, a)])]

genMemories :: Gen [Memory]
genMemories = listOf ((,) <$> elements universe <*> listOf ((,) <$> elements kinds <*> elements universe))

shrinkMemories :: [Memory] -> [[Memory]]
shrinkMemories = shrinkList (\(i, es) -> [(i, es') | es' <- shrinkList (const []) es])

forMemories :: (Testable p) => ([Memory] -> p) -> Property
forMemories = forAllShrink genMemories shrinkMemories

genRoots :: Gen (Set Id)
genRoots = Set.fromList <$> sublistOf universe

-- Predicates for the traversals, named so that a failure is readable.
genPred :: Gen String
genPred = elements ["all", "no-supersedes", "about-only"]

predOf :: String -> EdgeType -> Bool
predOf "no-supersedes" = (/= Supersedes)
predOf "about-only" = (== About)
predOf _ = const True

-- The reference model: the same answers, from a plain list of edges.
edgesOf :: [Memory] -> [(Id, EdgeType, Id)]
edgesOf ms = [(i, k, t) | (i, es) <- ms, (k, t) <- es]

modelNodes :: [Memory] -> Set Id
modelNodes = Set.fromList . map fst

modelSucc, modelPred :: [Memory] -> EdgeType -> Id -> Set Id
modelSucc ms k n = Set.fromList [t | (i, k', t) <- edgesOf ms, i == n, k' == k]
modelPred ms k n = Set.fromList [i | (i, k', t) <- edgesOf ms, t == n, k' == k]

modelNeighbours :: [Memory] -> Id -> Set (Dir, EdgeType, Id)
modelNeighbours ms n =
  Set.fromList $
    [(Out, k, t) | (i, k, t) <- edgesOf ms, i == n]
      ++ [(In, k, i) | (i, k, t) <- edgesOf ms, t == n]

modelDangling, modelSuperseded, modelHeads :: [Memory] -> Set Id
modelDangling ms = Set.fromList [t | (_, _, t) <- edgesOf ms] `Set.difference` modelNodes ms
modelSuperseded ms = Set.fromList [t | (_, Supersedes, t) <- edgesOf ms] `Set.intersection` modelNodes ms
modelHeads ms = modelNodes ms `Set.difference` modelSuperseded ms

-- One step of a walk: follow every selected edge from the nodes in the set.
stepForward, stepBoth :: (EdgeType -> Bool) -> [Memory] -> Set Id -> Set Id
stepForward p ms s = s <> Set.fromList [t | (i, k, t) <- edgesOf ms, p k, i `Set.member` s]
stepBoth p ms s =
  stepForward p ms s
    <> Set.fromList [i | (i, k, t) <- edgesOf ms, p k, t `Set.member` s]

modelReach :: (EdgeType -> Bool) -> Set Id -> [Memory] -> Set Id
modelReach p roots ms = go roots
  where
    go s = let s' = stepForward p ms s in if s' == s then s else go s'

modelHops :: Int -> (EdgeType -> Bool) -> Set Id -> [Memory] -> Set Id
modelHops n p roots ms = iterate (stepBoth p ms) roots !! n

-- A traversal may or may not list dangling targets. The tests compare only
-- the part of the result that is a node, and check the roots on their own.
onlyNodes :: Graph -> Set Id -> Set Id
onlyNodes g = Set.intersection (nodes g)

constructionTests :: TestTree
constructionTests =
  testGroup
    "singleton and mempty"
    [ testCase "mempty has no nodes" $
        nodes mempty @?= Set.empty
    , testCase "a memory with no edges is a node" $
        nodes (singleton a []) @?= Set.singleton a
    , testCase "a memory with no edges has no neighbours" $
        neighbours a (singleton a []) @?= Set.empty
    , testCase "the target of an edge is not a node" $
        nodes (singleton b [Edge Supersedes a]) @?= Set.singleton b
    , testCase "an edge is visible from both ends" $ do
        successors Supersedes b g @?= Set.singleton a
        predecessors Supersedes a g @?= Set.singleton b
    ]
  where
    g = singleton b [Edge Supersedes a]

monoidTests :: TestTree
monoidTests =
  testGroup
    "Monoid"
    [ testCase "two memories with the same target keep both edges" $
        predecessors About a (build [(b, [(About, a)]), (c, [(About, a)])])
          @?= Set.fromList [b, c]
    , testCase "two graphs of the same memory keep the edges of both" $ do
        let g = singleton b [Edge About a] <> singleton b [Edge Refines c]
        successors About b g @?= Set.singleton a
        successors Refines b g @?= Set.singleton c
    , testCase "a graph that holds a target and a graph that holds its source join up" $ do
        let g = singleton a [] <> singleton b [Edge Supersedes a]
        nodes g @?= Set.fromList [a, b]
        predecessors Supersedes a g @?= Set.singleton b
    , testProperty "mempty is a left and right identity" $ forMemories $ \ms ->
        let g = build ms
         in conjoin [mempty <> g === g, g <> mempty === g]
    , testProperty "<> is associative" $
        forMemories $ \m1 -> forMemories $ \m2 -> forMemories $ \m3 ->
          (build m1 <> build m2) <> build m3 === build m1 <> (build m2 <> build m3)
    , testProperty "the order of the memories does not matter" $ forMemories $ \ms ->
        forAll (shuffle ms) $ \ms' -> build ms' === build ms
    , testProperty "two halves joined are the same as the whole" $ forMemories $ \ms ->
        forAll (choose (0, length ms)) $ \n ->
          build (take n ms) <> build (drop n ms) === build ms
    ]

queryTests :: TestTree
queryTests =
  testGroup
    "queries"
    [ testCase "successors of an unknown node are empty" $
        successors Supersedes x chain @?= Set.empty
    , testCase "predecessors of an unknown node are empty" $
        predecessors Supersedes x chain @?= Set.empty
    , testCase "successors keep only the asked kind" $ do
        let g = build [(b, [(Supersedes, a), (About, c)])]
        successors Supersedes b g @?= Set.singleton a
        successors About b g @?= Set.singleton c
        successors Refines b g @?= Set.empty
    , testCase "predecessors keep only the asked kind" $ do
        let g = build [(b, [(Supersedes, a)]), (c, [(About, a)])]
        predecessors Supersedes a g @?= Set.singleton b
        predecessors About a g @?= Set.singleton c
    , testCase "neighbours tell the direction of each edge" $
        neighbours b chain
          @?= Set.fromList [(Out, Supersedes, a), (In, Supersedes, c)]
    , testCase "an edge to a dangling target shows from the source only" $ do
        let g = build [(b, [(About, x)])]
        neighbours b g @?= Set.singleton (Out, About, x)
        neighbours x g @?= Set.singleton (In, About, b)
    , testProperty "an edge is a successor of its source exactly when its target has it as a predecessor" $
        forMemories $ \ms ->
          let g = build ms
           in conjoin
                [ (y `Set.member` successors k i g) === (i `Set.member` predecessors k y g)
                | k <- kinds
                , i <- universe
                , y <- universe
                ]
    ]

traversalTests :: TestTree
traversalTests =
  testGroup
    "reachable and withinHops"
    [ testCase "reachable follows edges from newer to older only" $ do
        reachable (const True) (Set.singleton c) chain @?= Set.fromList [a, b, c]
        reachable (const True) (Set.singleton a) chain @?= Set.singleton a
    , testCase "reachable does not follow a kind that the predicate rejects" $
        reachable (/= Supersedes) (Set.singleton c) chain @?= Set.singleton c
    , testCase "reachable from no roots is empty" $
        reachable (const True) Set.empty chain @?= Set.empty
    , testCase "reachable stops on a cycle" $ do
        r <- timeout 1000000 (evaluate (Set.size (reachable (const True) (Set.singleton a) cycleGraph)))
        r @?= Just 2
    , testCase "withinHops follows edges in both directions" $ do
        withinHops 1 (const True) (Set.singleton b) chain @?= Set.fromList [a, b, c]
        withinHops 1 (const True) (Set.singleton c) chain @?= Set.fromList [b, c]
        withinHops 2 (const True) (Set.singleton c) chain @?= Set.fromList [a, b, c]
    , testCase "withinHops does not follow a kind that the predicate rejects" $
        withinHops 5 (/= Supersedes) (Set.singleton b) chain @?= Set.singleton b
    , testCase "withinHops stops on a cycle" $ do
        r <- timeout 1000000 (evaluate (Set.size (withinHops 100 (const True) (Set.singleton a) cycleGraph)))
        r @?= Just 2
    , testProperty "reachable includes the roots" $ forMemories $ \ms ->
        forAll genRoots $ \roots -> forAll genPred $ \pn ->
          roots `Set.isSubsetOf` reachable (predOf pn) roots (build ms)
    , testProperty "reachable is closed: a second pass adds nothing" $ forMemories $ \ms ->
        forAll genRoots $ \roots -> forAll genPred $ \pn ->
          let g = build ms
              r = reachable (predOf pn) roots g
           in reachable (predOf pn) r g === r
    , testProperty "withinHops 0 is the roots" $ forMemories $ \ms ->
        forAll genRoots $ \roots -> forAll genPred $ \pn ->
          withinHops 0 (predOf pn) roots (build ms) === roots
    , testProperty "withinHops only grows as the number of hops grows" $ forMemories $ \ms ->
        forAll genRoots $ \roots -> forAll genPred $ \pn -> forAll (choose (0, 4)) $ \n ->
          let g = build ms
           in withinHops n (predOf pn) roots g `Set.isSubsetOf` withinHops (n + 1) (predOf pn) roots g
    ]

supersessionTests :: TestTree
supersessionTests =
  testGroup
    "superseded, heads and dangling"
    [ testCase "in a chain, only the newest memory is a head" $ do
        superseded chain @?= Set.fromList [a, b]
        heads chain @?= Set.singleton c
    , testCase "two memories that supersede the same memory are both heads" $ do
        let g = build [(a, []), (b, [(Supersedes, a)]), (c, [(Supersedes, a)])]
        superseded g @?= Set.singleton a
        heads g @?= Set.fromList [b, c]
    , testCase "an edge of another kind does not supersede" $ do
        let g = build [(a, []), (b, [(About, a), (Refines, a), (DerivedFrom, a)])]
        superseded g @?= Set.empty
        heads g @?= Set.fromList [a, b]
    , testCase "a memory with no edges, and nothing that supersedes it, is a head" $
        heads (singleton a []) @?= Set.singleton a
    , testCase "an empty graph has no heads" $
        heads mempty @?= Set.empty
    , testCase "a pruned target is dangling, and is not a superseded node" $ do
        let g = build [(b, [(Supersedes, x)])]
        dangling g @?= Set.singleton x
        superseded g @?= Set.empty
        heads g @?= Set.singleton b
    , testCase "a complete graph has no dangling targets" $
        dangling chain @?= Set.empty
    , testCase "a target is not dangling when its own memory joins the graph later" $
        dangling (singleton b [Edge About a] <> singleton a []) @?= Set.empty
    ]

modelTests :: TestTree
modelTests =
  testGroup
    "agree with a list model"
    [ testProperty "nodes" $ forMemories $ \ms ->
        nodes (build ms) === modelNodes ms
    , testProperty "successors and predecessors" $ forMemories $ \ms ->
        let g = build ms
         in conjoin
              [ conjoin
                  [ successors k i g === modelSucc ms k i
                  , predecessors k i g === modelPred ms k i
                  ]
              | k <- kinds
              , i <- universe
              ]
    , testProperty "neighbours" $ forMemories $ \ms ->
        let g = build ms
         in conjoin [neighbours i g === modelNeighbours ms i | i <- universe]
    , testProperty "dangling" $ forMemories $ \ms ->
        dangling (build ms) === modelDangling ms
    , testProperty "superseded" $ forMemories $ \ms ->
        superseded (build ms) === modelSuperseded ms
    , testProperty "heads" $ forMemories $ \ms ->
        heads (build ms) === modelHeads ms
    , testProperty "heads and superseded split the nodes" $ forMemories $ \ms ->
        let g = build ms
         in conjoin
              [ heads g `Set.union` superseded g === nodes g
              , Set.null (heads g `Set.intersection` superseded g) === True
              ]
    , testProperty "reachable" $ forMemories $ \ms ->
        forAll genRoots $ \roots -> forAll genPred $ \pn ->
          let g = build ms
              p = predOf pn
           in onlyNodes g (reachable p roots g) === onlyNodes g (modelReach p roots ms)
    , testProperty "withinHops" $ forMemories $ \ms ->
        forAll genRoots $ \roots -> forAll genPred $ \pn -> forAll (choose (0, 4)) $ \n ->
          let g = build ms
              p = predOf pn
           in onlyNodes g (withinHops n p roots g) === onlyNodes g (modelHops n p roots ms)
    ]
