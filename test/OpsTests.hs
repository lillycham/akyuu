{-# LANGUAGE OverloadedStrings #-}

module OpsTests (opsTests, withOpsEnv, note) where

import Akyuu.Amend (Edit (Append))
import Akyuu.Cache qualified as Cache
import Akyuu.Error (AkyuuError (AmbiguousPrefix, BadField, BadIdSpec, BadInput, GCFailed, NoRoot, NoSuchPrefix, Pruned, RefFailed, RootMissing, StoreFailed), describe, fromSupersede)
import Akyuu.GC (Policy (gracePeriod, keepGenerations, trashTTL), Tombstone (Tombstone), defaultPolicy)
import Akyuu.GC qualified as GC
import Akyuu.Graph (Dir (In, Out), Edge (Edge), EdgeType (About, Refines, Supersedes))
import Akyuu.Id (Id, render)
import Akyuu.Id qualified as Id
import Akyuu.Memory (Memory (memAboutRefs, memBody, memCreated, memEdges, memKind), parseMemory, renderMemory)
import Akyuu.Mutation (withMutation)
import Akyuu.Ops (Env (envCache, envStore), IdSpec (Full, Prefix), NewMemory (NewMemory, newAboutRefs, newAgent, newBody, newEdges, newKind), VerifyReport (badRefs, checkedObjects, corruptObjects, missingTargets, prunedTargets), addMemory, addUnderRef, amendMemory, buildMemory, checkField, dryRunGC, getMemory, listRefNames, listRefValues, neighboursOf, parseDuration, parseIdSpec, readRef, refLinksOf, reindexCache, resolveId, resolveRoot, runGC, searchMemories, setRefTo, supersedeMemory, verifyOk, verifyStore, withEnv)
import Akyuu.Ops qualified as Ops
import Akyuu.Query (Match (matchId), Neighbour (Neighbour), RefLink (RefLink), SearchResult (context, matches), defaultSearchOptions)
import Akyuu.Query qualified as Query
import Akyuu.Refs (Expected (MustBeAbsent, Unchecked), Name, Ref (Ref), RefError (Locked, NoSuchRef, Stale), mkName)
import Akyuu.Refs qualified as Refs
import Akyuu.Store (StoreError (NotFound), objectPath)
import Akyuu.Store qualified as Store
import Akyuu.Supersede (SupersedeError (SupersedeRef, SupersedeStore))
import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, readMVar, takeMVar)
import Control.Monad (forM)
import Data.ByteString qualified as BS
import Data.Either (isLeft)
import Data.List (sort)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (addUTCTime, getCurrentTime)
import Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import Support (nid, right, withTempDir)
import System.Directory (createDirectory, createDirectoryIfMissing, removeDirectory, removeFile)
import System.FilePath (takeDirectory, (</>))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))
import Test.Tasty.QuickCheck (Testable (property), testProperty, (===))

opsTests :: TestTree
opsTests =
  testGroup
    "Akyuu.Ops"
    [ pureCases,
      properties,
      envCases,
      opCases,
      publicationCases,
      verifyCases,
      aboutRefCases,
      errorTextCases
    ]

-- Helpers --------------------------------------------------------------

-- An open environment on a fresh directory.
withOpsEnv :: (FilePath -> Env -> IO a) -> IO a
withOpsEnv act = withTempDir $ \dir -> do
  r <- withEnv dir (\env -> Right <$> act dir env)
  right r

-- A new memory with this body and these edges.
note :: Text -> [Edge] -> NewMemory
note body es = NewMemory {newKind = "fact", newAgent = "claude", newEdges = Set.fromList es, newBody = body, newAboutRefs = Set.empty}

-- Make an empty file with the name of the object of an 'Id', so that
-- 'Akyuu.Store.list' sees it.
plant :: Env -> Id -> IO ()
plant env i = do
  let p = objectPath (envStore env) i
  createDirectoryIfMissing True (takeDirectory p)
  BS.writeFile p BS.empty

-- About-ref links -----------------------------------------------------

