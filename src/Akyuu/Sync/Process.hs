-- | Bounded Git subprocesses. A shell anchor owns the process group until
-- cleanup, including when Git exits before a descendant closes its pipes.
module Akyuu.Sync.Process (Deadline, deadline, remaining, runGit, ProcessError (..), describeProcessError) where

import Akyuu.Fs (ifMissing, ignoreIO, tryWith)
import Control.Concurrent (forkIO, killThread, newEmptyMVar, putMVar, takeMVar, threadDelay)
import Control.Exception (bracket, finally, mask)
import Control.Monad (forM_, unless, void, when)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (decodeUtf8With)
import Data.Text.Encoding.Error (lenientDecode)
import Data.Word (Word64)
import GHC.Clock (getMonotonicTimeNSec)
import System.Directory (doesDirectoryExist, getFileSize, getTemporaryDirectory, listDirectory, pathIsSymbolicLink, removeFile)
import System.Environment (getEnvironment)
import System.FilePath ((</>))
import System.IO (hClose, hSetBinaryMode, openBinaryTempFile)
import System.Posix.Signals (sigKILL, sigTERM, signalProcessGroup)
import System.Process (CreateProcess (close_fds, create_group, env, std_err, std_in, std_out), StdStream (CreatePipe), createProcess, getPid, getProcessExitCode, proc, waitForProcess)
import System.Timeout (timeout)

newtype Deadline = Deadline Word64

-- | A failed command keeps the end of its diagnostic output, as one line.
data ProcessError = GitFailed Int Text | GitTimeout | GitOutputLimit | GitStorageLimit | GitProcessIO deriving (Eq, Show)

describeProcessError :: ProcessError -> Text
describeProcessError failure = case failure of
  GitFailed code message -> "exit status " <> T.pack (show code) <> (if T.null message then "" else ": " <> message)
  GitTimeout -> "the deadline passed"
  GitOutputLimit -> "the output exceeded its limit"
  GitStorageLimit -> "the private Git repository exceeded its storage limit"
  GitProcessIO -> "the command did not start or lost its pipes"

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
          -- Some shells (dash) cannot name a descriptor above 9 in a redirection:
          -- there `exec 10>&-` runs a program named 10 and ends the shell. A
          -- subshell probe finds this; such a shell closes only 3 to 9.
          script = "if (eval 'exec 10>&-') 2>/dev/null; then wide=1; else wide=; fi; for path in /dev/fd/*; do fd=${path##*/}; case $fd in ''|*[!0-9]*|0|1|2) continue;; esac; case $wide:$fd in :??*) continue;; esac; eval \"exec $fd>&-\"; done; status=$1; shift; \"$@\"; result=$?; exec 1>&- 2>&-; printf '%s\\n' \"$result\" > \"$status\"; while :; do sleep 1; done"
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
      diagnostics <- newEmptyMVar
      errors <- forkIO (tryWith (const GitProcessIO) (drain herr 16384 False) >>= putMVar diagnostics . either (const BS.empty) id)
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
                          Just code -> pure (Left (GitFailed code ""))
                          Nothing -> do
                            -- The anchor ends only when something kills it or
                            -- its shell fails. Do not wait for the deadline.
                            gone <- getProcessExitCode ph
                            case gone of
                              Nothing -> threadDelay (min left 10000) >> poll
                              Just _ -> do
                                final <- ifMissing Nothing (Just <$> BS.readFile status)
                                pure $ case final >>= parseStatus of
                                  Just 0 -> Right ()
                                  Just code -> Left (GitFailed code "")
                                  Nothing -> Left GitProcessIO
      flip finally clean $ do
        budget <- remaining end
        completion <- restore (timeout budget poll) `finally` stop
        let result = maybe (Left GitTimeout) id completion
        case result of
          Left (GitFailed code _) -> do
            said <- timeout 200000 (takeMVar diagnostics)
            pure (Left (GitFailed code (maybe "" lastLines said)))
          Left err -> pure (Left err)
          Right () -> do
            got <- restore (timeout 2000000 (takeMVar output))
            tooMuch <- readIORef overflow
            pure $ if tooMuch then Left GitOutputLimit else maybe (Left GitTimeout) id got
  pure (either Left id outcome)
  where
    prefix start value = take (length start) value == start
    -- The last lines say why Git failed. Keep them short and on one line.
    lastLines bytes =
      let clean = T.map (\c -> if c < ' ' || c == '\DEL' then ' ' else c)
          said = filter (not . T.null) (map (T.strip . clean) (T.lines (decodeUtf8With lenientDecode bytes)))
       in T.takeEnd 400 (T.intercalate "; " (reverse (take 3 (reverse said))))
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
