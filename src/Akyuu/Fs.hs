-- | Small file helpers that more than one module uses.
module Akyuu.Fs
  ( atomicWrite,
    atomicWriteWith,
    AtomicStep (..),
    syncDir,
    tryAs,
    tryWith,
    ignoreIO,
    ifMissing,
  )
where

import Control.Exception (Exception, IOException, bracket, bracketOnError, finally, try, tryJust)
import Control.Monad (guard, void)
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import System.Directory (removeFile, renameFile)
import System.FilePath (takeDirectory)
import System.IO (hClose, openBinaryTempFile)
import System.IO.Error (isDoesNotExistError)
import System.Posix.IO (OpenMode (ReadOnly), closeFd, defaultFileFlags, handleToFd, openFd)
import System.Posix.Unistd (fileSynchronise)

-- | Run an action that can throw an exception of type @x@. The exception
-- becomes a 'Left' that holds the result of the function. Other exceptions,
-- for example a timeout, are not caught.
--
-- Each module that does I/O has its own error type. It uses this function
-- with the constructor for its own failures, for example @tryAs CacheSQL@
-- for a SQLite error. The type @x@ comes from the function that you pass.
tryAs :: (Exception x) => (x -> e) -> IO a -> IO (Either e a)
tryAs f = fmap (first f) . try

-- | 'tryAs' for an 'IOException', for example @tryWith StoreIO@.
tryWith :: (IOException -> e) -> IO a -> IO (Either e a)
tryWith = tryAs

-- | Run an action and ignore an 'IOException'. Use it only for cleanup.
ignoreIO :: IO () -> IO ()
ignoreIO = void . try @IOException

-- | Run an action. If it fails because a file or directory is missing, give
-- the default value. Other exceptions go up.
ifMissing :: a -> IO a -> IO a
ifMissing d act = either (const d) id <$> tryJust (guard . isDoesNotExistError) act

-- | Write bytes to a file so that a reader sees the old content or the new
-- content, and never a part of it. This holds also after a crash and after a
-- loss of power.
--
-- The function writes a temporary file in the same directory as the target.
-- Then it takes three steps:
--
-- 1. It flushes the temporary file to the disk with @fsync@. Without this
--    step, the rename can reach the disk before the content. After a power
--    loss, the target is then empty or short.
-- 2. It renames the temporary file to the target name. The rename replaces a
--    file that is already there. The temporary file must be in the same
--    directory, because a rename between two file systems is not atomic.
-- 3. It flushes the directory with @fsync@. Without this step, the rename can
--    be lost, and the old content comes back.
--
-- The function returns after step 3.
--
-- On macOS, @fsync@ pushes the data to the drive, but the drive can still
-- keep it in its own cache. A full flush needs @fcntl(F_FULLFSYNC)@, which
-- this function does not use.
--
-- The directory of the target must exist. If a step fails, the function
-- removes the temporary file and rethrows the 'Control.Exception.IOException'.
-- 'Akyuu.Store.add' and 'Akyuu.Refs.setRef' both use this function.
atomicWrite :: FilePath -> ByteString -> IO ()
atomicWrite = atomicWriteWith (const (pure ()))

-- | Boundaries for fault injection. A rename is visible before its directory
-- flush completes; callers must treat failures after that point as uncertain.
data AtomicStep = TemporaryWritten | FileSynced | Renamed | DirectorySynced
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | 'atomicWrite' with a callback after each write/flush boundary. Production
-- callers normally use 'atomicWrite'; tests can simulate an interrupted write.
atomicWriteWith :: (AtomicStep -> IO ()) -> FilePath -> ByteString -> IO ()
atomicWriteWith step final bytes =
  bracketOnError
    -- openBinaryTempFile treats a lone leading dot as an extension. A second
    -- dot keeps the generated basename hidden as well as the final extension.
    (openBinaryTempFile dir ".tmp.write")
    (\(tmp, h) -> ignoreIO (hClose h) >> ignoreIO (removeFile tmp))
    ( \(tmp, h) -> do
        BS.hPut h bytes
        step TemporaryWritten
        -- 'handleToFd' flushes and closes the handle, but not the descriptor.
        -- The descriptor is ours to close.
        fd <- handleToFd h
        fileSynchronise fd `finally` closeFd fd
        step FileSynced
        renameFile tmp final
        step Renamed
        syncDir dir
        step DirectorySynced
    )
  where
    dir = takeDirectory final

-- | Flush a directory to the disk with @fsync@. This makes the renames and
-- the new files in it permanent.
syncDir :: FilePath -> IO ()
syncDir dir = bracket (openFd dir ReadOnly defaultFileFlags) closeFd fileSynchronise
