{-# LANGUAGE OverloadedStrings #-}

module LevelsTests (levelsTests) where

import Akyuu.Error (AkyuuError (BadInput))
import Akyuu.Graph (Edge (Edge), EdgeType (DerivedFrom, Follows))
import Akyuu.Id (Id)
import Akyuu.Levels (Chain, Item (Brief, Episode, Summary), Run (runLevel, runMemories), chainOrder, checkSources, fit, levelRef, resolution, todo)
import Akyuu.Memory (Memory (memBody, memCreated, memEdges))
import Akyuu.Ops (appendEpisode, readLevels, summariseLog, unfoldMemory)
import Akyuu.Refs (mkName, nameText)
import Control.Monad (forM)
import Data.Either (isLeft)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime, addUTCTime)
import Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import OpsTests (withOpsEnv)
import Support (newMem, nid, right, testMemory)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

levelsTests :: TestTree
levelsTests =
  testGroup
    "Akyuu.Levels"
    [ pureCases,
      storeCases
    ]

-- A log of n episodes, oldest first, linked by follows. Episode k has the
-- id nid k and is created k minutes after noon.
episodes :: Int -> Chain
episodes n = [(nid k, ep k) | k <- [1 .. n]]
  where
    ep k =
      testMemory
        "note"
        (addUTCTime (fromIntegral (60 * k)) noon)
        "claude"
        (if k == 1 then Set.empty else Set.singleton (Edge Follows (nid (k - 1))))
        ("episode " <> T.pack (show k))

-- A summary with this id, the summary before it, and its sources.
summary :: Int -> Maybe Int -> [Int] -> (Id, Memory)
summary i before srcs =
  ( nid i,
    testMemory
      "summary"
      noon
      "claude"
      (Set.fromList ([Edge Follows (nid b) | Just b <- [before]] <> [Edge DerivedFrom (nid s) | s <- srcs]))
      ("summary " <> T.pack (show i))
  )

noon :: UTCTime
noon = posixSecondsToUTCTime 1791201600

ids :: Chain -> [Id]
ids = map fst

pureCases :: TestTree
pureCases =
  testGroup
    "pure"
    [ testCase "the ref of a level is a suffix of the last part" $ do
        n <- right (mkName "me/log")
        fmap nameText (levelRef n 0) @?= Right "me/log"
        fmap nameText (levelRef n 2) @?= Right "me/log.l2",
      testCase "todo offers full runs of the oldest episodes, and leaves the newest out" $ do
        let rs = todo 3 2 [episodes 9]
        map runLevel rs @?= [1, 1]
        map (ids . runMemories) rs @?= [map nid [1, 2, 3], map nid [4, 5, 6]],
      testCase "todo skips what a summary covers, and offers the next level" $ do
        let l1 = [summary 101 Nothing [1, 2, 3], summary 102 (Just 101) [4, 5, 6], summary 103 (Just 102) [7, 8, 9]]
            rs = todo 3 0 [episodes 12, l1]
        [(runLevel r, ids (runMemories r)) | r <- rs] @?= [(1, map nid [10, 11, 12]), (2, map nid [101, 102, 103])],
      testCase "the sources must be the oldest that no summary covers" $ do
        let levels = [episodes 6, [summary 101 Nothing [1, 2]]]
        checkSources 1 [nid 4, nid 3] levels @?= Right ()
        assertBool "a later stretch" (isLeft (checkSources 1 [nid 4, nid 5] levels))
        assertBool "a covered one" (isLeft (checkSources 1 [nid 2, nid 3] levels))
        assertBool "only one" (isLeft (checkSources 1 [nid 3] levels))
        assertBool "level 0" (isLeft (checkSources 0 [nid 3, nid 4] levels))
        assertBool "a level with nothing below" (isLeft (checkSources 3 [nid 101, nid 102] levels)),
      testCase "resolution shows recent episodes whole, then the highest summaries, then lines" $ do
        let l1 = [summary 101 Nothing [1, 2], summary 102 (Just 101) [3, 4]]
            l2 = [summary 201 Nothing [101, 102]]
            shape (Episode i _) = ("whole", i)
            shape (Brief i _) = ("line", i)
            shape (Summary k i _ n _ _) = ("level " <> T.pack (show k) <> " of " <> T.pack (show n), i)
        map shape (resolution 2 [episodes 7, l1, l2])
          @?= [("whole", nid 7), ("whole", nid 6), ("line", nid 5), ("level 2 of 4", nid 201)],
      testCase "fit shows fewer episodes whole until the text fits, or says what it needs" $ do
        let render = T.concat . map (\it -> case it of Episode _ m -> memBody m <> T.replicate 50 "."; Brief _ _ -> "b"; Summary {} -> "s")
            levels = [episodes 5]
        fmap T.length (fit render 1000 5 levels) @?= Right (T.length (render (resolution 5 levels)))
        fit render 5 5 levels @?= Right "bbbbb"
        fit render 3 5 levels @?= Left 5,
      testCase "chainOrder follows the chain, newest first, also when the times are equal" $ do
        let same = [(i, m {memCreated = noon}) | (i, m) <- episodes 4]
        ids (chainOrder (reverse (drop 1 same) <> take 1 same)) @?= map nid [4, 3, 2, 1]
    ]

