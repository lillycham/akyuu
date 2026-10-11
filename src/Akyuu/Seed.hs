-- | A demo store, for the web UI and for tests: @akyuu seed --demo@.
--
-- 'seedDemo' fills an empty directory with a small store that has one of
-- each thing that the UI can show:
--
-- * supersede chains, and a ref with more generations than GC keeps;
-- * a fork: two memories that supersede one;
-- * an edge to an object that was never stored (a missing target);
-- * a memory that GC deleted, with a tombstone, and one that is in trash;
-- * a pin, a memory that a retaining edge keeps, and young memories;
-- * several kinds and agents, and refs with history.
--
-- It uses the functions of the library: 'Akyuu.Store.add',
-- 'Akyuu.Supersede.supersedeFrom', 'Akyuu.Refs.setRef', 'Akyuu.GC.pin' and
-- 'Akyuu.GC.sweep'. To make old objects without a wait, it gives them a
-- @created@ time in the past and sets their file time to it. The prune uses
-- 'Akyuu.GC.sweep' with a policy whose trash time is 0, and a run time one
-- second after now.
module Akyuu.Seed
  ( Demo (..),
    seedDemo,
    checkEmptyRoot,
    demoLines,
  )
where

import Akyuu.Cache qualified as Cache
import Akyuu.Error (AkyuuError (BadInput, BadName, CacheFailed, GCFailed, RefFailed, StoreFailed), fromSupersede)
import Akyuu.GC (Policy (trashTTL), defaultPolicy)
import Akyuu.GC qualified as GC
import Akyuu.Graph (Edge (Edge), EdgeType (About, DerivedFrom, Refines, Supersedes))
import Akyuu.Id (Id, hashBytes, render)
import Akyuu.Ops (Env (envCache, envRefs, envStore), NewMemory (NewMemory), buildMemory, withEnv)
import Akyuu.Refs (Expected (MustBeAbsent), Name, mkName)
import Akyuu.Refs qualified as Refs
import Akyuu.Store qualified as Store
import Akyuu.Supersede (supersedeFrom)
import Control.Exception (IOException, try)
import Control.Monad (foldM, forM_, unless)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Trans.Except (ExceptT (ExceptT), except, runExceptT, throwE, withExceptT)
import Data.Bifunctor (first)
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.List (isPrefixOf, isSuffixOf, sortOn)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime, addUTCTime, nominalDay)
import System.Directory
  ( createDirectory,
    doesDirectoryExist,
    doesPathExist,
    listDirectory,
    setModificationTime,
  )
import System.FilePath ((</>))

-- | What 'seedDemo' made. The tests use these ids to check the views.
data Demo = Demo
  { -- | Every ref, with its values, current first.
    demoRefs :: [(Text, [Id])],
    -- | GC deleted this memory. It has a tombstone, and a memory still has
    -- an edge to it.
    demoPruned :: Id,
    -- | GC moved this memory to trash. Phase 2 of a sweep deletes it after
    -- the trash time.
    demoTrashed :: Id,
    -- | A pin keeps this old memory, and nothing else does.
    demoPinned :: Id,
    -- | A memory has an edge to this 'Id', but it was never stored.
    demoMissing :: Id,
    -- | The fork: the old memory, and the two memories that supersede it.
    demoFork :: (Id, Id, Id),
    -- | An old memory that only a retaining edge keeps, and the memory with
    -- that edge.
    demoRetained :: (Id, Id),
    -- | The old memories that nothing keeps: a GC run now collects them.
    demoGarbage :: [Id],
    -- | Young memories that no root holds. The grace period keeps them.
    demoYoung :: [Id],
    -- | Every memory that is in the store at the end.
    demoStored :: [Id]
  }
  deriving (Eq, Show)

-- | Check that a directory can get a demo store.
--
-- The directory must not exist, or it must be empty, or it may hold only an
-- empty store: the directories and files of a store with no objects, no
-- refs, no pins, nothing in trash and no tombstones. Anything else gives
-- 'BadInput', and nothing changes. A store with data is never touched.
checkEmptyRoot :: FilePath -> IO (Either AkyuuError ())
checkEmptyRoot root = do
  there <- doesPathExist root
  if not there
    then pure (Right ())
    else do
      isDir <- doesDirectoryExist root
      if not isDir
        then pure (Left (BadInput (T.pack root <> " is not a directory.")))
        else do
          r <- try (contents root)
          pure $ case r of
            Left e -> Left (BadInput ("The directory " <> T.pack root <> " could not be read: " <> T.pack (show (e :: IOException))))
            Right [] -> Right ()
            Right found ->
              Left
                ( BadInput
                    ( "The directory "
                        <> T.pack root
                        <> " is not empty: it has "
                        <> T.intercalate ", " (map T.pack (take 5 found))
                        <> ". seed --demo only fills an empty directory or an empty store."
                    )
                )
  where
    -- The entries that are not part of an empty store.
    contents dir = do
      names <- listDirectory dir
      concat <$> traverse (entry dir) names
    entry dir n
      | n `elem` ["store", "trash", "refs", "pins", "tombstones"] = do
          files <- deep (dir </> n)
          pure (map ((n </>)) (filter (not . lockOrTemp) files))
      | n == "gc.lock" || n == ".DS_Store" || "cache.sqlite" `isPrefixOf` n = pure []
      | otherwise = pure [n]
    lockOrTemp f = f == ".lock" || ".tmp" `isPrefixOf` f || ".DS_Store" `isSuffixOf` f
    -- Every file under a directory, by its path from that directory.
    deep d = do
      isDir <- doesDirectoryExist d
      if not isDir
        then pure ["."]
        else do
          names <- listDirectory d
          concat
            <$> traverse
              ( \n -> do
                  sub <- doesDirectoryExist (d </> n)
                  if sub then map (n </>) <$> deep (d </> n) else pure [n]
              )
              names

