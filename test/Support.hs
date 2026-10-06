-- | Helpers that more than one test module uses.
module Support (withTempDir, right, nid) where

import Akyuu.Id (Id, fromDigest)
import Control.Exception (bracket)
import Data.ByteString qualified as BS
import Data.Maybe (fromMaybe)
import System.Directory
  ( createDirectory
  , getTemporaryDirectory
  , removeDirectoryRecursive
  , removeFile
  )
import System.IO (hClose, openTempFile)
import Test.Tasty.HUnit (assertFailure)

-- A fresh directory for one test. It is removed when the test ends.
withTempDir :: (FilePath -> IO a) -> IO a
withTempDir = bracket make removeDirectoryRecursive
  where
    make = do
      tmp <- getTemporaryDirectory
      (path, h) <- openTempFile tmp "akyuu-test"
      hClose h
      removeFile path
      createDirectory path
      pure path

-- Take the 'Right' of a result, or fail the test with the error.
right :: (Show e) => Either e a -> IO a
right = either (\e -> assertFailure ("unexpected Left: " ++ show e)) pure

-- An 'Id' for a small number. Different numbers give different 'Id' values.
nid :: Int -> Id
nid n = fromMaybe (error "nid: not 32 bytes") (fromDigest (BS.replicate 32 (fromIntegral n)))
