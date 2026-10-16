{-# LANGUAGE OverloadedStrings #-}

-- | Helpers that more than one test module uses.
module Support (withTempDir, right, nid, testMemory, newMem) where

import Akyuu.Graph (Edge)
import Akyuu.Id (Id, fromDigest)
import Akyuu.Memory (Memory, mkMemory)
import Akyuu.Ops (NewMemory (NewMemory))
import Control.Exception (bracket)
import Data.ByteString qualified as BS
import Data.Maybe (fromMaybe)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Time (UTCTime)
import System.Directory
  ( createDirectory,
    getTemporaryDirectory,
    removeDirectoryRecursive,
    removeFile,
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

-- A memory for a test. It stops the test with an error if a field is not
-- valid, so a test never builds a memory that the store would refuse.
testMemory :: Text -> UTCTime -> Text -> Set Edge -> Text -> Memory
testMemory k t a es b = either (error . ("testMemory: " ++) . show) id (mkMemory k t a es b)

-- | A new memory with no about-ref links: kind, agent, edges and body.
newMem :: Text -> Text -> Set Edge -> Text -> NewMemory
newMem k a es b = NewMemory k a es b Set.empty