aboutRefCases :: TestTree
aboutRefCases =
  testGroup
    "about-ref links"
    [ testCase "a link to a ref that does not exist is refused, and nothing is added" $
        withOpsEnv $ \_ env -> do
          r <- addMemory env (linked "x" [topic])
          case r of
            Left (BadInput t) -> assertBool (T.unpack t) ("me/topic" `T.isInfixOf` t)
            other -> assertFailure (show other)
          listRefNames env >>= (@?= Right []),
      testCase "a memory keeps its links, and amend keeps them too" $
        withOpsEnv $ \_ env -> do
          _ <- right =<< addUnderRef env topic (note "the topic" [])
          i <- right =<< addUnderRef env notes (linked "about the topic" [topic])
          m <- right =<< getMemory env i
          memAboutRefs m @?= Set.singleton topic
          j <- right =<< amendMemory env notes (Just i) Nothing [Append "more"]
          m' <- right =<< getMemory env j
          memAboutRefs m' @?= Set.singleton topic,
      testCase "the links resolve in both directions, to the current value of the ref" $
        withOpsEnv $ \_ env -> do
          _ <- right =<< addUnderRef env topic (note "topic one" [])
          i <- right =<< addMemory env (linked "about the topic" [topic])
          t2 <- right =<< supersedeMemory env topic Nothing (note "topic two" [])
          refLinksOf env i >>= (@?= Right [RefLink Out topic (Just t2)])
          refLinksOf env t2 >>= (@?= Right [RefLink In topic (Just i)]),
      testCase "search puts the current memory of a linked ref in the context" $
        withOpsEnv $ \_ env -> do
          _ <- right =<< addUnderRef env topic (note "first text" [])
          t2 <- right =<< supersedeMemory env topic Nothing (note "second text" [])
          i <- right =<< addMemory env (linked "a lighthouse keeper" [topic])
          r <- right =<< searchMemories env defaultSearchOptions "lighthouse"
          map matchId (matches r) @?= [i]
          assertBool "the current memory of the ref is in the context" (t2 `Set.member` context r)
    ]
  where
    topic = name "me/topic"
    notes = name "me/notes"
    name t = either (error . show) id (mkName t)
    linked :: Text -> [Name] -> NewMemory
    linked body ns = (note body []) {newAboutRefs = Set.fromList ns}

-- Pure part ------------------------------------------------------------

pureCases :: TestTree
pureCases =
  testGroup
    "pure"
    [ testCase "parseIdSpec reads a whole id as Full" $
        parseIdSpec (render (nid 1)) @?= Right (Full (nid 1)),
      testCase "parseIdSpec reads sha256- and some digits as a prefix" $
        parseIdSpec "sha256-08d4" @?= Right (Prefix "sha256-08d4"),
      testCase "parseIdSpec adds sha256- to bare digits, and lowers the case" $
        parseIdSpec "08D4" @?= Right (Prefix "sha256-08d4"),
      testCase "parseIdSpec refuses fewer than 4 digits" $
        parseIdSpec "sha256-08d" @?= Left (BadIdSpec "sha256-08d"),
      testCase "parseIdSpec refuses a character that is not hex" $
        parseIdSpec "08dg" @?= Left (BadIdSpec "08dg"),
      testCase "parseIdSpec refuses a text that is longer than an id" $
        parseIdSpec (T.replicate 65 "a") @?= Left (BadIdSpec (T.replicate 65 "a")),
      testCase "parseIdSpec refuses an empty text" $
        parseIdSpec "" @?= Left (BadIdSpec ""),
      testCase "resolveRoot takes --root first" $
        resolveRoot (Just "/a") (Just "/b") @?= Right "/a",
      testCase "resolveRoot takes AKYUU_ROOT second" $
        resolveRoot Nothing (Just "/b") @?= Right "/b",
      testCase "resolveRoot gives NoRoot when neither is set" $
        resolveRoot Nothing Nothing @?= Left NoRoot,
      testCase "resolveRoot ignores an empty value" $
        resolveRoot (Just "") (Just "") @?= Left NoRoot,
      testCase "checkField accepts a plain value" $
        checkField "kind" "fact" @?= Right "fact",
      testCase "checkField rejects an empty value" $
        checkField "kind" "" @?= Left (BadField "kind" ""),
      testCase "checkField rejects a line feed" $
        checkField "kind" "a\nb: c" @?= Left (BadField "kind" "a\nb: c"),
      testCase "checkField rejects a space at an end" $
        checkField "agent" " me" @?= Left (BadField "agent" " me"),
      testCase "checkField accepts a space inside" $
        checkField "kind" "a b" @?= Right "a b",
      testCase "buildMemory cuts the time to whole seconds" $
        fmap memCreated (buildMemory (posixSecondsToUTCTime 100.75) (note "x" []))
          @?= Right (posixSecondsToUTCTime 100),
      testCase "buildMemory checks the agent" $
        isLeft (buildMemory (posixSecondsToUTCTime 0) (note "x" []) {newAgent = "a\n"}) @?= True
    ]

