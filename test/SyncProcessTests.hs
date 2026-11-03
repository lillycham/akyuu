{-# LANGUAGE OverloadedStrings #-}

module SyncProcessTests (syncProcessTests) where

import Akyuu.Sync.Process (ProcessError (GitOutputLimit, GitStorageLimit, GitTimeout), deadline, runGit)
import Control.Concurrent (forkIO, killThread, newEmptyMVar, putMVar, takeMVar, threadDelay)
import Control.Exception (finally)
import Control.Monad (void)
import Data.ByteString.Char8 qualified as BC
import Support (withTempDir)
import System.Directory (createDirectory, doesFileExist, findExecutable)
import System.Environment (getEnv, getEnvironment, getExecutablePath, lookupEnv)
import System.Exit (ExitCode (ExitSuccess))
import System.FileLock (SharedExclusive (Exclusive), lockFile, unlockFile, withTryFileLock)
import System.FilePath ((</>))
import System.Posix.Files (setFileMode)
import System.Process (CreateProcess (close_fds, env), proc, readCreateProcessWithExitCode)
import System.Timeout (timeout)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase, (@?=))

-- Environment changes stay in a child process, isolated from parallel tests.
isolated :: String -> BC.ByteString -> (FilePath -> IO ()) -> IO ()
isolated name script action = do
  worker <- lookupEnv "AKYUU_SYNC_WORKER_ROOT"
  case worker of
    Just root -> action root
    Nothing -> withTempDir $ \root -> do
      let bin = root </> "bin"
      createDirectory bin
      shell <- findExecutable "sh" >>= maybe (ioError (userError "The subprocess tests require sh on PATH.")) pure
      BC.writeFile (bin </> "git") (BC.pack ("#!" <> shell <> "\n") <> script <> "\n")
      setFileMode (bin </> "git") 0o700
      executable <- getExecutablePath
      inherited <- getEnvironment
      path <- getEnv "PATH"
      let environment = [("PATH", bin <> ":" <> path), ("AKYUU_SYNC_WORKER_ROOT", root), ("AKYUU_TEST_MARKER", root </> "survived"), ("AKYUU_TEST_STARTED", root </> "started"), ("AKYUU_TEST_DISK", root)] <> filter (\(key, _) -> key `notElem` ["PATH", "AKYUU_SYNC_WORKER_ROOT", "AKYUU_TEST_MARKER", "AKYUU_TEST_STARTED", "AKYUU_TEST_DISK"]) inherited
          command = (proc executable ["-p", "$0 ~ /" <> name <> "/", "--num-threads=1"]) {env = Just environment, close_fds = True}
      result <- timeout 15000000 (readCreateProcessWithExitCode command "")
      case result of
        Just (ExitSuccess, _, _) -> pure ()
        Just (_, out, err) -> assertFailure (out <> err)
        Nothing -> assertFailure "The isolated process test exceeded its deadline."

started :: FilePath -> IO ()
started root = do
  result <- timeout 3000000 loop
  result @?= Just ()
  where
    loop = do found <- doesFileExist (root </> "started"); if found then pure () else threadDelay 10000 >> loop

syncProcessTests :: TestTree
syncProcessTests =
  testGroup
    "bounded sync subprocesses"
    [ scenario "stdout is bounded" "printf '%01000d' 0" $ \_ -> do
        end <- deadline 5
        runGit end Nothing ["--version"] "" 64 >>= (@?= Left GitOutputLimit),
      scenario "private Git storage is bounded during the command" "truncate -s 600M \"$AKYUU_TEST_DISK/large\"; sleep 30" $ \root -> do
        end <- deadline 5
        runGit end (Just root) ["--version"] "" 64 >>= (@?= Left GitStorageLimit),
      scenario "timeout kills a TERM-resistant child" "(trap '' TERM; sleep 2; printf alive > \"$AKYUU_TEST_MARKER\"; sleep 30) & while :; do sleep 1; done" $ \root -> do
        end <- deadline 1
        runGit end Nothing ["--version"] "" 64 >>= (@?= Left GitTimeout)
        threadDelay 1300000
        doesFileExist (root </> "survived") >>= (@?= False),
      scenario "an exited Git process cannot leave a live descendant" "(trap '' TERM; sleep 2; printf alive > \"$AKYUU_TEST_MARKER\"; sleep 30) & exit 0" $ \root -> do
        end <- deadline 5
        runGit end Nothing ["--version"] "" 64 >>= (@?= Right "")
        threadDelay 2100000
        doesFileExist (root </> "survived") >>= (@?= False),
      scenario "cancellation cleans the owned process group" "printf yes > \"$AKYUU_TEST_STARTED\"; (trap '' TERM; sleep 2; printf alive > \"$AKYUU_TEST_MARKER\"; sleep 30) & while :; do sleep 1; done" $ \root -> do
        end <- deadline 30
        done <- newEmptyMVar
        worker <- forkIO (void (runGit end Nothing ["--version"] "" 64) `finally` putMVar done ())
        started root
        killThread worker
        timeout 3000000 (takeMVar done) >>= (@?= Just ())
        threadDelay 2100000
        doesFileExist (root </> "survived") >>= (@?= False),
      scenario "a Git child does not retain its parent's file lock" "printf yes > \"$AKYUU_TEST_STARTED\"; sleep 1" $ \root -> do
        held <- lockFile (root </> "probe.lock") Exclusive
        done <- newEmptyMVar
        end <- deadline 5
        _ <- forkIO (runGit end Nothing ["--version"] "" 64 >>= putMVar done)
        started root
        unlockFile held
        available <- withTryFileLock (root </> "probe.lock") Exclusive (const (pure True))
        available @?= Just True
        result <- timeout 6000000 (takeMVar done)
        result @?= Just (Right "")
    ]
  where
    scenario name script action = testCase name (isolated name script action)
