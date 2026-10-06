{-# LANGUAGE OverloadedStrings #-}

module FsTests (fsTests) where

import Akyuu.Fs (atomicWrite, ignoreIO, tryAs, tryWith)
import Control.Exception (ArithException (..), IOException, throwIO, try)
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
    , tryAsTests
    , tryWithTests
    , ignoreIOTests
    ]

tryAsTests :: TestTree
tryAsTests =
  testGroup
    "tryAs"
    [ testCase "returns Right with the result if there is no exception" $
        tryAs (\(e :: ArithException) -> show e) (pure (3 :: Int)) >>= (@?= Right 3)
    , testCase "turns an exception of the type of the function into Left" $
        tryAs (\(e :: ArithException) -> show e) (throwIO Overflow :: IO ())
          >>= (@?= Left "arithmetic overflow")
    , testCase "does not catch an exception of another type" $ do
        r <- try (tryAs (\(_ :: ArithException) -> ("a" :: String)) (readFile "/nonexistent/akyuu-test-missing-file"))
        case r of
          Left (_ :: IOException) -> pure ()
          Right x -> assertFailure ("expected an IOException, got " ++ show x)
    ]

tryWithTests :: TestTree
tryWithTests =
  testGroup
    "tryWith"
    [ testCase "returns Right with the result if there is no exception" $
        tryWith show (pure (3 :: Int)) >>= (@?= Right 3)
    , testCase "turns an IOException into Left, with the function applied" $ do
        r <- tryWith (const ("io" :: String)) (readFile "/nonexistent/akyuu-test-missing-file")
        r @?= Left "io"
    , testCase "does not catch other exceptions" $ do
        r <- try (tryWith (const ("io" :: String)) (throwIO Overflow :: IO ()))
        case r of
          Left Overflow -> pure ()
          Left e -> assertFailure ("unexpected: " ++ show e)
          Right x -> assertFailure ("expected an exception, got " ++ show x)
    ]

ignoreIOTests :: TestTree
ignoreIOTests =
  testGroup
    "ignoreIO"
    [ testCase "runs the action" $
        ignoreIO (pure ())
    , testCase "ignores an IOException" $
        ignoreIO (() <$ readFile "/nonexistent/akyuu-test-missing-file")
    , testCase "does not ignore other exceptions" $ do
        r <- try (ignoreIO (throwIO Overflow))
        case r of
          Left Overflow -> pure ()
          Left e -> assertFailure ("unexpected: " ++ show e)
          Right () -> assertFailure "expected an exception"
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