properties :: TestTree
properties =
  testGroup
    "properties"
    [ testProperty "a memory that buildMemory accepts reads back the same" $
        \k a b -> case buildMemory (posixSecondsToUTCTime 1791201600) (NewMemory (T.pack k) (T.pack a) Set.empty (T.pack b) Set.empty) of
          Left _ -> property True
          Right m -> parseMemory (renderMemory m) === Right m
    ]

-- The environment ------------------------------------------------------

envCases :: TestTree
envCases =
  testGroup
    "withEnv"
    [ testCase "gives RootMissing for a directory that does not exist" $
        withTempDir $ \dir -> do
          r <- withEnv (dir </> "nope") (\_ -> pure (Right ()))
          r @?= Left (RootMissing (dir </> "nope"))
    ]

-- Operations -----------------------------------------------------------

opCases :: TestTree
opCases =
  testGroup
    "operations"
    [ testCase "add, then get, gives the same memory" $
        withOpsEnv $ \_ env -> do
          i <- right =<< addMemory env (note "hello" [])
          m <- right =<< getMemory env i
          memBody m @?= "hello"
          memKind m @?= "fact",
      testCase "add rejects a bad kind" $
        withOpsEnv $ \_ env -> do
          r <- addMemory env (note "x" []) {newKind = ""}
          r @?= Left (BadField "kind" ""),
      testCase "get of a missing memory gives NotFound" $
        withOpsEnv $ \_ env -> do
          r <- getMemory env (nid 7)
          r @?= Left (StoreFailed (NotFound (nid 7))),
      testCase "get of a pruned memory gives Pruned" $
        withOpsEnv $ \dir env -> do
          createDirectoryIfMissing True (dir </> "tombstones")
          BS.writeFile (dir </> "tombstones" </> T.unpack (render (nid 7))) "pruned: 2026-10-10T12:00:00Z\n"
          r <- getMemory env (nid 7)
          case r of
            Left (Pruned i (Tombstone _) _) -> i @?= nid 7
            other -> assertFailure ("expected Pruned, got " <> show other),
      testCase "a deleted memory that was superseded names the newer memory" $
        withOpsEnv $ \_ env -> do
          n <- right (mkName "claude/notes")
          v1 <- right =<< addMemory env (note "v1" [])
          _ <- right =<< setRefTo env n MustBeAbsent v1
          v2 <- right =<< supersedeMemory env n Nothing (note "v2" [])
          now <- getCurrentTime
          let p = defaultPolicy {gracePeriod = 0, trashTTL = 0, keepGenerations = 0}
              doomed = Set.singleton v1
          -- The first run moves v1 to trash. The second one deletes it.
          _ <- right =<< GC.sweepAndSync (envCache env) (envStore env) p (addUTCTime 2 now) doomed
          _ <- right =<< GC.sweepAndSync (envCache env) (envStore env) p (addUTCTime 4 now) Set.empty
          r <- getMemory env v1
          case r of
            Left e@(Pruned i _ newer) -> do
              i @?= v1
              newer @?= Set.singleton v2
              assertBool "the text names the newer memory" (render v2 `T.isInfixOf` describe e)
            other -> assertFailure ("expected Pruned, got " <> show other)
          -- The edge of v2 stays, so the deleted memory still has a neighbour.
          ns <- right =<< neighboursOf env v1
          ns @?= [Neighbour In Supersedes v2],
      testCase "setRefTo refuses an Id that is not in the store" $
        withOpsEnv $ \_ env -> do
          n <- right (mkName "claude/notes")
          r <- setRefTo env n MustBeAbsent (nid 7)
          r @?= Left (StoreFailed (NotFound (nid 7))),
      testCase "setRefTo, readRef and supersede work together" $
        withOpsEnv $ \_ env -> do
          n <- right (mkName "claude/notes")
          v1 <- right =<< addMemory env (note "v1" [])
          _ <- right =<< setRefTo env n MustBeAbsent v1
          v2 <- right =<< supersedeMemory env n Nothing (note "v2" [])
          r <- right =<< readRef env n
          r @?= Ref v2 [v1]
          m <- right =<< getMemory env v2
          memEdges m @?= Set.singleton (Edge Supersedes v1),
      testCase "supersede with a stale --expect gives Stale" $
        withOpsEnv $ \_ env -> do
          n <- right (mkName "claude/notes")
          v1 <- right =<< addMemory env (note "v1" [])
          _ <- right =<< setRefTo env n MustBeAbsent v1
          v2 <- right =<< supersedeMemory env n (Just v1) (note "v2" [])
          r <- supersedeMemory env n (Just v1) (note "v3" [])
          r @?= Left (RefFailed (Stale n (Just v2))),
      testCase "listRefNames is sorted" $
        withOpsEnv $ \_ env -> do
          v <- right =<< addMemory env (note "v" [])
          ns <- traverse (right . mkName) ["b/x", "a/y", "c"]
          mapM_ (\n -> right =<< setRefTo env n Unchecked v) ns
          names <- right =<< listRefNames env
          names @?= [ns !! 1, ns !! 0, ns !! 2],
      testCase "listRefValues gives each name with its id, sorted" $
        withOpsEnv $ \_ env -> do
          v <- right =<< addMemory env (note "v" [])
          w <- right =<< addMemory env (note "w" [])
          [nb, na] <- traverse (right . mkName) ["b/x", "a"]
          _ <- right =<< setRefTo env nb Unchecked v
          _ <- right =<< setRefTo env na Unchecked w
          vals <- right =<< listRefValues env
          vals @?= [(na, w), (nb, v)],
      testCase "listRefValues of a store with no refs is empty" $
        withOpsEnv $
          \_ env -> listRefValues env >>= (@?= Right []),
      testCase "resolveId passes a whole id through, even if it is not in the store" $
        withOpsEnv $ \_ env ->
          resolveId env (Full (nid 7)) >>= (@?= Right (nid 7)),
      testCase "resolveId finds the one memory that a prefix names" $
        withOpsEnv $ \_ env -> do
          i <- right =<< addMemory env (note "one" [])
          _ <- right =<< addMemory env (note "two" [])
          resolveId env (Prefix (T.take 12 (render i))) >>= (@?= Right i),
      testCase "resolveId says when no memory has the prefix" $
        withOpsEnv $ \_ env -> do
          _ <- right =<< addMemory env (note "one" [])
          resolveId env (Prefix "sha256-ffffffff") >>= (@?= Left (NoSuchPrefix "sha256-ffffffff")),
      testCase "resolveId lists the matches when a prefix is ambiguous" $
        withOpsEnv $ \_ env -> do
          -- Two names that share a long start. Only the file names matter
          -- to 'resolveId', so the files can be empty.
          let a = nid 170
              b = either (error . show) id (Id.parse ("sha256-" <> T.replicate 62 "a" <> "bb"))
          mapM_ (plant env) [a, b]
          r <- resolveId env (Prefix "sha256-aaaa")
          r @?= Left (AmbiguousPrefix "sha256-aaaa" (sort [a, b])),
      testCase "search finds a memory added after the cache opened" $
        withOpsEnv $ \_ env -> do
          i <- right =<< addMemory env (note "Lilly prefers Haskell" [])
          j <- right =<< addMemory env (note "about tools" [Edge About i])
          r <- right =<< searchMemories env defaultSearchOptions "haskell"
          map matchId (matches r) @?= [i]
          context r @?= Set.singleton j,
      testCase "neighboursOf shows both directions" $
        withOpsEnv $ \_ env -> do
          i <- right =<< addMemory env (note "a" [])
          j <- right =<< addMemory env (note "b" [Edge Refines i])
          ns <- right =<< neighboursOf env i
          ns @?= [Neighbour In Refines j],
      testCase "neighboursOf an unknown Id gives NotFound" $
        withOpsEnv $ \_ env -> do
          r <- neighboursOf env (nid 7)
          r @?= Left (StoreFailed (NotFound (nid 7))),
      testCase "neighboursOf a dangling target gives its edges" $
        withOpsEnv $ \_ env -> do
          j <- right =<< addMemory env (note "b" [Edge About (nid 7)])
          ns <- right =<< neighboursOf env (nid 7)
          ns @?= [Neighbour In About j],
      testCase "a dry run plans nothing for a fresh memory" $
        withOpsEnv $ \_ env -> do
          _ <- right =<< addMemory env (note "a" [])
          p <- right =<< dryRunGC env defaultPolicy
          p @?= Set.empty,
      testCase "a dry run uses the policy that it gets" $
        withOpsEnv $ \_ env -> do
          i <- right =<< addMemory env (note "a" [])
          p <- right =<< dryRunGC env defaultPolicy {gracePeriod = 0}
          p @?= Set.singleton i,
      testCase "parseDuration reads a number and a unit" $
        map parseDuration ["0s", "45s", "30m", "1h", "7d"]
          @?= map Right [0, 45, 1800, 3600, 7 * 86400],
      testCase "parseDuration refuses a bad length of time" $
        mapM_
          (\t -> assertBool (T.unpack t) (isLeft (parseDuration t)))
          ["", "30", "m", "1.5h", "-1h", "1 h", "1w", "h1", "1hh"],
      testCase "reindex reads every memory" $
        withOpsEnv $ \_ env -> do
          _ <- right =<< addMemory env (note "apple" [])
          _ <- right =<< addMemory env (note "pear" [])
          _ <- right =<< runGC env defaultPolicy
          _ <- right =<< reindexCache env
          r <- right =<< searchMemories env defaultSearchOptions "apple"
          length (matches r) @?= 1
    ]

