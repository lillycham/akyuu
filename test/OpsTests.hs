{-# LANGUAGE OverloadedStrings #-}

module OpsTests (opsTests, withOpsEnv, note) where

import Akyuu.Error
import Akyuu.GC (Tombstone (..))
import Akyuu.Graph (Dir (..), Edge (..), EdgeType (..))
import Akyuu.Id (render)
import Akyuu.Memory (Memory (..), parseMemory, renderMemory)
import Akyuu.Ops
import Akyuu.Query (Match (..), Neighbour (..), SearchResult (..), defaultSearchOptions)
import Akyuu.Refs (Expected (..), Ref (..), RefError (..), mkName)
import Akyuu.Store (StoreError (..), objectPath)
import Akyuu.Supersede (SupersedeError (..))
import Data.ByteString qualified as BS
import Data.Either (isLeft)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import Support (nid, right, withTempDir)
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))
import Test.Tasty
import Test.Tasty.HUnit
import Test.Tasty.QuickCheck

opsTests :: TestTree
opsTests =
  testGroup
    "Akyuu.Ops"
    [ pureCases
    , properties
    , envCases
    , opCases
    , verifyCases
    , errorTextCases
    ]

-- Helpers --------------------------------------------------------------

-- An open environment on a fresh directory.
withOpsEnv :: (FilePath -> Env -> IO a) -> IO a
withOpsEnv act = withTempDir $ \dir -> do
  r <- withEnv dir (\env -> Right <$> act dir env)
  right r

-- A new memory with this body and these edges.
note :: Text -> [Edge] -> NewMemory
note body es = NewMemory {newKind = "fact", newAgent = "claude", newEdges = Set.fromList es, newBody = body}

-- Pure part ------------------------------------------------------------

pureCases :: TestTree
pureCases =
  testGroup
    "pure"
    [ testCase "resolveRoot takes --root first" $
        resolveRoot (Just "/a") (Just "/b") @?= Right "/a"
    , testCase "resolveRoot takes AKYUU_ROOT second" $
        resolveRoot Nothing (Just "/b") @?= Right "/b"
    , testCase "resolveRoot gives NoRoot when neither is set" $
        resolveRoot Nothing Nothing @?= Left NoRoot
    , testCase "resolveRoot ignores an empty value" $
        resolveRoot (Just "") (Just "") @?= Left NoRoot
    , testCase "checkField accepts a plain value" $
        checkField "kind" "fact" @?= Right "fact"
    , testCase "checkField rejects an empty value" $
        checkField "kind" "" @?= Left (BadField "kind" "")
    , testCase "checkField rejects a line feed" $
        checkField "kind" "a\nb: c" @?= Left (BadField "kind" "a\nb: c")
    , testCase "checkField rejects a space at an end" $
        checkField "agent" " me" @?= Left (BadField "agent" " me")
    , testCase "checkField accepts a space inside" $
        checkField "kind" "a b" @?= Right "a b"
    , testCase "buildMemory cuts the time to whole seconds" $
        fmap memCreated (buildMemory (posixSecondsToUTCTime 100.75) (note "x" []))
          @?= Right (posixSecondsToUTCTime 100)
    , testCase "buildMemory checks the agent" $
        isLeft (buildMemory (posixSecondsToUTCTime 0) (note "x" []) {newAgent = "a\n"}) @?= True
    ]

