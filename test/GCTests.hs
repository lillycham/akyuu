{-# LANGUAGE OverloadedStrings #-}

module GCTests (gcTests) where

import Akyuu.Cache (Cache, cachedIds, closeCache, openCache)
import Akyuu.GC (GCError (CorruptTombstone, GCLocked, GCRefs), Observed (Observed), Policy (Policy, gracePeriod, keepGenerations, trashTTL), Reason (HeldByPin, HeldByRef, HeldByTemp, IsYoung, RetainedBy), Roots (Roots, rootPins, rootRefs, rootTemps), RunReport (planned, swept), SweepReport (SweepReport, deleted, trashed), Tombstone (Tombstone), TombstoneParseError (BadTombstone, TombstoneNotUtf8), Why (Why, whyIsNode, whyLive, whyPath, whyReasons), allRoots, collect, defaultPolicy, dryRun, explain, explainAll, gcLockPath, listPins, listTombstones, listTrash, lookupTombstone, parseTombstone, pin, pinPath, plan, readRoots, recheck, renderTombstone, retains, snapshot, sweep, sweepAndSync, tombstonePath, unpin, withGCLock)
import Akyuu.Graph (Edge (Edge), EdgeType (About, DerivedFrom, Refines, Supersedes), Graph, nodes, reachable, singleton, successors)
import Akyuu.Id (Id)
import Akyuu.Memory (Memory (Memory, memAgent, memBody, memCreated, memEdges, memKind))
import Akyuu.Refs (Expected (Unchecked), RefError (CorruptRef), Refs, mkName, openRefs, refPath, setRef)
import Akyuu.Store (Store, add, objectPath, openStore, trashPath)
import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, readMVar, takeMVar)
import Control.Exception (bracket)
import Control.Monad (forM)
import Data.ByteString qualified as BS
import Data.List (isPrefixOf, sort)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Time (UTCTime, addUTCTime, getCurrentTime, nominalDay)
import Data.Time.Clock.POSIX (posixSecondsToUTCTime, utcTimeToPOSIXSeconds)
import Support (nid, right, withTempDir)
import System.Directory (createDirectoryIfMissing, doesDirectoryExist, doesFileExist, listDirectory, setModificationTime)
import System.FilePath ((</>))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit ((@?=), assertBool, assertFailure, testCase)
import Test.Tasty.QuickCheck ((===), Arbitrary (arbitrary), Gen, Property, Testable (property), choose, conjoin, counterexample, elements, forAll, listOf, sublistOf, testProperty)

gcTests :: TestTree
gcTests =
  testGroup
    "Akyuu.GC"
    [ retainsTests
    , planTests
    , properties
    , explainTests
    , tombstoneTests
    , listingTests
    , pinTests
    , rootTests
    , sweepTests
    , runTests
    ]

-- Pure helpers ---------------------------------------------------------

-- The time of the pure tests.
t0 :: UTCTime
t0 = posixSecondsToUTCTime 1791201600

-- A time well before the grace period of 'pol'.
old :: UTCTime
old = addUTCTime (-nominalDay) t0

-- A time inside the grace period of 'pol'.
fresh :: UTCTime
fresh = addUTCTime (-60) t0

-- A policy with a grace period of one hour.
pol :: Policy
pol =
  Policy
    { keepGenerations = 0
    , gracePeriod = 3600
    , trashTTL = 7 * nominalDay
    }

-- The facts of a run at 't0', with these ages.
obs :: Map Id UTCTime -> Observed
obs = Observed t0

-- Every node of the graph is old.
allOld :: Graph -> Map Id UTCTime
allOld g = Map.fromSet (const old) (nodes g)

build :: [(Id, [(EdgeType, Id)])] -> Graph
build = foldMap (\(i, es) -> singleton i [Edge k t | (k, t) <- es])

roots :: [Id] -> Roots
roots is = Roots {rootRefs = Set.fromList is, rootPins = Set.empty, rootTemps = Set.empty}

noRoots :: Roots
noRoots = roots []

a, b, c, x :: Id
a = nid 0
b = nid 1
c = nid 2
x = nid 3 -- never a node

-- b supersedes a.
pair :: Graph
pair = build [(a, []), (b, [(Supersedes, a)])]

