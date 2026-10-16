{-# LANGUAGE OverloadedStrings #-}

module EpisodeTests (episodeTests) where

import Akyuu.Episode (Walk (walkEntries, walkMore))
import Akyuu.Error (AkyuuError (BadInput))
import Akyuu.GC (Policy (gracePeriod, keepGenerations), defaultPolicy)
import Akyuu.Graph (Edge (Edge), EdgeType (About, DerivedFrom))
import Akyuu.Memory (Memory (memBody, memEdges))
import Akyuu.Ops (NewMemory, addMemory, appendEpisode, dryRunGC, readLog, supersedeMemory)
import Akyuu.Refs (mkName)
import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Monad (forM, forM_)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import OpsTests (withOpsEnv)
import Support (newMem, right)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

episodeTests :: TestTree
episodeTests =
  testGroup
    "episodes"
    [ testCase "the first append makes the log, and the second points at the first" $
        withOpsEnv $ \_ env -> do
          n <- right (mkName "agent/episodes")
          a <- right =<< appendEpisode env n (note "first")
          b <- right =<< appendEpisode env n (note "second")
          w <- right =<< readLog env n 10
          map fst (walkEntries w) @?= [b, a]
          map (memBody . snd) (walkEntries w) @?= ["second", "first"]
          walkMore w @?= Nothing
          case walkEntries w of
            [(_, newest), (_, oldest)] -> do
              memEdges newest @?= Set.singleton (Edge DerivedFrom a)
              memEdges oldest @?= Set.empty
            other -> error ("unexpected: " <> show (length other)),
      testCase "the limit cuts the walk, and says where it goes on" $
        withOpsEnv $ \_ env -> do
          n <- right (mkName "agent/episodes")
          ids <- forM ["a", "b", "c", "d"] $ \t -> right =<< appendEpisode env n (note t)
          w <- right =<< readLog env n 2
          map fst (walkEntries w) @?= [ids !! 3, ids !! 2]
          walkMore w @?= Just (ids !! 1),
      testCase "other links are allowed, derived_from is not" $
        withOpsEnv $ \_ env -> do
          n <- right (mkName "agent/episodes")
          topic <- right =<< addMemory env (note "a topic")
          _ <- right =<< appendEpisode env n (newMem "episode" "claude" (Set.singleton (Edge About topic)) "it was about the topic")
          r <- appendEpisode env n (newMem "episode" "claude" (Set.singleton (Edge DerivedFrom topic)) "x")
          case r of
            Left (BadInput _) -> pure ()
            other -> error ("expected BadInput, got " <> show other),
      testCase "a log that GC knows is kept whole, a loose memory is not" $
        withOpsEnv $ \_ env -> do
          n <- right (mkName "agent/episodes")
          forM_ ["a", "b", "c"] $ \t -> right =<< appendEpisode env n (note t)
          loose <- right =<< addMemory env (note "loose")
          doomed <- right =<< dryRunGC env now
          doomed @?= Set.singleton loose,
      testCase "a summary replaces the log, and the episodes are then garbage" $
        withOpsEnv $ \_ env -> do
          n <- right (mkName "agent/episodes")
          ids <- forM ["a", "b", "c"] $ \t -> right =<< appendEpisode env n (note t)
          s <- right =<< supersedeMemory env n Nothing (newMem "summary" "claude" Set.empty "a, b and c happened")
          -- With one older generation, the ref still names the newest episode, so
          -- the chain is kept. With none, the summary is the only root.
          kept <- right =<< dryRunGC env now
          kept @?= Set.empty
          doomed <- right =<< dryRunGC env now {keepGenerations = 0}
          doomed @?= Set.fromList ids
          assertBool "the summary is kept" (s `Set.notMember` doomed),
      testCase "agents that append at the same time all get into the log" $
        withOpsEnv $ \_ env -> do
          n <- right (mkName "agent/episodes")
          done <- newEmptyMVar
          forM_ [1 .. 4 :: Int] $ \k -> forkIO $ do
            r <- appendEpisode env n (note (T.pack (show k)))
            putMVar done r
          rs <- forM [1 .. 4 :: Int] (const (takeMVar done))
          mapM_ (\r -> either (error . show) (const (pure ())) r) rs
          w <- right =<< readLog env n 10
          length (walkEntries w) @?= 4
    ]
  where
    note :: Text -> NewMemory
    note = newMem "episode" "claude" Set.empty
    now = defaultPolicy {gracePeriod = 0, keepGenerations = 1}
