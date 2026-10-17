{-# LANGUAGE OverloadedStrings #-}

module EpisodeTests (episodeTests) where

import Akyuu.Episode (Walk (walkEntries, walkMore))
import Akyuu.Error (AkyuuError (BadInput))
import Akyuu.GC (Policy (gracePeriod, keepGenerations), defaultPolicy)
import Akyuu.Graph (Edge (Edge), EdgeType (About, DerivedFrom, Follows))
import Akyuu.Memory (Memory (memBody, memEdges))
import Akyuu.Ops (NewMemory, addMemory, appendEpisode, dryRunGC, readLog, setRefTo, supersedeMemory)
import Akyuu.Refs (Expected (MustBeAbsent), mkName)
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
              memEdges newest @?= Set.singleton (Edge Follows a)
              memEdges oldest @?= Set.empty
            other -> error ("unexpected: " <> show (length other)),
      testCase "the limit cuts the walk, and says where it goes on" $
        withOpsEnv $ \_ env -> do
          n <- right (mkName "agent/episodes")
          ids <- forM ["a", "b", "c", "d"] $ \t -> right =<< appendEpisode env n (note t)
          w <- right =<< readLog env n 2
          map fst (walkEntries w) @?= [ids !! 3, ids !! 2]
          walkMore w @?= Just (ids !! 1),
      testCase "other links are allowed, and derived_from is evidence" $
        withOpsEnv $ \_ env -> do
          n <- right (mkName "agent/episodes")
          topic <- right =<< addMemory env (note "a topic")
          a <- right =<< appendEpisode env n (newMem "episode" "claude" (Set.singleton (Edge About topic)) "it was about the topic")
          b <- right =<< appendEpisode env n (newMem "episode" "claude" (Set.singleton (Edge DerivedFrom topic)) "it came from the topic")
          w <- right =<< readLog env n 10
          map fst (walkEntries w) @?= [b, a],
      testCase "append adds follows, so a follows edge of its own is refused" $
        withOpsEnv $ \_ env -> do
          n <- right (mkName "agent/episodes")
          a <- right =<< appendEpisode env n (note "first")
          r <- appendEpisode env n (newMem "episode" "claude" (Set.singleton (Edge Follows a)) "x")
          isBadInput r @?= True,
      testCase "the first episode cannot have exactly one derived_from edge" $
        withOpsEnv $ \_ env -> do
          n <- right (mkName "agent/episodes")
          topic <- right =<< addMemory env (note "a topic")
          r <- appendEpisode env n (newMem "episode" "claude" (Set.singleton (Edge DerivedFrom topic)) "x")
          isBadInput r @?= True,
      testCase "an old log goes on: a new episode follows a chain of derived_from edges" $
        withOpsEnv $ \_ env -> do
          n <- right (mkName "agent/episodes")
          a <- right =<< addMemory env (note "old a")
          b <- right =<< addMemory env (newMem "episode" "claude" (Set.singleton (Edge DerivedFrom a)) "old b")
          _ <- right =<< setRefTo env n MustBeAbsent b
          c <- right =<< appendEpisode env n (note "new c")
          w <- right =<< readLog env n 10
          map fst (walkEntries w) @?= [c, b, a]
          walkMore w @?= Nothing,
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
    isBadInput r = case r of
      Left (BadInput _) -> True
      _ -> False