-- Plan with every node old.
planOld :: Roots -> Graph -> Set Id
planOld r g = plan pol (obs (allOld g)) r g

-- retains --------------------------------------------------------------

retainsTests :: TestTree
retainsTests =
  testGroup
    "retains"
    [ testCase "only Supersedes does not retain" $
        [k | k <- [minBound .. maxBound], not (retains k)] @?= [Supersedes]
    ]

-- plan -----------------------------------------------------------------

planTests :: TestTree
planTests =
  testGroup
    "plan"
    [ testCase "collects a superseded memory" $
        planOld (roots [b]) pair @?= Set.singleton a
    , testCase "keeps a retained generation" $
        planOld (roots [a, b]) pair @?= Set.empty
    , testCase "keeps a pin and a temporary root" $ do
        planOld noRoots {rootPins = Set.singleton a} pair @?= Set.singleton b
        planOld noRoots {rootTemps = Set.singleton a} pair @?= Set.singleton b
    , testCase "collects everything if there are no roots" $
        planOld noRoots pair @?= Set.fromList [a, b]
    , testCase "a live memory keeps the target of each retaining edge" $
        let g = build [(a, []), (b, [(Supersedes, a)]), (c, [(About, a)])]
         in planOld (roots [b, c]) g @?= Set.empty
    , testCase "liveness does not flow backwards along an edge" $
        let g = build [(a, []), (b, [(About, a)])]
         in planOld (roots [a]) g @?= Set.singleton b
    , testCase "keeps a young object and what it retains" $
        let g = build [(a, []), (b, [(About, a)])]
            ages = Map.fromList [(a, old), (b, fresh)]
         in plan pol (obs ages) noRoots g @?= Set.empty
    , testCase "collects the same objects when they are old" $
        let g = build [(a, []), (b, [(About, a)])]
         in planOld noRoots g @?= Set.fromList [a, b]
    , testCase "keeps an object with no known age" $
        plan pol (obs (Map.singleton b old)) (roots [b]) pair @?= Set.empty
    , testCase "keeps an object with a time in the future" $
        plan pol (obs (Map.fromList [(a, addUTCTime 60 t0), (b, old)])) (roots [b]) pair
          @?= Set.empty
    , testCase "ignores a root and a target that are not nodes" $
        let g = build [(a, []), (b, [(About, x)]), (c, [(Supersedes, x)])]
         in planOld (roots [x, b]) g @?= Set.fromList [a, c]
    , testCase "an empty graph gives an empty plan" $
        planOld (roots [a]) mempty @?= Set.empty
    ]

-- Properties -----------------------------------------------------------

universe :: [Id]
universe = map nid [0 .. 5]

genGraph :: Gen Graph
genGraph =
  build
    <$> listOf
      ( (,) <$> elements universe
          <*> listOf ((,) <$> elements [minBound .. maxBound] <*> elements universe)
      )

genSet :: Gen (Set Id)
genSet = Set.fromList <$> sublistOf universe

genRoots :: Gen Roots
genRoots = Roots <$> genSet <*> genSet <*> genSet

-- Each Id is old, young, or has no known age.
genAges :: Gen (Map Id UTCTime)
genAges =
  Map.fromList . concat
    <$> forM universe (\i -> elements [[(i, old)], [(i, fresh)], []])

-- A case for the properties: the graph, the roots and the ages.
data Case = Case Graph Roots (Map Id UTCTime)
  deriving (Show)

instance Arbitrary Case where
  arbitrary = Case <$> genGraph <*> genRoots <*> genAges

