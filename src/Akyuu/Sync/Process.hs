-- | Bounded Git subprocesses. A shell anchor owns the process group until
-- cleanup, including when Git exits before a descendant closes its pipes.
module Akyuu.Sync.Process (Deadline, deadline, remaining, runGit, ProcessError (..)) where

import Akyuu.Fs (ifMissing, ignoreIO, tryWith)
import Control.Concurrent (forkIO, killThread, newEmptyMVar, putMVar, takeMVar, threadDelay)
import Control.Exception (bracket, finally, mask)
import Control.Monad (forM_, unless, void, when)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Word (Word64)
import GHC.Clock (getMonotonicTimeNSec)
import System.Directory (doesDirectoryExist, getFileSize, getTemporaryDirectory, listDirectory, pathIsSymbolicLink, removeFile)
import System.Environment (getEnvironment)
import System.FilePath ((</>))
import System.IO (hClose, hSetBinaryMode, openBinaryTempFile)
import System.Posix.Signals (sigKILL, sigTERM, signalProcessGroup)
import System.Process (CreateProcess (close_fds, create_group, env, std_err, std_in, std_out), StdStream (CreatePipe), createProcess, getPid, proc, waitForProcess)
import System.Timeout (timeout)

newtype Deadline = Deadline Word64

data ProcessError = GitFailed Int | GitTimeout | GitOutputLimit | GitStorageLimit | GitProcessIO deriving (Eq, Show)

deadline :: Int -> IO Deadline
deadline seconds = Deadline . (+ fromIntegral (max 1 seconds) * 1000000000) <$> getMonotonicTimeNSec

remaining :: Deadline -> IO Int
remaining (Deadline end) = do
  now <- getMonotonicTimeNSec
  pure (if now >= end then 0 else fromIntegral ((end - now) `div` 1000))

-- | Output is bounded in memory. A monitored private repository has a 512 MiB
-- disk budget, checked during the command (temporary overshoot is possible).
-- The command never inherits Git configuration, credential prompts or hooks.
runGit :: Deadline -> Maybe FilePath -> [String] -> ByteString -> Int -> IO (Either ProcessError ByteString)
runGit end watched args input limit = do
  outcome <- tryWith (const GitProcessIO) $ mask $ \restore -> do
    tmp <- getTemporaryDirectory
    descriptors <- doesDirectoryExist "/dev/fd"
    unless descriptors (ioError (userError "Descriptor enumeration is unavailable."))
    bracket (openBinaryTempFile tmp "akyuu-git-status") (\(path, h) -> ignoreIO (hClose h) >> ignoreIO (removeFile path)) $ \(status, h) -> do
      hClose h
      removeFile status
      inherited <- getEnvironment
      let environment =
            [(key, value) | (key, value) <- inherited, not ("GIT_" `prefix` key), key `notElem` ["BASH_ENV", "ENV", "LC_ALL"]]
              <> [("GIT_CONFIG_NOSYSTEM", "1"), ("GIT_CONFIG_GLOBAL", "/dev/null"), ("GIT_TERMINAL_PROMPT", "0"), ("GIT_SSH_COMMAND", "ssh -oBatchMode=yes"), ("LC_ALL", "C")]
          -- Enumerate open descriptors in the child. process.close_fds scans
          -- the full descriptor limit on Darwin, which can cost seconds for
          -- each tiny Git call. Kernel descriptor names contain digits only.
          script = "for path in /dev/fd/*; do fd=${path##*/}; case $fd in ''|*[!0-9]*|0|1|2) continue;; esac; eval \"exec $fd>&-\"; done; status=$1; shift; \"$@\"; result=$?; exec 1>&- 2>&-; printf '%s\\n' \"$result\" > \"$status\"; while :; do sleep 1; done"
          command =
            (proc "sh" (["-c", script, "akyuu-git", status, "git", "-c", "core.hooksPath=/dev/null", "-c", "gc.auto=0", "-c", "maintenance.auto=false", "-c", "transfer.fsckObjects=true", "-c", "protocol.ext.allow=never", "-c", "protocol.file.allow=always", "-c", "fetch.unpackLimit=0"] <> args))
              { std_in = CreatePipe,
                std_out = CreatePipe,
                std_err = CreatePipe,
                create_group = True,
                close_fds = False,
                env = Just environment
              }
      (Just hin, Just hout, Just herr, ph) <- createProcess command
      pid <- getPid ph
      forM_ [hin, hout, herr] (`hSetBinaryMode` True)
      overflow <- newIORef False
      output <- newEmptyMVar
      let drain handle cap failLarge = go [] 0
            where
              go chunks size = do
                bytes <- BS.hGetSome handle 32768
                if BS.null bytes
                  then pure (BS.concat (reverse chunks))
                  else do
                    when (failLarge && size + BS.length bytes > cap) (writeIORef overflow True)
                    let kept = BS.take (max 0 (cap - size)) bytes
                    go (if BS.null kept then chunks else kept : chunks) (min cap (size + BS.length bytes))
      writer <- forkIO (ignoreIO (BS.hPut hin input) `finally` ignoreIO (hClose hin))
      reader <- forkIO (tryWith (const GitProcessIO) (drain hout limit True) >>= putMVar output)
      errors <- forkIO (void (tryWith (const GitProcessIO) (drain herr 16384 False)))
      let stop = do
            (forM_ pid (\group -> ignoreIO (signalProcessGroup sigTERM group)) >> threadDelay 20000)
              `finally` (forM_ pid (\group -> ignoreIO (signalProcessGroup sigKILL group)) >> void (timeout 2000000 (waitForProcess ph)))
          clean = do
            forM_ [writer, reader, errors] killThread
            forM_ [hin, hout, herr] (ignoreIO . hClose)
          poll = do
            left <- remaining end
            tooMuch <- readIORef overflow
            disk <- maybe (pure True) underBudget watched
            if left <= 0
              then pure (Left GitTimeout)
              else
                if tooMuch
                  then pure (Left GitOutputLimit)
                  else
                    if not disk
                      then pure (Left GitStorageLimit)
                      else do
                        result <- ifMissing Nothing (Just <$> BS.readFile status)
                        case result >>= parseStatus of
                          Just 0 -> pure (Right ())
                          Just code -> pure (Left (GitFailed code))
                          Nothing -> threadDelay (min left 10000) >> poll
      flip finally clean $ do
        budget <- remaining end
        completion <- restore (timeout budget poll) `finally` stop
        let result = maybe (Left GitTimeout) id completion
        case result of
          Left err -> pure (Left err)
          Right () -> do
            got <- restore (timeout 2000000 (takeMVar output))
            tooMuch <- readIORef overflow
            pure $ if tooMuch then Left GitOutputLimit else maybe (Left GitTimeout) id got
  pure (either Left id outcome)
  where
    prefix start value = take (length start) value == start
    parseStatus bytes = case BC.readInt bytes of Just (n, rest) | rest == "\n" && n >= 0 && n <= 255 -> Just n; _ -> Nothing

underBudget :: FilePath -> IO Bool
underBudget root = (<= 512 * 1024 * 1024) <$> size root
  where
    size path = ifMissing 0 $ do
      link <- pathIsSymbolicLink path
      if link
        then pure (513 * 1024 * 1024)
        else do
          directory <- doesDirectoryExist path
          if directory then listDirectory path >>= fmap sum . traverse (size . (path </>)) else getFileSize path
