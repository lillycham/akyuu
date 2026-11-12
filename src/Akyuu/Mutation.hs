-- | The outer lock of every store mutation. Lock order: mutation, refs,
-- then cache/SQLite. Never run external commands while this lock is held.
module Akyuu.Mutation
  ( Mutation,
    withMutation,
    withLockFile,
    checkMutation,
    mutationLockPath,
  )
where

import Akyuu.Fs (tryWith)
import Control.Concurrent (threadDelay)
import Control.Exception (IOException)
import System.FileLock (SharedExclusive (Exclusive), withTryFileLock)
import System.FilePath ((</>))

-- | Evidence that the caller holds the mutation lock for this root. Pass it
-- only to operations inside the callback of 'withMutation'; do not retain it.
newtype Mutation = Mutation FilePath

mutationLockPath :: FilePath -> FilePath
mutationLockPath root = root </> "store.lock"

-- | Acquire the process-safe, non-reentrant lock, with a one-second bounded
-- wait. File locks are released by the OS on exceptions and process death.
withMutation :: FilePath -> e -> (IOException -> e) -> (Mutation -> IO (Either e a)) -> IO (Either e a)
withMutation root busy io action = withLockFile (mutationLockPath root) busy io (action (Mutation root))

-- | Hold an exclusive lock file for an action, with the same one-second
-- bounded wait. The sync and migration locks use this too, each with its own
-- file: only 'withMutation' gives evidence of the mutation lock.
withLockFile :: FilePath -> e -> (IOException -> e) -> IO (Either e a) -> IO (Either e a)
withLockFile path busy io action = go (100 :: Int)
  where
    go 0 = pure (Left busy)
    go n = do
      got <- tryWith io (withTryFileLock path Exclusive (const action))
      case got of
        Left e -> pure (Left e)
        Right Nothing -> threadDelay 10000 >> go (n - 1)
        Right (Just result) -> pure result

-- | Prevent a compound operation from using a token for a different store.
checkMutation :: Mutation -> FilePath -> IO ()
checkMutation (Mutation held) root
  | held == root = pure ()
  | otherwise = ioError (userError "A mutation token belongs to a different store root.")