properties :: TestTree
properties =
  testGroup
    "properties"
    [ testProperty "plan returns only nodes of the graph" $ \(Case g r ages) ->
        plan pol (obs ages) r g `Set.isSubsetOf` nodes g
    , testProperty "plan never returns a root" $ \(Case g r ages) ->
        Set.disjoint (plan pol (obs ages) r g) (allRoots r)
    , testProperty "plan never returns what a root retains" $ \(Case g r ages) ->
        Set.disjoint (plan pol (obs ages) r g) (reachable retains (allRoots r) g)
    , testProperty "plan never returns a young object or one with no age" $ \(Case g r ages) ->
        let isOld i = Map.lookup i ages == Just old
         in all isOld (plan pol (obs ages) r g)
    , testProperty "with no roots and only old objects, plan returns every node" $ \(Case g _ _) ->
        planOld noRoots g === nodes g
    , testProperty "more roots never collect more" $ \(Case g r ages) ->
        forAll genRoots $ \r' ->
          let more = Roots (rootRefs r <> rootRefs r') (rootPins r <> rootPins r') (rootTemps r <> rootTemps r')
           in plan pol (obs ages) more g `Set.isSubsetOf` plan pol (obs ages) r g
    , testProperty "an old node is collected exactly when no root reaches it" $ \(Case g r _) ->
        let live = reachable retains (allRoots r) g
         in planOld r g === nodes g `Set.difference` live
    ]

-- explain --------------------------------------------------------------

explainTests :: TestTree
explainTests =
  testGroup
    "explain"
    [ testCase "a superseded memory with no root is not live, and has no reasons" $
        explain pol (obs (allOld pair)) (roots [b]) pair a @?= Why True False [] []
    , testCase "a ref root is held by the ref, with an empty path" $
        explain pol (obs (allOld pair)) (roots [b]) pair b @?= Why True True [HeldByRef] []
    , testCase "lists every reason, roots first and edges last" $
        let g = build [(a, []), (b, [(About, a)]), (c, [(Refines, a), (Supersedes, a)])]
            r = (roots [a, b, c]) {rootPins = Set.singleton a, rootTemps = Set.singleton a}
            ages = Map.fromList [(a, fresh), (b, old), (c, old)]
         in whyReasons (explain pol (obs ages) r g a)
              @?= [HeldByRef, HeldByPin, HeldByTemp, IsYoung, RetainedBy About b, RetainedBy Refines c]
    , testCase "the path is the shortest chain of retaining edges from a root" $
        let g = build [(a, []), (b, [(About, a)]), (c, [(DerivedFrom, b)]), (x, [(Refines, a)])]
         in whyPath (explain pol (obs (allOld g)) (roots [c, x]) g a) @?= [(x, Refines)]
    , testCase "a longer path goes from the root to the id, in order" $
        let g = build [(a, []), (b, [(About, a)]), (c, [(DerivedFrom, b)])]
         in whyPath (explain pol (obs (allOld g)) (roots [c]) g a) @?= [(c, DerivedFrom), (b, About)]
    , testCase "a young node is a reason, and the start of a path" $
        let g = build [(a, []), (b, [(About, a)])]
            ages = Map.fromList [(a, old), (b, fresh)]
         in ( whyReasons (explain pol (obs ages) noRoots g b)
            , whyPath (explain pol (obs ages) noRoots g a)
            )
              @?= ([IsYoung], [(b, About)])
    , testCase "an id that is not a node is never young" $
        explain pol (obs Map.empty) noRoots pair x @?= Why False False [] []
    , testProperty "an id is in plan exactly when it is a node and not live" $ \(Case g r ages) ->
        conjoin
          [ (i `Set.member` plan pol (obs ages) r g) === (whyIsNode w && not (whyLive w))
          | i <- universe
          , let w = explain pol (obs ages) r g i
          ]
    , testProperty "a node is live exactly when it has a reason" $ \(Case g r ages) ->
        conjoin
          [ whyLive w === not (null (whyReasons w))
          | i <- Set.toList (nodes g)
          , let w = explain pol (obs ages) r g i
          ]
    , testProperty "the path starts at a seed and follows retaining edges to the id" $ \(Case g r ages) ->
        conjoin
          [ validPath g (seedsOf g r ages) i (whyPath (explain pol (obs ages) r g i))
          | i <- universe
          ]
    , testProperty "explainAll gives explain for every node" $ \(Case g r ages) ->
        explainAll pol (obs ages) r g === Map.fromSet (explain pol (obs ages) r g) (nodes g)
    , testCase "explainAll on a chain gives the same paths as explain" $
        let g = build [(a, []), (b, [(About, a)]), (c, [(DerivedFrom, b)]), (x, [(Refines, a)])]
         in Map.lookup a (explainAll pol (obs (allOld g)) (roots [c]) g)
              @?= Just (Why True True [RetainedBy About b] [(c, DerivedFrom), (b, About)])
    , testProperty "a live id has a path exactly when it is not a seed" $ \(Case g r ages) ->
        conjoin
          [ not (null (whyPath w)) === (whyLive w && i `Set.notMember` seedsOf g r ages)
          | i <- universe
          , let w = explain pol (obs ages) r g i
          ]
    ]

-- The seeds of liveness: the roots, and each node that is not old.
seedsOf :: Graph -> Roots -> Map Id UTCTime -> Set Id
seedsOf g r ages = allRoots r <> Set.filter (\n -> Map.lookup n ages /= Just old) (nodes g)

-- A path is valid if it is empty, or if its first memory is a seed, each
-- step is a retaining edge of the graph, and the last step reaches the id.
validPath :: Graph -> Set Id -> Id -> [(Id, EdgeType)] -> Property
validPath _ _ _ [] = property True
validPath g seeds i steps@((s0, _) : _) =
  counterexample (show steps) $
    s0 `Set.member` seeds
      && and
        [ retains k && t `Set.member` successors k s g
        | ((s, k), t) <- zip steps (map fst (drop 1 steps) <> [i])
        ]

-- Tombstones -----------------------------------------------------------

tombstoneTests :: TestTree
tombstoneTests =
  testGroup
    "tombstones"
    [ testCase "renders one line" $
        renderTombstone (Tombstone t0) @?= "pruned: 2026-10-05T12:00:00Z\n"
    , testCase "parses what it renders" $
        parseTombstone "pruned: 2026-10-05T12:00:00Z\n" @?= Right (Tombstone t0)
    , testCase "accepts a missing final newline" $
        parseTombstone "pruned: 2026-10-05T12:00:00Z" @?= Right (Tombstone t0)
    , testCase "rejects other text" $ do
        parseTombstone "gone: 2026-10-05T12:00:00Z\n"
          @?= Left (BadTombstone "gone: 2026-10-05T12:00:00Z\n")
        parseTombstone "pruned: 2026-10-05 12:00:00\n"
          @?= Left (BadTombstone "pruned: 2026-10-05 12:00:00\n")
        parseTombstone "" @?= Left (BadTombstone "")
    , testCase "rejects bytes that are not UTF-8" $
        parseTombstone "\xff\xfe" @?= Left TombstoneNotUtf8
    , testProperty "parseTombstone reverses renderTombstone for whole seconds" $
        forAll (choose (0 :: Int, 4102444800)) $ \s ->
          let t = Tombstone (posixSecondsToUTCTime (fromIntegral s))
           in parseTombstone (renderTombstone t) === Right t
    , testCase "tombstonePath is tombstones/<id> under the root" $
        withEnv $ \s _ _ dir ->
          tombstonePath s a @?= dir </> "tombstones" </> show a
    , testCase "lookupTombstone gives Nothing if there is none" $
        withEnv $ \s _ _ _ -> lookupTombstone s a >>= (@?= Right Nothing)
    , testCase "lookupTombstone rejects a bad file" $
        withEnv $ \s _ _ dir -> do
          createDirectoryIfMissing True (dir </> "tombstones")
          BS.writeFile (tombstonePath s a) "junk"
          lookupTombstone s a >>= (@?= Left (CorruptTombstone a (BadTombstone "junk")))
    ]

-- Listings -------------------------------------------------------------

listingTests :: TestTree
listingTests =
  testGroup
    "listTrash and listTombstones"
    [ testCase "no directories mean empty lists" $
        withEnv $ \s _ _ _ -> do
          listTombstones s >>= (@?= Right [])
          listTrash s >>= (@?= Right [])
    , testCase "listTrash gives each object with the time of the move" $
        withEnv $ \s rs cache _ -> do
          (i, _) <- supersededPair s rs
          t <- later
          _ <- gcOnce s rs cache zeroGen t
          listTrash s >>= (@?= Right [(i, t)])
    , testCase "listTombstones gives each tombstone, sorted, and skips other names" $
        withEnv $ \s rs cache dir -> do
          (i, _) <- supersededPair s rs
          t <- later
          _ <- gcOnce s rs cache zeroGen t
          let t2 = addUTCTime (trashTTL zeroGen + 60) t
          _ <- right =<< sweep s zeroGen t2 Set.empty
          BS.writeFile (dir </> "tombstones" </> ".tmp1") "x"
          listTombstones s >>= (@?= Right [(i, Tombstone t2)])
          listTrash s >>= (@?= Right [])
    , testCase "listTombstones fails on a bad tombstone" $
        withEnv $ \s _ _ dir -> do
          createDirectoryIfMissing True (dir </> "tombstones")
          BS.writeFile (tombstonePath s a) "junk"
          listTombstones s >>= (@?= Left (CorruptTombstone a (BadTombstone "junk")))
    ]

-- Pins -----------------------------------------------------------------

pinTests :: TestTree
pinTests =
  testGroup
    "pins"
    [ testCase "no pins directory means no pins" $
        withEnv $ \s _ _ _ -> listPins s >>= (@?= Right Set.empty)
    , testCase "pin, list, unpin" $
        withEnv $ \s _ _ _ -> do
          right =<< pin s a
          right =<< pin s b
          right =<< pin s a
          listPins s >>= (@?= Right (Set.fromList [a, b]))
          right =<< unpin s a
          listPins s >>= (@?= Right (Set.singleton b))
    , testCase "unpin of an object that is not pinned does nothing" $
        withEnv $ \s _ _ _ -> unpin s a >>= (@?= Right ())
    , testCase "a pin is an empty file in pins/" $
        withEnv $ \s _ _ dir -> do
          right =<< pin s a
          pinPath s a @?= dir </> "pins" </> show a
          BS.readFile (pinPath s a) >>= (@?= "")
    , testCase "listPins skips a name that is not an Id" $
        withEnv $ \s _ _ dir -> do
          right =<< pin s a
          BS.writeFile (dir </> "pins" </> ".tmp123") ""
          listPins s >>= (@?= Right (Set.singleton a))
    ]

-- Roots from disk ------------------------------------------------------

rootTests :: TestTree
rootTests =
  testGroup
    "readRoots"
    [ testCase "reads the retained generations of each ref and the pins" $
        withEnv $ \s rs _ _ -> do
          setTo rs "claude/notes" [a, b, c]
          setTo rs "other" [x]
          right =<< pin s (nid 9)
          r0 <- right =<< readRoots pol rs s
          r0 @?= Roots (Set.fromList [c, x]) (Set.singleton (nid 9)) Set.empty
          r1 <- right =<< readRoots pol {keepGenerations = 1} rs s
          rootRefs r1 @?= Set.fromList [b, c, x]
    , testCase "fails on a corrupt ref" $
        withEnv $ \s rs _ _ -> do
          setTo rs "claude/notes" [a]
          let n = either (error . show) id (mkName "claude/notes")
          BS.writeFile (refPath rs n) "not an id\n"
          r <- readRoots pol rs s
          case r of
            Left (GCRefs (CorruptRef n' _)) -> n' @?= n
            _ -> assertFailure ("expected CorruptRef, got " ++ show r)
    ]

-- Sweep ----------------------------------------------------------------

sweepTests :: TestTree
sweepTests =
  testGroup
    "sweep"
    [ testCase "a superseded memory is collected, and the head stays" $
        withEnv $ \s rs cache _ -> do
          (i, j) <- supersededPair s rs
          t <- later
          (doomed, rep) <- gcOnce s rs cache zeroGen t
          doomed @?= Set.singleton i
          trashed rep @?= [i]
          doesFileExist (objectPath s i) >>= (@?= False)
          doesFileExist (trashPath s i) >>= (@?= True)
          doesFileExist (objectPath s j) >>= (@?= True)
    , testCase "a retained generation is not collected" $
        withEnv $ \s rs cache _ -> do
          (i, _) <- supersededPair s rs
          t <- later
          (doomed, _) <- gcOnce s rs cache zeroGen {keepGenerations = 1} t
          doomed @?= Set.empty
          doesFileExist (objectPath s i) >>= (@?= True)
    , testCase "a pinned memory survives" $
        withEnv $ \s rs cache _ -> do
          (i, _) <- supersededPair s rs
          right =<< pin s i
          t <- later
          (doomed, _) <- gcOnce s rs cache zeroGen t
          doomed @?= Set.empty
          doesFileExist (objectPath s i) >>= (@?= True)
    , testCase "a dry run changes nothing" $
        withEnv $ \s rs cache dir -> do
          _ <- supersededPair s rs
          right =<< pin s x
          treeBefore <- treeOf dir
          t <- later
          (g, ages) <- right =<< snapshot cache s
          let o = Observed t ages
          r <- right =<< readRoots zeroGen rs s
          assertBool "the plan is empty, so the test shows nothing" (not (Set.null (plan zeroGen o r g)))
          treeAfter <- treeOf dir
          treeAfter @?= treeBefore
    , testCase "a young object survives the grace period" $
        withEnv $ \s rs cache _ -> do
          i <- right =<< add s (mem "no ref yet")
          realNow <- getCurrentTime
          (doomed, _) <- gcOnce s rs cache defaultPolicy realNow
          doomed @?= Set.empty
          doesFileExist (objectPath s i) >>= (@?= True)
          t <- later
          (doomed', _) <- gcOnce s rs cache zeroGen t
          doomed' @?= Set.singleton i
    , testCase "sweep moves first, and deletes only after the TTL" $
        withEnv $ \s rs cache _ -> do
          (i, _) <- supersededPair s rs
          t <- later
          (_, rep) <- gcOnce s rs cache zeroGen t
          (trashed rep, deleted rep) @?= ([i], [])
          let p = zeroGen
              ttl = trashTTL p
          -- Just before the TTL: still in the trash.
          r1 <- right =<< sweep s zeroGen (addUTCTime (ttl - 60) t) Set.empty
          r1 @?= SweepReport [] []
          doesFileExist (trashPath s i) >>= (@?= True)
          lookupTombstone s i >>= (@?= Right Nothing)
          -- After the TTL: deleted, with a tombstone.
          let t2 = addUTCTime (ttl + 60) t
          r2 <- right =<< sweep s zeroGen t2 Set.empty
          r2 @?= SweepReport [] [i]
          doesFileExist (trashPath s i) >>= (@?= False)
          doesFileExist (objectPath s i) >>= (@?= False)
          lookupTombstone s i >>= (@?= Right (Just (Tombstone t2)))
    , testCase "no tombstone for an object that is back in the store" $
        withEnv $ \s rs cache _ -> do
          (i, _) <- supersededPair s rs
          t <- later
          _ <- gcOnce s rs cache zeroGen t
          _ <- right =<< add s (mem "old")
          r <- right =<< sweep s zeroGen (addUTCTime (trashTTL zeroGen + 60) t) Set.empty
          deleted r @?= [i]
          doesFileExist (trashPath s i) >>= (@?= False)
          doesFileExist (objectPath s i) >>= (@?= True)
          lookupTombstone s i >>= (@?= Right Nothing)
    , testCase "sweep skips an object that is not in the store" $
        withEnv $ \s _ _ _ -> do
          t <- later
          sweep s zeroGen t (Set.singleton a) >>= (@?= Right (SweepReport [] []))
    , testCase "sweepAndSync makes the cache forget the swept objects" $
        withEnv $ \s rs cache _ -> do
          (i, j) <- supersededPair s rs
          t <- later
          _ <- gcOnce s rs cache zeroGen t
          ids <- right =<< cachedIds cache
          ids @?= Set.singleton j
          Set.member i ids @?= False
    ]

-- A whole run ----------------------------------------------------------

runTests :: TestTree
runTests =
  testGroup
    "collect"
    [ testCase "collects an old object that nothing reaches" $
        withEnv $ \s rs cache _ -> do
          i <- oldObject s "lonely"
          r <- right =<< collect cache s rs defaultPolicy Set.empty
          planned r @?= Set.singleton i
          trashed (swept r) @?= [i]
          doesFileExist (trashPath s i) >>= (@?= True)
    , testCase "an old object that is added again gets the grace period" $
        withEnv $ \s rs cache _ -> do
          i <- oldObject s "lonely"
          _ <- right =<< add s (mem "lonely")
          r <- right =<< collect cache s rs defaultPolicy Set.empty
          planned r @?= Set.empty
          doesFileExist (objectPath s i) >>= (@?= True)
    , testCase "a temporary root survives" $
        withEnv $ \s rs cache _ -> do
          i <- oldObject s "lonely"
          r <- right =<< collect cache s rs defaultPolicy (Set.singleton i)
          planned r @?= Set.empty
    , testCase "recheck keeps the plan if nothing changed" $
        withEnv $ \s rs cache _ -> do
          i <- oldObject s "lonely"
          (r, g, doomed, t) <- planNow s rs cache
          doomed @?= Set.singleton i
          recheck s rs defaultPolicy t r g doomed >>= (@?= Right doomed)
    , testCase "recheck drops an object that a new memory links to" $
        withEnv $ \s rs cache _ -> do
          i <- oldObject s "target"
          (r, g, doomed, t) <- planNow s rs cache
          doomed @?= Set.singleton i
          _ <- right =<< add s (memWith "new" [Edge About i])
          recheck s rs defaultPolicy t r g doomed >>= (@?= Right Set.empty)
    , testCase "recheck drops an object that is pinned, or that a ref points at, after the plan" $
        withEnv $ \s rs cache _ -> do
          i <- oldObject s "a"
          j <- oldObject s "b"
          (r, g, doomed, t) <- planNow s rs cache
          doomed @?= Set.fromList [i, j]
          right =<< pin s i
          setTo rs "claude/back" [j]
          recheck s rs defaultPolicy t r g doomed >>= (@?= Right Set.empty)
    , testCase "sweep skips an object that was added again after the plan" $
        withEnv $ \s rs cache _ -> do
          i <- oldObject s "lonely"
          (_, _, doomed, t) <- planNow s rs cache
          doomed @?= Set.singleton i
          _ <- right =<< add s (mem "lonely")
          rep <- right =<< sweep s defaultPolicy t doomed
          trashed rep @?= []
          doesFileExist (objectPath s i) >>= (@?= True)
    , testCase "a dry run writes nothing, not even the cache" $
        withEnv $ \s rs cache dir -> do
          i <- oldObject s "lonely"
          j <- right =<< add s (mem "young")
          treeBefore <- treeOf dir
          dryRun cache s rs defaultPolicy Set.empty >>= (@?= Right (Set.singleton i))
          treeAfter <- treeOf dir
          treeAfter @?= treeBefore
          cachedIds cache >>= (@?= Right Set.empty)
          mapM_ (\k -> doesFileExist (objectPath s k) >>= (@?= True)) [i, j]
          doesFileExist (gcLockPath s) >>= (@?= False)
    , testCase "the lock file is gc.lock in the root" $
        withEnv $ \s _ _ dir -> gcLockPath s @?= dir </> "gc.lock"
    , testCase "a run returns GCLocked while another run holds the lock" $
        withEnv $ \s rs cache _ -> do
          i <- oldObject s "lonely"
          held <- newEmptyMVar
          release <- newEmptyMVar
          done <- newEmptyMVar
          _ <- forkIO $ do
            r <- withGCLock s (putMVar held () >> takeMVar release >> pure (Right ()))
            putMVar done r
          takeMVar held
          collect cache s rs defaultPolicy Set.empty >>= (@?= Left GCLocked) . fmap planned
          t <- getCurrentTime
          sweep s defaultPolicy t (Set.singleton i) >>= (@?= Left GCLocked)
          doesFileExist (objectPath s i) >>= (@?= True)
          putMVar release ()
          takeMVar done >>= (@?= Right ())
          -- The lock is free again.
          r <- right =<< collect cache s rs defaultPolicy Set.empty
          planned r @?= Set.singleton i
    , testCase "two runs at once: each object is trashed once, and no run fails" $
        withEnv $ \s rs cache dir -> do
          is <- mapM (oldObject s) ["a", "b", "c", "d"]
          -- Each run has its own cache connection, like two processes.
          cache2 <- right =<< openCache dir
          go <- newEmptyMVar
          results <- forM [cache, cache2] $ \c' -> do
            out <- newEmptyMVar
            _ <- forkIO $ readMVar go >> collect c' s rs defaultPolicy Set.empty >>= putMVar out
            pure out
          putMVar go ()
          rs' <- mapM takeMVar results
          closeCache cache2
          let ok = [r | Right r <- rs']
              others = [e | Left e <- rs', e /= GCLocked]
          others @?= []
          assertBool "no run swept" (not (null ok))
          sort (concatMap (trashed . swept) ok) @?= sort is
          mapM_ (\k -> doesFileExist (trashPath s k) >>= (@?= True)) is
    ]

-- An object whose file time is two days ago, so it is older than the grace
-- period of 'defaultPolicy'.
oldObject :: Store -> Text -> IO Id
oldObject s body = do
  i <- right =<< add s (mem body)
  t <- getCurrentTime
  setModificationTime (objectPath s i) (addUTCTime (-2 * nominalDay) t)
  pure i

-- The roots, the graph and the plan of a run now, with no temporary roots,
-- and the time of the run.
planNow :: Store -> Refs -> Cache -> IO (Roots, Graph, Set Id, UTCTime)
planNow s rs cache = do
  t <- getCurrentTime
  (g, ages) <- right =<< snapshot cache s
  r <- right =<< readRoots defaultPolicy rs s
  pure (r, g, plan defaultPolicy (Observed t ages) r g, t)

-- IO helpers -----------------------------------------------------------

-- A fresh store, refs and cache in one directory. The cache is closed when
-- the test ends.
withEnv :: (Store -> Refs -> Cache -> FilePath -> IO a) -> IO a
withEnv act = withTempDir $ \dir -> do
  s <- right =<< openStore dir
  rs <- right =<< openRefs dir
  bracket (right =<< openCache dir) closeCache $ \cache -> act s rs cache dir

memWith :: Text -> [Edge] -> Memory
memWith body es =
  Memory
    { memKind = "fact"
    , memCreated = t0
    , memAgent = "claude"
    , memEdges = Set.fromList es
    , memBody = body
    }

mem :: Text -> Memory
mem body = memWith body []

-- Set a ref to each Id in turn, so the last one is current.
setTo :: Refs -> Text -> [Id] -> IO ()
setTo rs name ids = do
  n <- either (\e -> assertFailure (show e)) pure (mkName name)
  mapM_ (\i -> right =<< setRef rs n Unchecked i) ids

-- Add "old", then "new" that supersedes it, and move the ref claude/notes
-- from the old one to the new one. Returns (old, new).
supersededPair :: Store -> Refs -> IO (Id, Id)
supersededPair s rs = do
  i <- right =<< add s (mem "old")
  j <- right =<< add s (memWith "new" [Edge Supersedes i])
  setTo rs "claude/notes" [i, j]
  pure (i, j)

-- One day from now, in whole seconds. Every object that a test added is
-- older than the grace period then.
later :: IO UTCTime
later = do
  t <- getCurrentTime
  let whole = fromInteger (floor (utcTimeToPOSIXSeconds t))
  pure (addUTCTime nominalDay (posixSecondsToUTCTime whole))

-- The default policy, with keepGenerations 0.
zeroGen :: Policy
zeroGen = defaultPolicy {keepGenerations = 0}

-- One whole GC run at a time: snapshot, roots, plan, sweep and sync.
gcOnce :: Store -> Refs -> Cache -> Policy -> UTCTime -> IO (Set Id, SweepReport)
gcOnce s rs cache p t = do
  (g, ages) <- right =<< snapshot cache s
  r <- right =<< readRoots p rs s
  let doomed = plan p (Observed t ages) r g
  (rep, _) <- right =<< sweepAndSync cache s p t doomed
  pure (doomed, rep)

-- Every file under a directory, with its content, in order. The cache files
-- are left out: SQLite can touch its own files (the WAL index) on a read.
-- The tests check the cache with 'cachedIds'.
treeOf :: FilePath -> IO [(FilePath, BS.ByteString)]
treeOf root = sort <$> go ""
  where
    go rel = do
      names <- listDirectory (root </> rel)
      concat <$> forM (filter (not . ("cache.sqlite" `isPrefixOf`)) names) (\n -> do
        let r = rel </> n
        isDir <- doesDirectoryExist (root </> r)
        if isDir
          then ((r, "<dir>") :) <$> go r
          else (\bs -> [(r, bs)]) <$> BS.readFile (root </> r))
