{-# LANGUAGE OverloadedStrings #-}

module LevelsTests (levelsTests) where

import Akyuu.Error (AkyuuError (BadInput, LogInterrupted, RefFailed))
import Akyuu.Graph (Edge (Edge), EdgeType (DerivedFrom, Follows))
import Akyuu.Id (Id)
import Akyuu.Levels (Chain, Item (Brief, Episode, Summary), Run (runFrom, runLevel, runMemories, runTo), chainOrder, checkSources, fit, levelRef, resolution, todo)
import Akyuu.Memory (Memory (memBody, memCreated, memEdges))
import Akyuu.Ops (Env (envRefs, envStore), appendEpisode, readLevels, readRef, summariseLog, unfoldMemory)
import Akyuu.Refs (RefError (CorruptRef, NoSuchRef, RefIO), mkName, nameText, refPath)
import Akyuu.Store (StoreError (Corrupt, NotFound), objectPath)
import Control.Monad (forM)
import Data.ByteString qualified as BS
import Data.Either (isLeft)
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Time (UTCTime, addUTCTime)
import Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import OpsTests (withOpsEnv)
import Support (newMem, nid, right, testMemory)
import System.Directory (createFileLink, removeFile)
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
      testCase "a summary whose episodes are not in the walk does not crash" $ do
        -- The walk of level 0 stopped early: it holds none of the episodes.
        let l1 = [summary 101 Nothing [1, 2], summary 102 (Just 101) [3, 4]]
        map runLevel (todo 2 0 [[], l1]) @?= [2]
        length (resolution True 0 [[], l1]) @?= 0
        length (resolution True 0 [take 1 (drop 4 (episodes 5)), l1]) @?= 1,
      testCase "a run of summaries spans the times of the episodes under it" $ do
        let l1 = [summary 101 Nothing [1, 2, 3], summary 102 (Just 101) [4, 5, 6]]
            minute :: Int -> UTCTime
            minute k = addUTCTime (fromIntegral (60 * k)) noon
        [(runFrom r, runTo r) | r <- todo 2 0 [episodes 6, l1], runLevel r == 2] @?= [(minute 1, minute 6)],
      testCase "the sources must be the oldest that no summary covers" $ do
        let levels = [episodes 6, [summary 101 Nothing [1, 2]]]
        checkSources 1 [nid 4, nid 3] levels @?= Right ()
        assertBool "a later stretch" (isLeft (checkSources 1 [nid 4, nid 5] levels))
        assertBool "a covered one" (isLeft (checkSources 1 [nid 2, nid 3] levels))
        assertBool "only one" (isLeft (checkSources 1 [nid 3] levels))
        assertBool "level 0" (isLeft (checkSources 0 [nid 3, nid 4] levels))
        assertBool "a level with nothing below" (isLeft (checkSources 3 [nid 101, nid 102] levels)),
      testCase "resolution shows episodes whole, or old ones as lines, and the highest summaries" $ do
        let l1 = [summary 101 Nothing [1, 2], summary 102 (Just 101) [3, 4]]
            l2 = [summary 201 Nothing [101, 102]]
            shape (Episode i _) = ("whole", i)
            shape (Brief i _) = ("line", i)
            shape (Summary k i _ n _ _) = ("level " <> T.pack (show k) <> " of " <> T.pack (show n), i)
        map shape (resolution True 2 [episodes 7, l1, l2])
          @?= [("whole", nid 7), ("whole", nid 6), ("whole", nid 5), ("level 2 of 4", nid 201)]
        map shape (resolution False 2 [episodes 7, l1, l2])
          @?= [("whole", nid 7), ("whole", nid 6), ("line", nid 5), ("level 2 of 4", nid 201)],
      testCase "fit shows everything whole, then old episodes as lines and fewer whole, or says what it needs" $ do
        let render = T.concat . map (\it -> case it of Episode _ m -> memBody m <> T.replicate 50 "."; Brief _ _ -> "b"; Summary {} -> "s")
            levels = [episodes 5]
        fmap T.length (fit render 1000 2 levels) @?= Right (T.length (render (resolution True 2 levels)))
        fit render 150 2 levels @?= Right (render (resolution False 2 levels))
        fit render 5 2 levels @?= Right "bbbbb"
        fit render 3 2 levels @?= Left 5,
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
          isBadInput r @?= True,
      testCase "a missing oldest episode cannot become a new summary prefix" $
        withOpsEnv $ \_ env -> do
          n <- right (mkName "me/log")
          first : rest <- forM ["oldest", "middle", "newest"] $ \body -> right =<< appendEpisode env n (newMem "note" "agent" Set.empty body)
          removeFile (objectPath (envStore env) first)
          levels <- readLevels env n
          levels @?= Left (LogInterrupted first (NotFound first))
          summaryResult <- summariseLog env n 1 rest (newMem "summary" "agent" Set.empty "must not publish")
          summaryResult @?= Left (LogInterrupted first (NotFound first))
          l1 <- right (levelRef n 1)
          readRef env l1 >>= (@?= Left (RefFailed (NoSuchRef l1))),
      testCase "corrupt base history is rejected before a summary is published" $
        withOpsEnv $ \_ env -> do
          n <- right (mkName "me/log")
          first : rest <- forM ["oldest", "middle", "newest"] $ \body -> right =<< appendEpisode env n (newMem "note" "agent" Set.empty body)
          BS.writeFile (objectPath (envStore env) first) "damaged"
          readLevels env n >>= (@?= Left (LogInterrupted first (Corrupt first)))
          summariseLog env n 1 rest (newMem "summary" "agent" Set.empty "must not publish")
            >>= (@?= Left (LogInterrupted first (Corrupt first)))
          l1 <- right (levelRef n 1)
          readRef env l1 >>= (@?= Left (RefFailed (NoSuchRef l1))),
      testCase "an incomplete summary chain cannot be summarised at the next level" $
        withOpsEnv $ \_ env -> do
          n <- right (mkName "me/log")
          es <- forM [1 .. 6 :: Int] $ \k -> right =<< appendEpisode env n (newMem "note" "agent" Set.empty (T.pack (show k)))
          first : rest <- forM [0, 2, 4] $ \offset ->
            right =<< summariseLog env n 1 (take 2 (drop offset es)) (newMem "summary" "agent" Set.empty (T.pack (show offset)))
          removeFile (objectPath (envStore env) first)
          readLevels env n >>= (@?= Left (LogInterrupted first (NotFound first)))
          summariseLog env n 2 rest (newMem "summary" "agent" Set.empty "must not publish")
            >>= (@?= Left (LogInterrupted first (NotFound first)))
          l2 <- right (levelRef n 2)
          readRef env l2 >>= (@?= Left (RefFailed (NoSuchRef l2))),
      testCase "a corrupt higher-level ref is an error, not an absent level" $
        withOpsEnv $ \_ env -> do
          n <- right (mkName "me/log")
          es <- forM ["first", "second"] $ \body -> right =<< appendEpisode env n (newMem "note" "agent" Set.empty body)
          l1 <- right (levelRef n 1)
          let path = refPath (envRefs env) l1
          BS.writeFile path "damaged"
          levels <- readLevels env n
          case levels of
            Left (RefFailed (CorruptRef failed _)) -> failed @?= l1
            other -> fail ("expected corrupt level ref, got " <> show other)
          published <- summariseLog env n 1 es (newMem "summary" "agent" Set.empty "must not publish")
          case published of
            Left (RefFailed (CorruptRef failed _)) -> failed @?= l1
            other -> fail ("expected corrupt level ref, got " <> show other)
          BS.readFile path >>= (@?= "damaged"),
      testCase "a higher-level ref IO failure is an error, not an absent level" $
        withOpsEnv $ \_ env -> do
          n <- right (mkName "me/log")
          _ <- right =<< appendEpisode env n (newMem "note" "agent" Set.empty "first")
          l1 <- right (levelRef n 1)
          let path = refPath (envRefs env) l1
          createFileLink path path
          levels <- readLevels env n
          case levels of
            Left (RefFailed (RefIO _)) -> pure ()
            other -> fail ("expected level ref IO error, got " <> show other)
    ]
  where
    isBadInput :: Either AkyuuError a -> Bool
    isBadInput r = case r of
      Left (BadInput _) -> True
      _ -> False