-- Verify ---------------------------------------------------------------

verifyCases :: TestTree
verifyCases =
  testGroup
    "verifyStore"
    [ testCase "a sound store is ok" $
        withOpsEnv $ \_ env -> do
          _ <- right =<< addMemory env (note "a" [])
          r <- right =<< verifyStore env
          verifyOk r @?= True
          checkedObjects r @?= 1,
      testCase "finds a corrupt object" $
        withOpsEnv $ \_ env -> do
          i <- right =<< addMemory env (note "a" [])
          BS.writeFile (objectPath (envStore env) i) "kind: fact\n\nchanged"
          r <- right =<< verifyStore env
          corruptObjects r @?= [i]
          verifyOk r @?= False,
      testCase "finds a missing target, and a pruned one is normal" $
        withOpsEnv $ \dir env -> do
          createDirectoryIfMissing True (dir </> "tombstones")
          BS.writeFile (dir </> "tombstones" </> T.unpack (render (nid 8))) "pruned: 2026-10-10T12:00:00Z\n"
          _ <- right =<< addMemory env (note "a" [Edge About (nid 7), Edge Supersedes (nid 8)])
          r <- right =<< verifyStore env
          missingTargets r @?= [nid 7]
          prunedTargets r @?= [nid 8],
      testCase "finds a corrupt ref" $
        withOpsEnv $ \dir env -> do
          n <- right (mkName "bad")
          BS.writeFile (dir </> "refs" </> "bad") "nonsense\n"
          r <- right =<< verifyStore env
          map fst (badRefs r) @?= [n]
          verifyOk r @?= False
    ]