properties :: TestTree
properties =
  testGroup
    "properties"
    [ testProperty "a memory that buildMemory accepts reads back the same" $
        \k a b -> case buildMemory (posixSecondsToUTCTime 1791201600) (NewMemory (T.pack k) (T.pack a) Set.empty (T.pack b)) of
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
          memKind m @?= "fact"
    , testCase "add rejects a bad kind" $
        withOpsEnv $ \_ env -> do
          r <- addMemory env (note "x" []) {newKind = ""}
          r @?= Left (BadField "kind" "")
    , testCase "get of a missing memory gives NotFound" $
        withOpsEnv $ \_ env -> do
          r <- getMemory env (nid 7)
          r @?= Left (StoreFailed (NotFound (nid 7)))
    , testCase "get of a pruned memory gives Pruned" $
        withOpsEnv $ \dir env -> do
          createDirectoryIfMissing True (dir </> "tombstones")
          BS.writeFile (dir </> "tombstones" </> T.unpack (render (nid 7))) "pruned: 2026-10-10T12:00:00Z\n"
          r <- getMemory env (nid 7)
          case r of
            Left (Pruned i (Tombstone _)) -> i @?= nid 7
            other -> assertFailure ("expected Pruned, got " <> show other)
    , testCase "setRefTo refuses an Id that is not in the store" $
        withOpsEnv $ \_ env -> do
          n <- right (mkName "claude/notes")
          r <- setRefTo env n MustBeAbsent (nid 7)
          r @?= Left (StoreFailed (NotFound (nid 7)))
    , testCase "setRefTo, readRef and supersede work together" $
        withOpsEnv $ \_ env -> do
          n <- right (mkName "claude/notes")
          v1 <- right =<< addMemory env (note "v1" [])
          _ <- right =<< setRefTo env n MustBeAbsent v1
          v2 <- right =<< supersedeMemory env n Nothing (note "v2" [])
          r <- right =<< readRef env n
          r @?= Ref v2 [v1]
          m <- right =<< getMemory env v2
          memEdges m @?= Set.singleton (Edge Supersedes v1)
    , testCase "supersede with a stale --expect gives Stale" $
        withOpsEnv $ \_ env -> do
          n <- right (mkName "claude/notes")
          v1 <- right =<< addMemory env (note "v1" [])
          _ <- right =<< setRefTo env n MustBeAbsent v1
          v2 <- right =<< supersedeMemory env n (Just v1) (note "v2" [])
          r <- supersedeMemory env n (Just v1) (note "v3" [])
          r @?= Left (RefFailed (Stale n (Just v2)))
    , testCase "listRefNames is sorted" $
        withOpsEnv $ \_ env -> do
          v <- right =<< addMemory env (note "v" [])
          ns <- traverse (right . mkName) ["b/x", "a/y", "c"]
          mapM_ (\n -> right =<< setRefTo env n Unchecked v) ns
          names <- right =<< listRefNames env
          names @?= [ns !! 1, ns !! 0, ns !! 2]
    , testCase "search finds a memory added after the cache opened" $
        withOpsEnv $ \_ env -> do
          i <- right =<< addMemory env (note "Lilly prefers Haskell" [])
          j <- right =<< addMemory env (note "about tools" [Edge About i])
          r <- right =<< searchMemories env defaultSearchOptions "haskell"
          map matchId (matches r) @?= [i]
          context r @?= Set.singleton j
    , testCase "neighboursOf shows both directions" $
        withOpsEnv $ \_ env -> do
          i <- right =<< addMemory env (note "a" [])
          j <- right =<< addMemory env (note "b" [Edge Refines i])
          ns <- right =<< neighboursOf env i
          ns @?= [Neighbour In Refines j]
    , testCase "neighboursOf an unknown Id gives NotFound" $
        withOpsEnv $ \_ env -> do
          r <- neighboursOf env (nid 7)
          r @?= Left (StoreFailed (NotFound (nid 7)))
    , testCase "neighboursOf a dangling target gives its edges" $
        withOpsEnv $ \_ env -> do
          j <- right =<< addMemory env (note "b" [Edge About (nid 7)])
          ns <- right =<< neighboursOf env (nid 7)
          ns @?= [Neighbour In About j]
    , testCase "a dry run plans nothing for a fresh memory" $
        withOpsEnv $ \_ env -> do
          _ <- right =<< addMemory env (note "a" [])
          p <- right =<< dryRunGC env
          p @?= Set.empty
    , testCase "reindex reads every memory" $
        withOpsEnv $ \_ env -> do
          _ <- right =<< addMemory env (note "apple" [])
          _ <- right =<< addMemory env (note "pear" [])
          _ <- right =<< runGC env
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
          checkedObjects r @?= 1
    , testCase "finds a corrupt object" $
        withOpsEnv $ \_ env -> do
          i <- right =<< addMemory env (note "a" [])
          BS.writeFile (objectPath (envStore env) i) "kind: fact\n\nchanged"
          r <- right =<< verifyStore env
          corruptObjects r @?= [i]
          verifyOk r @?= False
    , testCase "finds a missing target, and a pruned one is normal" $
        withOpsEnv $ \dir env -> do
          createDirectoryIfMissing True (dir </> "tombstones")
          BS.writeFile (dir </> "tombstones" </> T.unpack (render (nid 8))) "pruned: 2026-10-10T12:00:00Z\n"
          _ <- right =<< addMemory env (note "a" [Edge About (nid 7), Edge Supersedes (nid 8)])
          r <- right =<< verifyStore env
          missingTargets r @?= [nid 7]
          prunedTargets r @?= [nid 8]
    , testCase "finds a corrupt ref" $
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
          @?= "There is no memory " <> render (nid 1) <> " in the store."
    , testCase "Stale says where the ref points now" $ do
        n <- right (mkName "claude/notes")
        describe (RefFailed (Stale n (Just (nid 2))))
          @?= "The ref 'claude/notes' is not at the expected value. It points to " <> render (nid 2) <> " now. Read it again."
    , testCase "NoRoot says how to give a root" $
        describe NoRoot @?= "No store is given. Use --root DIR, or set AKYUU_ROOT."
    , testCase "no text is the Show form" $ do
        n <- right (mkName "x")
        let es = [StoreFailed (NotFound (nid 1)), RefFailed (NoSuchRef n), RefFailed Locked, NoRoot, BadField "kind" ""]
        mapM_ (\e -> assertBool (show e) (T.pack (show e) /= describe e)) es
    , testCase "fromSupersede keeps the inner error" $ do
        n <- right (mkName "x")
        fromSupersede (SupersedeRef (NoSuchRef n)) @?= RefFailed (NoSuchRef n)
        fromSupersede (SupersedeStore (NotFound (nid 1))) @?= StoreFailed (NotFound (nid 1))
    ]
