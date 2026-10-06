-- | Small file helpers that more than one module uses.
module Akyuu.Fs
  ( atomicWrite,
  )
where

import Data.ByteString (ByteString)

-- | Write bytes to a file so that a reader sees the old content or the new
-- content, and never a part of it. This holds also after a crash.
--
-- The function writes a temporary file in the same directory as the target,
-- closes it (which flushes it), and renames it to the target name. The
-- rename replaces a file that is already there. The temporary file must be in
-- the same directory, because a rename between two file systems is not
-- atomic.
--
-- The directory of the target must exist. If the write fails, the function
-- removes the temporary file and rethrows the 'Control.Exception.IOException'.
-- 'Akyuu.Store.add' has the same steps. It can use this function when it
-- is ready.
atomicWrite :: FilePath -> ByteString -> IO ()
atomicWrite = error "Akyuu.Fs.atomicWrite: not implemented"
