-- | Small file helpers that more than one module uses.
module Akyuu.Fs
  ( atomicWrite,
    tryWith,
    ignoreIO,
  )
where

import Control.Exception (IOException, bracket, bracketOnError, finally, try)
import Control.Monad (void)
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import System.Directory (removeFile, renameFile)
import System.FilePath (takeDirectory)
import System.IO (hClose, openBinaryTempFile)
import System.Posix.IO (OpenMode (ReadOnly), closeFd, defaultFileFlags, handleToFd, openFd)
import System.Posix.Unistd (fileSynchronise)

-- | Run an action that can throw an 'IOException'. The exception becomes a
-- 'Left' that holds the result of the function.
--
-- Each module that does I/O has its own error type. It uses this function
-- with the constructor for disk errors, for example @tryWith StoreIO@.
-- Other exceptions, for example a timeout, are not caught.
tryWith :: (IOException -> e) -> IO a -> IO (Either e a)
tryWith f = fmap (first f) . try

-- | Run an action and ignore an 'IOException'. Use it only for cleanup.
ignoreIO :: IO () -> IO ()
ignoreIO = void . try @IOException

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
atomicWrite final bytes =
  bracketOnError
    (openBinaryTempFile dir ".tmp")
    (\(tmp, h) -> ignoreIO (hClose h) >> ignoreIO (removeFile tmp))
    ( \(tmp, h) -> do
        BS.hPut h bytes
        -- 'handleToFd' flushes and closes the handle, but not the descriptor.
        -- The descriptor is ours to close.
        fd <- handleToFd h
        fileSynchronise fd `finally` closeFd fd
        renameFile tmp final
        syncDir dir
    )
  where
    dir = takeDirectory final

-- | Flush a directory to the disk with @fsync@. This makes the renames and
-- the new files in it permanent.
syncDir :: FilePath -> IO ()
syncDir dir = bracket (openFd dir ReadOnly defaultFileFlags) closeFd fileSynchronise
