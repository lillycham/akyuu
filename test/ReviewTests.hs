{-# LANGUAGE OverloadedStrings #-}

module ReviewTests (reviewTests) where

import Akyuu.Review (Review (Review, reviewAgent, reviewNote), listReviews, pair, prune, review, reviewPath, unreview)
import Akyuu.Store (openStore)
import Control.Monad (void)
import Data.Set qualified as Set
import Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import Support (nid, right, withTempDir)
import System.Directory (doesFileExist)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

reviewTests :: TestTree
reviewTests =
  testGroup
    "Akyuu.Review"
    [ testCase "pair puts the lower id first" $ do
        pair (nid 2) (nid 1) @?= (nid 1, nid 2)
        pair (nid 1) (nid 2) @?= (nid 1, nid 2),
      testCase "a review is listed with its agent and note, in either order" $
        withTempDir $ \dir -> do
          s <- right =<< openStore dir
          right =<< review s (nid 2) (nid 1) (Review "claude" t0 "different ports")
          rs <- right =<< listReviews s
          [(p, reviewAgent r, reviewNote r) | (p, r) <- rs] @?= [((nid 1, nid 2), "claude", "different ports")],
      testCase "reviewing again replaces the first review" $
        withTempDir $ \dir -> do
          s <- right =<< openStore dir
          right =<< review s (nid 1) (nid 2) (Review "a" t0 "one")
          right =<< review s (nid 2) (nid 1) (Review "b" t0 "two")
          rs <- right =<< listReviews s
          map (reviewAgent . snd) rs @?= ["b"],
      testCase "unreview removes the file, and a missing one is not an error" $
        withTempDir $ \dir -> do
          s <- right =<< openStore dir
          right =<< review s (nid 1) (nid 2) (Review "a" t0 "")
          right =<< unreview s (nid 2) (nid 1)
          doesFileExist (reviewPath s (nid 1) (nid 2)) >>= (@?= False)
          right =<< unreview s (nid 1) (nid 2),
      testCase "no reviewed directory gives an empty list" $
        withTempDir $ \dir -> do
          s <- right =<< openStore dir
          rs <- right =<< listReviews s
          rs @?= [],
      testCase "prune removes the pairs that name a memory that is gone" $
        withTempDir $ \dir -> do
          s <- right =<< openStore dir
          void (right =<< review s (nid 1) (nid 2) (Review "a" t0 ""))
          void (right =<< review s (nid 1) (nid 3) (Review "a" t0 ""))
          gone <- right =<< prune s (Set.fromList [nid 1, nid 2])
          gone @?= [(nid 1, nid 3)]
          rs <- right =<< listReviews s
          map fst rs @?= [(nid 1, nid 2)]
    ]
  where
    t0 = posixSecondsToUTCTime 0