-- Error text -----------------------------------------------------------

errorTextCases :: TestTree
errorTextCases =
  testGroup
    "describe"
    [ testCase "NotFound names the Id" $
        describe (StoreFailed (NotFound (nid 1)))
          @?= "There is no memory " <> render (nid 1) <> " in the store.",
      testCase "Stale says where the ref points now" $ do
        n <- right (mkName "claude/notes")
        describe (RefFailed (Stale n (Just (nid 2))))
          @?= "The ref 'claude/notes' is not at the expected value. It points to " <> render (nid 2) <> " now. Read it again.",
      testCase "NoRoot says how to give a root" $
        describe NoRoot @?= "No store is given. Use --root DIR, set AKYUU_ROOT, or set root in the config file (see akyuu config).",
      testCase "no text is the Show form" $ do
        n <- right (mkName "x")
        let es = [StoreFailed (NotFound (nid 1)), RefFailed (NoSuchRef n), RefFailed Locked, NoRoot, BadField "kind" ""]
        mapM_ (\e -> assertBool (show e) (T.pack (show e) /= describe e)) es,
      testCase "fromSupersede keeps the inner error" $ do
        n <- right (mkName "x")
        fromSupersede (SupersedeRef (NoSuchRef n)) @?= RefFailed (NoSuchRef n)
        fromSupersede (SupersedeStore (NotFound (nid 1))) @?= StoreFailed (NotFound (nid 1))
    ]