storeCases :: TestTree
storeCases =
  testGroup
    "in a store"
    [ testCase "a summary goes to the log of its level, and unfold gives back its sources" $
        withOpsEnv $ \_ env -> do
          n <- right (mkName "me/log")
          es <- forM [1 .. 6 :: Int] $ \k -> right =<< appendEpisode env n (newMem "note" "claude" Set.empty ("episode " <> T.pack (show k)))
          s1 <- right =<< summariseLog env n 1 (take 3 es) (newMem "summary" "claude" Set.empty "the first three")
          s2 <- right =<< summariseLog env n 1 (take 3 (drop 3 es)) (newMem "summary" "claude" Set.empty "the next three")
          levels <- right =<< readLevels env n
          map ids levels @?= [es, [s1, s2]]
          m2 <- maybe (fail "no s2") pure (lookup s2 (levels !! 1))
          memEdges m2 @?= Set.fromList (Edge Follows s1 : map (Edge DerivedFrom) (drop 3 es))
          unfolded <- right =<< unfoldMemory env s1
          ids unfolded @?= reverse (take 3 es),
      testCase "a summary of the wrong stretch is refused, and level 2 covers level 1" $
        withOpsEnv $ \_ env -> do
          n <- right (mkName "me/log")
          es <- forM [1 .. 4 :: Int] $ \k -> right =<< appendEpisode env n (newMem "note" "claude" Set.empty ("e" <> T.pack (show k)))
          bad <- summariseLog env n 1 (drop 2 es) (newMem "summary" "claude" Set.empty "x")
          isBadInput bad @?= True
          a <- right =<< summariseLog env n 1 (take 2 es) (newMem "summary" "claude" Set.empty "a")
          b <- right =<< summariseLog env n 1 (drop 2 es) (newMem "summary" "claude" Set.empty "b")
          top <- right =<< summariseLog env n 2 [a, b] (newMem "summary" "claude" Set.empty "all")
          levels <- right =<< readLevels env n
          map ids levels @?= [es, [a, b], [top]],
      testCase "unfold of a memory with no sources is an error" $
        withOpsEnv $ \_ env -> do
          n <- right (mkName "me/log")
          e <- right =<< appendEpisode env n (newMem "note" "claude" Set.empty "alone")
          r <- unfoldMemory env e
          isBadInput r @?= True
    ]
  where
    isBadInput :: Either AkyuuError a -> Bool
    isBadInput r = case r of
      Left (BadInput _) -> True
      _ -> False
