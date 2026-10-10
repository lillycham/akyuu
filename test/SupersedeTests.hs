{-# LANGUAGE OverloadedStrings #-}

module SupersedeTests (supersedeTests) where

import Akyuu.Graph (Edge (..), EdgeType (..))
import Akyuu.Id (Id)
import Akyuu.Memory (Memory (..))
import Akyuu.Refs
import Akyuu.Store qualified as Store
import Akyuu.Supersede
import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Monad (forM)
import Data.Either (isRight)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import Support (right, withTempDir)
import Test.Tasty
import Test.Tasty.HUnit

supersedeTests :: TestTree
supersedeTests =
  testGroup
    "Akyuu.Supersede"
    [ supersedeCases
    , supersedeFromCases
    , raceCases
    ]

-- Test helpers ---------------------------------------------------------

-- A memory with this body and these edges. Everything else is fixed.
memWith :: Text -> [Edge] -> Memory
memWith body es =
  Memory
    { memKind = "fact"
    , memCreated = posixSecondsToUTCTime 1791201600
    , memAgent = "claude"
    , memEdges = Set.fromList es
    , memBody = body
    }

mem :: Text -> Memory
mem body = memWith body []

-- A fresh store and refs in one directory. The ref @claude/notes@ points to
-- the memory "v1". The test gets the store, the refs, the name and the 'Id'
-- of "v1".
withEnv :: (Store.Store -> Refs -> Name -> Id -> IO a) -> IO a
withEnv act = withTempDir $ \dir -> do
  s <- right =<< Store.openStore dir
  rs <- right =<< openRefs dir
  n <- right (mkName "claude/notes")
  v1 <- right =<< Store.add s (mem "v1")
  _ <- right =<< setRef rs n MustBeAbsent v1
  act s rs n v1

-- supersede ------------------------------------------------------------

supersedeCases :: TestTree
supersedeCases =
  testGroup
    "supersede"
    [ testCase "moves the ref to the new memory" $
        withEnv $ \s rs n _ -> do
          v2 <- right =<< supersede s rs n (mem "v2")
          r <- right =<< getRef rs n
          current r @?= v2
    , testCase "keeps the old value as the newest generation" $
        withEnv $ \s rs n v1 -> do
          _ <- right =<< supersede s rs n (mem "v2")
          r <- right =<< getRef rs n
          history r @?= [v1]
    , testCase "puts a Supersedes edge to the old memory in the new one" $
        withEnv $ \s rs n v1 -> do
          v2 <- right =<< supersede s rs n (mem "v2")
          m <- right =<< Store.get s v2
          memEdges m @?= Set.singleton (Edge Supersedes v1)
    , testCase "keeps the edges that the caller gave" $
        withEnv $ \s rs n v1 -> do
          other <- right =<< Store.add s (mem "other")
          let given = [Edge About other, Edge DerivedFrom other]
          v2 <- right =<< supersede s rs n (memWith "v2" given)
          m <- right =<< Store.get s v2
          memEdges m @?= Set.fromList (Edge Supersedes v1 : given)
    , testCase "does not repeat a Supersedes edge that the caller gave" $
        withEnv $ \s rs n v1 -> do
          v2 <- right =<< supersede s rs n (memWith "v2" [Edge Supersedes v1])
          m <- right =<< Store.get s v2
          memEdges m @?= Set.singleton (Edge Supersedes v1)
    , testCase "keeps the old object in the store" $
        withEnv $ \s rs n v1 -> do
          _ <- right =<< supersede s rs n (mem "v2")
          Store.exists s v1 >>= (@?= Right True)
    , testCase "can be called again on the new value" $
        withEnv $ \s rs n v1 -> do
          v2 <- right =<< supersede s rs n (mem "v2")
          v3 <- right =<< supersede s rs n (mem "v3")
          r <- right =<< getRef rs n
          (current r, history r) @?= (v3, [v2, v1])
    , testCase "returns NoSuchRef for a ref that does not exist, and adds nothing" $
        withEnv $ \s rs _ _ -> do
          missing <- right (mkName "claude/missing")
          r <- supersede s rs missing (mem "v2")
          r @?= Left (SupersedeRef (NoSuchRef missing))
          ids <- right =<< Store.list s
          length ids @?= 1
    ]

-- supersedeFrom --------------------------------------------------------

supersedeFromCases :: TestTree
supersedeFromCases =
  testGroup
    "supersedeFrom"
    [ testCase "works if the ref still has the value that the caller read" $
        withEnv $ \s rs n v1 -> do
          v2 <- right =<< supersedeFrom s rs n v1 (mem "v2")
          getRef rs n >>= fmap current . right >>= (@?= v2)
    , testCase "returns Stale if another agent moved the ref first" $
        withEnv $ \s rs n v1 -> do
          -- The other agent moves the ref after the caller read v1.
          theirs <- right =<< supersedeFrom s rs n v1 (mem "theirs")
          r <- supersedeFrom s rs n v1 (mem "mine")
          r @?= Left (SupersedeRef (Stale n (Just theirs)))
    , testCase "leaves the ref as it was after Stale" $
        withEnv $ \s rs n v1 -> do
          theirs <- right =<< supersedeFrom s rs n v1 (mem "theirs")
          _ <- supersedeFrom s rs n v1 (mem "mine")
          r <- right =<< getRef rs n
          (current r, history r) @?= (theirs, [v1])
    , testCase "leaves the new object in the store after Stale" $
        withEnv $ \s rs n v1 -> do
          _ <- right =<< supersedeFrom s rs n v1 (mem "theirs")
          _ <- supersedeFrom s rs n v1 (mem "mine")
          ids <- right =<< Store.list s
          -- v1, theirs and mine. GC collects "mine" later.
          length ids @?= 3
    ]

-- Several agents -------------------------------------------------------

raceCases :: TestTree
raceCases =
  testGroup
    "several agents"
    [ testCase "no update is lost if many agents supersede one ref" $
        withEnv $ \s rs n v1 -> do
          let agents = 8 :: Int
          vars <- forM [1 .. agents] $ \k -> do
            v <- newEmptyMVar
            _ <- forkIO $ do
              -- Each agent reads, then writes, like an agent that thinks.
              old <- either (const v1) current <$> getRef rs n
              r <- supersedeFrom s rs n old (mem (T.pack ("agent " ++ show k)))
              putMVar v r
            pure v
          results <- mapM takeMVar vars
          let won = [i | Right i <- results]
          assertBool "at least one agent wins" (not (null won))
          r <- right =<< getRef rs n
          -- Every winner is in the ref, and each generation is a winner (or v1).
          Set.fromList (current r : history r) @?= Set.fromList (v1 : won)
          length (history r) @?= length won
          assertBool "a loser got Stale" (all (\x -> isRight x || isStale x) results)
    ]
  where
    isStale (Left (SupersedeRef (Stale _ _))) = True
    isStale _ = False