-- Publication and collection -------------------------------------------

publicationCases :: TestTree
publicationCases =
  testGroup
    "publication"
    [ testCase "stale proposals affect neither search nor version resolution" $
        withOpsEnv $ \_ env -> do
          let n = named "me/topic"
          v1 <- right =<< addUnderRef env n (note "initial" [])
          accepted <- right =<< supersedeMemory env n (Just v1) (note "accepted" [])
          rejected <- supersedeMemory env n (Just v1) (note "rejected proposal" [])
          rejected @?= Left (RefFailed (Stale n (Just accepted)))
          hits <- right =<< searchMemories env defaultSearchOptions "rejected"
          matches hits @?= []
          graph <- right =<< Cache.loadGraph (envCache env)
          Query.resolve v1 graph @?= Set.singleton accepted,
      testCase "concurrent supersessions publish only the successful proposal" $
        withOpsEnv $ \_ env -> do
          let n = named "me/topic"
          v1 <- right =<< addUnderRef env n (note "initial" [])
          results <- together [supersedeMemory env n (Just v1) (note body []) | body <- ["proposal alpha", "proposal beta"]]
          let accepted = [i | Right i <- results]
          case accepted of
            [winner] -> do
              let losers = [e | Left e <- results]
              losers @?= [RefFailed (Stale n (Just winner))]
              hits <- right =<< searchMemories env defaultSearchOptions "proposal"
              map matchId (matches hits) @?= [winner]
              graph <- right =<< Cache.loadGraph (envCache env)
              Query.resolve v1 graph @?= Set.singleton winner
            _ -> assertFailure (show results),
      testCase "concurrent reference creation publishes only the winner" $
        withOpsEnv $ \_ env -> do
          let n = named "me/topic"
          results <- together [addUnderRef env n (note body []) | body <- ["proposal alpha", "proposal beta"]]
          case [i | Right i <- results] of
            [winner] -> do
              hits <- right =<< searchMemories env defaultSearchOptions "proposal"
              map matchId (matches hits) @?= [winner]
              readRef env n >>= (@?= Right (Ref winner []))
              length [() | Left (BadInput _) <- results] @?= 1
            _ -> assertFailure (show results),
      testCase "reference name conflicts reject before object publication" $
        withOpsEnv $ \_ env -> do
          _ <- right =<< addUnderRef env (named "me/topic") (note "existing" [])
          let child = named "me/topic/child"
          addUnderRef env child (note "rejected child" []) >>= (@?= Left (RefFailed (Refs.NameConflict child)))
          _ <- right =<< addUnderRef env (named "me/other/child") (note "existing child" [])
          let parent = named "me/other"
          addUnderRef env parent (note "rejected parent" []) >>= (@?= Left (RefFailed (Refs.NameConflict parent)))
          hits <- right =<< searchMemories env defaultSearchOptions "rejected"
          matches hits @?= [],
      testCase "a rejected nested reference does not reserve its parent name" $
        withOpsEnv $ \_ env -> do
          let parent = named "me/topic"
              child = named "me/topic/child"
          setRefTo env child MustBeAbsent (nid 7) >>= (@?= Left (StoreFailed (NotFound (nid 7))))
          i <- right =<< addUnderRef env parent (note "valid parent" [])
          readRef env parent >>= (@?= Right (Ref i [])),
      testCase "failed object publication does not reserve the reference namespace" $
        withOpsEnv $ \dir env -> do
          let parent = named "me/topic"
              child = named "me/topic/child"
              objects = dir </> "store"
          removeDirectory objects
          BS.writeFile objects "not a directory"
          result <- addUnderRef env child (note "cannot store this" [])
          case result of
            Left (StoreFailed (Store.StoreIO _)) -> pure ()
            _ -> assertFailure (show result)
          removeFile objects
          createDirectory objects
          i <- right =<< addUnderRef env parent (note "valid parent" [])
          readRef env parent >>= (@?= Right (Ref i [])),
      testCase "a collection that wins first makes reference updates and pins fail" $
        withOpsEnv $ \_ env -> do
          i <- right =<< addMemory env (note "unretained" [])
          original <- right =<< getMemory env i
          let p = defaultPolicy {gracePeriod = 0}
              n = named "me/topic"
          _ <- right =<< runGC env p
          update <- setRefTo env n MustBeAbsent i
          pinned <- Ops.pinMemory env i
          case (update, pinned) of
            (Left (StoreFailed (NotFound a)), Left (StoreFailed (NotFound b))) -> (a, b) @?= (i, i)
            _ -> assertFailure (show (update, pinned))
          readRef env n >>= (@?= Left (RefFailed (NoSuchRef n)))
          _ <- right =<< Store.add (envStore env) original
          _ <- right =<< setRefTo env n MustBeAbsent i
          _ <- right =<< runGC env p
          getMemory env i >>= (@?= Right original),
      testCase "object writes, reference updates and pins cannot pass a held GC lock" $
        withOpsEnv $ \_ env -> do
          i <- right =<< addMemory env (note "candidate" [])
          let n = named "me/topic"
          held <- GC.withGCLock (envStore env) $ \_ -> do
            addMemory env (note "blocked" []) >>= (@?= Left (StoreFailed Store.StoreLocked))
            setRefTo env n MustBeAbsent i >>= (@?= Left (RefFailed Locked))
            Ops.pinMemory env i >>= (@?= Left (GCFailed GC.GCLocked))
            pure (Right ())
          right held
          _ <- right =<< setRefTo env n MustBeAbsent i
          _ <- right =<< runGC env defaultPolicy {gracePeriod = 0}
          m <- right =<< getMemory env i
          memBody m @?= "candidate",
      testCase "a failed mutation releases its lock for the next writer" $
        withOpsEnv $ \dir env -> do
          result <- withMutation dir (RefFailed Locked) (RefFailed . Refs.RefIO) (\_ -> ioError (userError "injected failure")) :: IO (Either AkyuuError ())
          case result of
            Left (RefFailed (Refs.RefIO _)) -> pure ()
            _ -> assertFailure (show result)
          i <- right =<< addUnderRef env (named "me/topic") (note "after failure" [])
          _ <- right =<< runGC env defaultPolicy {gracePeriod = 0}
          m <- right =<< getMemory env i
          memBody m @?= "after failure"
    ]
  where
    named = either (error . show) id . mkName
    together actions = do
      start <- newEmptyMVar
      outputs <- forM actions $ \action -> do
        output <- newEmptyMVar
        _ <- forkIO (readMVar start >> action >>= putMVar output)
        pure output
      putMVar start ()
      mapM takeMVar outputs
