{-# LANGUAGE OverloadedStrings #-}

module FsTests (fsTests) where

import Akyuu.Fs (atomicWrite)
import Control.Exception (IOException, try)
import Data.ByteString qualified as BS
import Support (withTempDir)
import System.Directory (listDirectory)
import System.FilePath ((</>))
import Test.Tasty
import Test.Tasty.HUnit
import Test.Tasty.QuickCheck

fsTests :: TestTree
fsTests =
  testGroup
    "Akyuu.Fs"
    [ atomicWriteTests
    ]

atomicWriteTests :: TestTree
atomicWriteTests =
  testGroup
    "atomicWrite"
    [ testCase "makes a file with the content" $
        withTempDir $ \dir -> do
          atomicWrite (dir </> "f") "hello"
          BS.readFile (dir </> "f") >>= (@?= "hello")
    , testCase "writes empty content" $
        withTempDir $ \dir -> do
          atomicWrite (dir </> "f") BS.empty
          BS.readFile (dir </> "f") >>= (@?= BS.empty)
    , testCase "replaces a file that is already there" $
        withTempDir $ \dir -> do
          atomicWrite (dir </> "f") "old content that is long"
          atomicWrite (dir </> "f") "new"
          BS.readFile (dir </> "f") >>= (@?= "new")
    , testCase "leaves no other file in the directory" $
        withTempDir $ \dir -> do
          atomicWrite (dir </> "f") "a"
          atomicWrite (dir </> "f") "b"
          listDirectory dir >>= (@?= ["f"])
    , testCase "throws an IOException if the directory does not exist" $
        withTempDir $ \dir -> do
          r <- try (atomicWrite (dir </> "missing" </> "f") "x")
          case r of
            Left (_ :: IOException) -> pure ()
            Right () -> assertFailure "expected an IOException"
    , testProperty "reads back what it wrote" $ \ws ->
        ioProperty $ withTempDir $ \dir -> do
          let b = BS.pack ws
          atomicWrite (dir </> "f") b
          (=== b) <$> BS.readFile (dir </> "f")
    ]
