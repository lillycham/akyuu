{-# LANGUAGE OverloadedStrings #-}

-- | Tests of the demo store, and of the GC and health views on it. The demo
-- has one of each case, so it is the fixture of these views.
module SeedTests (seedTests, withDemo) where

import Akyuu.Cache (cachedIds, closeCache, openCache)
import Akyuu.Error (AkyuuError (..))
import Akyuu.GC (Tombstone (..), defaultPolicy)
import Akyuu.GC qualified as GC
import Akyuu.Graph qualified as Graph
import Akyuu.Id (Id, render)
import Akyuu.Ops (Env (..), VerifyReport (..), verifyStore, withEnv)
import Akyuu.Refs (openRefs)
import Akyuu.Seed
import Akyuu.Store (openStore)
import Akyuu.Store qualified as Store
import Akyuu.Web.Api (WebRequest (..), WebResponse (..), route, runEndpoint)
import Akyuu.Web.Read (readBundle)
import Control.Monad (forM_)
import Data.Aeson (Value (..))
import Data.Aeson qualified as A
import Data.Aeson.Key qualified as K
import Data.Aeson.KeyMap qualified as KM
import Data.Either (isLeft)
import Data.Maybe (fromMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (getCurrentTime)
import Support (nid, right, withTempDir)
import System.Directory (createDirectory, doesFileExist)
import System.FilePath ((</>))
import Test.Tasty
import Test.Tasty.HUnit
import WebTests (at, strings, treeOf)

seedTests :: TestTree
seedTests =
  testGroup
    "Akyuu.Seed"
    [ rootCases
    , demoCases
    , viewCases
    ]

-- Make the demo in a fresh directory, open it, and run a test on it.
withDemo :: (FilePath -> Demo -> Env -> IO a) -> IO a
withDemo act = withTempDir $ \dir -> do
  let root = dir </> "demo"
  now <- getCurrentTime
  d <- right =<< seedDemo root now
  r <- withEnv root (\env -> Right <$> act root d env)
  right r

get :: Env -> [Text] -> [(Text, Maybe Text)] -> IO (Int, Value)
get env p q = do
  r <- route (runEndpoint env) (WebRequest "GET" p q)
  pure (resStatus r, fromMaybe Null (A.decode (resBody r)))

items :: Maybe Value -> [Value]
items (Just (Array xs)) = foldr (:) [] xs
items _ = []

idText :: Id -> Maybe Value
idText = Just . String . render

-- Roots ----------------------------------------------------------------

rootCases :: TestTree
rootCases =
  testGroup
    "the root of seed"
    [ testCase "a directory that is not there is made" $
        withTempDir $ \dir -> do
          now <- getCurrentTime
          d <- right =<< seedDemo (dir </> "new") now
          assertBool "no memories" (length (demoStored d) > 20)
    , testCase "an empty store is accepted" $
        withTempDir $ \dir -> do
          _ <- right =<< openStore dir
          _ <- right =<< openRefs dir
          c <- right =<< openCache dir
          closeCache c
          checkEmptyRoot dir >>= (@?= Right ())
    , testCase "a store with data is refused, and does not change" $
        withDemo $ \root _ _ -> do
          before <- treeOf root
          now <- getCurrentTime
          r <- seedDemo root now
          isLeft r @?= True
          after' <- treeOf root
          after' @?= before
    , testCase "a .DS_Store of a file manager does not make the root non-empty" $
        withTempDir $ \dir -> do
          _ <- right =<< openStore dir
          writeFile (dir </> ".DS_Store") "x"
          writeFile (dir </> "store" </> ".DS_Store") "x"
          checkEmptyRoot dir >>= (@?= Right ())
    , testCase "a directory with another file is refused" $
        withTempDir $ \dir -> do
          writeFile (dir </> "notes.txt") "mine"
          r <- checkEmptyRoot dir
          case r of
            Left (BadInput t) -> assertBool (T.unpack t) ("notes.txt" `T.isInfixOf` t)
            other -> assertFailure ("expected BadInput, got " <> show other)
    , testCase "a file is refused" $
        withTempDir $ \dir -> do
          writeFile (dir </> "f") ""
          isLeft <$> checkEmptyRoot (dir </> "f") >>= (@?= True)
    , testCase "a single pin is enough to refuse" $
        withTempDir $ \dir -> do
          createDirectory (dir </> "pins")
          writeFile (dir </> "pins" </> T.unpack (render (nid 3))) ""
          isLeft <$> checkEmptyRoot dir >>= (@?= True)
    ]

-- The demo -------------------------------------------------------------

demoCases :: TestTree
demoCases =
  testGroup
    "the demo store"
    [ testCase "the pruned memory has a tombstone and is gone" $
        withDemo $ \_ d env -> do
          let s = envStore env
          Store.exists s (demoPruned d) >>= (@?= Right False)
          t <- right =<< GC.lookupTombstone s (demoPruned d)
          assertBool "no tombstone" (maybe False (const True) (t :: Maybe Tombstone))
    , testCase "the trashed memory is in trash and not in the store" $
        withDemo $ \_ d env -> do
          let s = envStore env
          Store.exists s (demoTrashed d) >>= (@?= Right False)
          tr <- right =<< GC.listTrash s
          map fst tr @?= [demoTrashed d]
    , testCase "the pin is there" $
        withDemo $ \_ d env ->
          GC.listPins (envStore env) >>= (@?= Right (Set.singleton (demoPinned d)))
    , testCase "a GC plan now has exactly the garbage" $
        withDemo $ \_ d env -> do
          p <- right =<< GC.dryRun (envCache env) (envStore env) (envRefs env) defaultPolicy Set.empty
          p @?= Set.fromList (demoGarbage d)
    , testCase "verify finds the missing target and the pruned one" $
        withDemo $ \_ d env -> do
          v <- right =<< verifyStore env
          missingTargets v @?= [demoMissing d]
          prunedTargets v @?= [demoPruned d]
          corruptObjects v @?= []
    , testCase "the fork has two heads that supersede one memory" $
        withDemo $ \_ d env -> do
          (g, _) <- right =<< GC.snapshot (envCache env) (envStore env)
          let (o, a, b) = demoFork d
          Graph.predecessors Graph.Supersedes o g @?= Set.fromList [a, b]
          assertBool "both are heads" (Set.fromList [a, b] `Set.isSubsetOf` Graph.heads g)
    , testCase "the cache is in sync with the store" $
        withDemo $ \_ d env -> do
          c <- right =<< cachedIds (envCache env)
          c @?= Set.fromList (demoStored d)
    , testCase "seven generations of codex/status, and several agents and kinds" $
        withDemo $ \_ d _ -> do
          fmap length (lookup "codex/status" (demoRefs d)) @?= Just 7
          length (demoRefs d) @?= 7
    ]

-- The GC and health views on the demo ------------------------------------

viewCases :: TestTree
viewCases =
  testGroup
    "the GC and health views on the demo"
    [ testCase "the plan endpoint lists the garbage and the young memories" $
        withDemo $ \_ d env -> do
          (s, v) <- get env ["api", "gc", "plan"] []
          s @?= 200
          Set.fromList (strings (at ["planned"] v)) @?= Set.fromList (map render (demoGarbage d))
          assertBool "young" (Set.fromList (map render (demoYoung d)) `Set.isSubsetOf` Set.fromList (strings (at ["young"] v)))
    , testCase "explain says why each case stays" $
        withDemo $ \_ d env -> do
          let reasons i = do
                (_, w) <- get env ["api", "gc", "explain", render i] []
                pure (w, [at ["reason"] r | r <- items (at ["reasons"] w)])
          (_, pin) <- reasons (demoPinned d)
          pin @?= [Just "pin"]
          let (f1, n1) = demoRetained d
          (w1, r1) <- reasons f1
          r1 @?= [Just "edge"]
          [at ["from"] r | r <- items (at ["reasons"] w1)] @?= [idText n1]
          [at ["id"] p | p <- items (at ["path"] w1)] @?= [idText n1]
          forM_ (demoGarbage d) $ \g -> do
            (w, r) <- reasons g
            (at ["live"] w, at ["planned"] w, r) @?= (Just (Bool False), Just (Bool True), [])
          -- The first young memory also has an about edge from the second one.
          forM_ (demoYoung d) $ \i -> do
            (_, y) <- reasons i
            assertBool (show y) (Just "young" `elem` y)
    , testCase "explain of the pruned memory is 410; the missing one is not a node, but a live edge reaches it" $
        withDemo $ \_ d env -> do
          (s1, _) <- get env ["api", "gc", "explain", render (demoPruned d)] []
          s1 @?= 410
          (s2, w) <- get env ["api", "gc", "explain", render (demoMissing d)] []
          s2 @?= 200
          (at ["isNode"] w, at ["planned"] w) @?= (Just (Bool False), Just (Bool False))
          [at ["reason"] r | r <- items (at ["reasons"] w)] @?= [Just "edge"]
          (s3, _) <- get env ["api", "gc", "explain", render (nid 3)] []
          s3 @?= 404
    , testCase "trash lists the trash, the tombstone and the pin" $
        withDemo $ \_ d env -> do
          (_, v) <- get env ["api", "trash"] []
          [at ["id"] x | x <- items (at ["trash"] v)] @?= [idText (demoTrashed d)]
          [at ["id"] x | x <- items (at ["tombstones"] v)] @?= [idText (demoPruned d)]
          [at ["id"] x | x <- items (at ["pins"] v)] @?= [idText (demoPinned d)]
    , testCase "the graph marks the pruned and the missing targets" $
        withDemo $ \_ d env -> do
          (_, v) <- get env ["api", "graph"] [("all", Nothing)]
          let status i = [at ["status"] n | n <- items (at ["nodes"] v), at ["id"] n == idText i]
          status (demoPruned d) @?= [Just "pruned"]
          status (demoMissing d) @?= [Just "missing"]
          let (o, _, _) = demoFork d
          status o @?= [Just "superseded"]
    , testCase "verify reports the missing target, and no drift" $
        withDemo $ \_ d env -> do
          (_, v) <- get env ["api", "verify"] []
          at ["ok"] v @?= Just (Bool False)
          strings (at ["missing"] v) @?= [render (demoMissing d)]
          at ["drift", "inSync"] v @?= Just (Bool True)
    , testCase "every node of the plan agrees with its explain" $
        withDemo $ \_ _ env -> do
          (_, g) <- get env ["api", "graph"] [("all", Nothing)]
          (_, p) <- get env ["api", "gc", "plan"] []
          let planned = Set.fromList (strings (at ["planned"] p))
          forM_ [i | n <- items (at ["nodes"] g), at ["status"] n `elem` [Just "head", Just "superseded"], Just (String i) <- [at ["id"] n]] $ \i -> do
            (_, w) <- get env ["api", "gc", "explain", i] []
            at ["planned"] w @?= Just (Bool (i `Set.member` planned))
    , testCase "the static bundle has every part, every memory and every explain" $
        withDemo $ \_ d env -> do
          b <- readBundle env
          forM_ ["stats", "graph", "refs", "plan", "trash", "verify", "memories", "explain"] $ \k ->
            case at [k, "error"] b of
              Just e -> assertFailure (T.unpack k <> ": " <> show e)
              Nothing -> pure ()
          case at ["memories"] b of
            Just (Object o) -> Set.fromList (map K.toText (KM.keys o)) @?= Set.fromList (map render (demoStored d))
            other -> assertFailure (show other)
          case (at ["explain"] b, at ["graph", "total", "nodes"] b) of
            (Just (Object o), Just (Number n)) ->
              -- Every node, but not the two dangling targets.
              fromIntegral (KM.size o) @?= n - 2
            other -> assertFailure (show other)
    , testCase "the demo files exist where the layout says" $
        withDemo $ \root d env -> do
          doesFileExist (GC.tombstonePath (envStore env) (demoPruned d)) >>= (@?= True)
          doesFileExist (root </> "pins" </> T.unpack (render (demoPinned d))) >>= (@?= True)
    ]