-- | Make the demo store in a directory, at the time @now@.
--
-- The directory is made if it is not there. Its parent must exist. See
-- 'checkEmptyRoot' for the directories that are refused. At the end the
-- cache is in sync with the store.
seedDemo :: FilePath -> UTCTime -> IO (Either AkyuuError Demo)
seedDemo root now = runExceptT $ do
  ExceptT (checkEmptyRoot root)
  exists <- liftIO (doesDirectoryExist root)
  unless exists $ do
    made <- liftIO (try (createDirectory root))
    either (\e -> throwE (BadInput ("The directory could not be made: " <> T.pack (show (e :: IOException))))) pure made
  ExceptT (withEnv root (runExceptT . fill now))

-- | The memories of the demo, and what is done to them. This runs inside
-- 'withEnv'.
fill :: UTCTime -> Env -> ExceptT AkyuuError IO Demo
fill now env = do
  oldOnes <- liftIO (newIORef [])
  let s = envStore env
      rs = envRefs env
      base = addUTCTime (-30 * nominalDay) now
      day d = addUTCTime (d * nominalDay) base
      mins m = addUTCTime (negate (m * 60)) now
      memAt t kind agent es body = except (buildMemory t (NewMemory kind agent (Set.fromList es) body))
      -- An old memory: its created time and its file time are in the past.
      old t kind agent es body = do
        m <- memAt t kind agent es body
        i <- withExceptT StoreFailed (ExceptT (Store.add s m))
        liftIO (modifyIORef' oldOnes ((i, t) :))
        pure i
      young t kind agent es body = do
        m <- memAt t kind agent es body
        withExceptT StoreFailed (ExceptT (Store.add s m))
      name t = except (first (BadName t) (mkName t))
      newRef t i = do
        n <- name t
        _ <- withExceptT RefFailed (ExceptT (Refs.setRef rs n MustBeAbsent i))
        pure n
      -- Supersede the ref from its current value, with an old memory.
      supersedeOld :: Name -> Id -> UTCTime -> Text -> Text -> [Edge] -> Text -> ExceptT AkyuuError IO Id
      supersedeOld n cur t kind agent es body = do
        m <- memAt t kind agent es body
        i <- withExceptT fromSupersede (ExceptT (supersedeFrom s rs n cur m))
        liftIO (modifyIORef' oldOnes ((i, t) :))
        pure i

  -- A preference, superseded twice: claude/lang.
  l1 <- old (day 0) "preference" "claude" [] "Lilly prefers Haskell for tools."
  lang <- newRef "claude/lang" l1
  l2 <- supersedeOld lang l1 (day 3) "preference" "claude" [] "Lilly prefers Haskell for tools, and Nix for every dependency."
  l3 <- supersedeOld lang l2 (day 10) "preference" "claude" [] "Lilly prefers Haskell for tools, and Nix for every tool and dependency. Never Homebrew."

  -- A fork: claude and codex both supersede e2.
  e1 <- old (day 1) "fact" "claude" [] "Lilly uses Emacs with evil-mode."
  editor <- newRef "claude/editor" e1
  e2 <- supersedeOld editor e1 (day 5) "fact" "claude" [] "Lilly uses Emacs with evil-mode and org-agenda."
  e3a <- supersedeOld editor e2 (day 12) "fact" "claude" [] "Lilly uses Emacs 30 with evil-mode, org-agenda and eglot."
  e3b <- old (addUTCTime 3600 (day 12)) "fact" "codex" [Edge Supersedes e2] "Lilly uses Emacs with evil-mode, and tries Zed for Rust."
  _ <- newRef "codex/editor" e3b

  -- A ref with seven generations. GC keeps the current one and five more.
  st1 <- old (day 2) "note" "codex" [] "Status 1: the store and the refs work."
  status <- newRef "codex/status" st1
  let step (cur, k) = do
        i <- supersedeOld status cur (day (2 + 3 * fromIntegral k)) "note" "codex" [] ("Status " <> T.pack (show (k + 1)) <> ": the work goes on.")
        pure (i, k + 1)
  _ <- foldM (\acc _ -> step acc) (st1, 1 :: Int) [1 .. 6 :: Int]

  -- A fact that only a retaining edge keeps, and the note that keeps it.
  f1 <- old (day 4) "fact" "lilly" [] "The akyuu store lives in ~/.akyuu."
  n1 <- old (day 11) "note" "claude" [Edge About l3, Edge DerivedFrom f1] "Nix shells pin every tool of akyuu."
  _ <- newRef "claude/notes" n1
  -- A summary that refines the note. Nothing keeps the summary.
  r1 <- old (day 13) "summary" "claude" [Edge Refines n1] "Summary: build with nix develop, and never with Homebrew."

  -- A decision that only a pin keeps.
  p1 <- old (day 6) "decision" "lilly" [] "Decision: the store is plain text. It never uses a binary format."
  withExceptT GCFailed (ExceptT (GC.pin s p1))

  -- An edge to an object that was never stored.
  let never = hashBytes "This memory was never stored."
  d1 <- old (day 14) "note" "codex" [Edge About never] "See the old design note. It was never stored."
  _ <- newRef "codex/design" d1

  -- A draft that GC deletes, and the todo that supersedes it.
  t0 <- old (day 7) "todo" "lilly" [] "Draft: write the README."
  t1 <- old (day 8) "todo" "lilly" [Edge Supersedes t0] "Write the README, with the architecture diagram."
  _ <- newRef "lilly/todo" t1
  -- A draft that GC moves to trash.
  t2 <- old (day 9) "todo" "lilly" [] "Draft: list the open decisions."
  -- Old memories that nothing keeps.
  g1 <- old (day 16) "fact" "codex" [] "Old scratch: a test memory."

  -- Young memories. Y3 keeps an old fact with an about edge.
  o1 <- old (day 15) "fact" "claude" [] "Lilly works on mirai, a Mac."
  y1 <- young (mins 10) "fact" "claude" [] "Lilly is testing the akyuu web UI."
  y2 <- young (mins 5) "note" "codex" [Edge About y1] "The web UI is read-only, on 127.0.0.1."
  y3 <- young (mins 2) "note" "claude" [Edge About o1] "mirai runs the web UI tests."

  -- Make the old objects old: their file time is their created time.
  olds <- liftIO (readIORef oldOnes)
  liftIO $ forM_ olds $ \(i, t) -> setModificationTime (Store.objectPath s i) t

  -- Delete t0: move it to trash, then delete it from trash. The second run
  -- uses a trash time of 0, one second later, so it leaves a tombstone now.
  let prune = defaultPolicy {trashTTL = 0}
  _ <- withExceptT GCFailed (ExceptT (GC.sweep s prune now (Set.singleton t0)))
  _ <- withExceptT GCFailed (ExceptT (GC.sweep s prune (addUTCTime 1 now) Set.empty))
  -- Move t2 to trash, with the default trash time of seven days.
  _ <- withExceptT GCFailed (ExceptT (GC.sweep s defaultPolicy now (Set.singleton t2)))

  _ <- withExceptT CacheFailed (ExceptT (Cache.sync (envCache env) s))
  stored <- withExceptT StoreFailed (ExceptT (Store.list s))
  refNames <- withExceptT RefFailed (ExceptT (Refs.listRefs rs))
  refVals <- traverse (\n -> (,) (Refs.nameText n) <$> withExceptT RefFailed (ExceptT (Refs.getRef rs n))) refNames
  pure
    Demo
      { demoRefs = sortOn fst [(n, Refs.current r : Refs.history r) | (n, r) <- refVals],
        demoPruned = t0,
        demoTrashed = t2,
        demoPinned = p1,
        demoMissing = never,
        demoFork = (e2, e3a, e3b),
        demoRetained = (f1, n1),
        demoGarbage = [st1, g1, r1],
        demoYoung = [y1, y2, y3],
        demoStored = stored
      }

-- | What 'seedDemo' made, as lines for a person. This function is pure.
demoLines :: FilePath -> Demo -> [Text]
demoLines root d =
  [ "made a demo store in " <> T.pack root <> " with " <> T.pack (show (length (demoStored d))) <> " memories",
    "refs:"
  ]
    <> ["  " <> n <> "  " <> render i <> older is | (n, i : is) <- demoRefs d]
    <> [ "fork:            " <> render a <> " is superseded by",
         "                 " <> render b,
         "                 " <> render c,
         "kept by an edge: " <> render (fst (demoRetained d)) <> " (from " <> render (snd (demoRetained d)) <> ")",
         "pinned:          " <> render (demoPinned d),
         "pruned:          " <> render (demoPruned d) <> " (a tombstone, and an edge to it)",
         "in trash:        " <> render (demoTrashed d),
         "missing target:  " <> render (demoMissing d) <> " (an edge to it, never stored)"
       ]
    <> ["garbage:         " <> render i <> " (a GC run now collects it)" | i <- demoGarbage d]
    <> ["young:           " <> render i <> " (the grace period keeps it)" | i <- demoYoung d]
    <> ["look at it with: akyuu --root " <> T.pack root <> " serve"]
  where
    (a, b, c) = demoFork d
    older [] = ""
    older is = " (and " <> T.pack (show (length is)) <> " older)"
