{-# LANGUAGE OverloadedStrings #-}

module GCTests (gcTests) where

import Akyuu.Cache (Cache, cachedIds, closeCache, openCache)
import Akyuu.GC
import Akyuu.Graph (Edge (..), EdgeType (..), Graph, nodes, reachable, singleton)
import Akyuu.Id (Id)
import Akyuu.Memory (Memory (..))
import Akyuu.Refs (Expected (..), RefError (CorruptRef), Refs, mkName, openRefs, refPath, setRef)
import Akyuu.Store (Store, add, objectPath, openStore, trashPath)
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
import System.Directory (createDirectoryIfMissing, doesDirectoryExist, doesFileExist, listDirectory)
import System.FilePath ((</>))
import Test.Tasty
import Test.Tasty.HUnit
import Test.Tasty.QuickCheck

gcTests :: TestTree
gcTests =
  testGroup
    "Akyuu.GC"
    [ retainsTests
    , planTests
    , properties
    , tombstoneTests
    , pinTests
    , rootTests
    , sweepTests
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
-- are left out: the cache is not the truth, and a dry run may sync it.
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
