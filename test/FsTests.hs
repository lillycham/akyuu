{-# LANGUAGE OverloadedStrings #-}

module FsTests (fsTests) where

import Akyuu.Fs (AtomicStep (TemporaryWritten), atomicWrite, atomicWriteWith, hGetBounded, ignoreIO, tryAs, tryWith)
import Control.Exception (ArithException (Overflow), IOException, throwIO, try)
import Data.ByteString qualified as BS
import Data.List (isPrefixOf)
import Support (withTempDir)
import System.Directory (listDirectory)
import System.FilePath ((</>))
import System.IO (IOMode (ReadMode), hFileSize, withBinaryFile)
import System.Posix.Files (setFileSize)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))
import Test.Tasty.QuickCheck (ioProperty, testProperty, (===))

fsTests :: TestTree
fsTests =
  testGroup
    "Akyuu.Fs"
    [ boundedReadTests,
      atomicWriteTests,
      tryAsTests,
      tryWithTests,
      ignoreIOTests
    ]

boundedReadTests :: TestTree
boundedReadTests =
  testGroup "bounded handle reads" $
    [ testCase label $ withTempDir $ \dir -> do
        let path = dir </> "input"
        BS.writeFile path bytes
        withBinaryFile path ReadMode $ \handle -> hGetBounded cap hint handle >>= (@?= BS.take cap bytes)
    | (label, bytes, cap, hint) <-
        [ ("empty file", BS.empty, 9, 0),
          ("zero bound", "abc", 0, 3),
          ("short file", "abc", 9, 3),
          ("exact bound", "abcdefghi", 9, 9),
          ("oversized file returns the detection byte", "abcdefghijk", 10, 11),
          ("negative hint is only a hint", "abcdef", 9, -1),
          ("huge hint stays bounded", "abc", 9, 2 ^ (100 :: Int)),
          ("growth spans several chunks", BS.replicate 200000 65, 150000, 0)
        ]
    ]
      <> [ testCase "growth after size observation does not hide extra bytes" $ withTempDir $ \dir -> do
             let path = dir </> "input"
             BS.writeFile path "abc"
             withBinaryFile path ReadMode $ \handle -> do
               hint <- hFileSize handle
               setFileSize path 16
               hGetBounded 10 hint handle >>= (@?= ("abc" <> BS.replicate 7 0)),
           testCase "truncation after size observation stops at EOF" $ withTempDir $ \dir -> do
             let path = dir </> "input"
             BS.writeFile path "abcdefghijklmnop"
             withBinaryFile path ReadMode $ \handle -> do
               hint <- hFileSize handle
               setFileSize path 3
               hGetBounded 10 hint handle >>= (@?= "abc"),
           testCase "negative bounds fail without reading" $ withTempDir $ \dir -> do
             let path = dir </> "input"
             BS.writeFile path "abc"
             withBinaryFile path ReadMode $ \handle -> do
               result <- try (hGetBounded (-1) 3 handle) :: IO (Either IOException BS.ByteString)
               case result of
                 Left _ -> pure ()
                 Right _ -> assertFailure "negative bound accepted"
               BS.hGet handle 3 >>= (@?= "abc")
         ]

tryAsTests :: TestTree
tryAsTests =
  testGroup
    "tryAs"
    [ testCase "returns Right with the result if there is no exception" $
        tryAs (\(e :: ArithException) -> show e) (pure (3 :: Int)) >>= (@?= Right 3),
      testCase "turns an exception of the type of the function into Left" $
        tryAs (\(e :: ArithException) -> show e) (throwIO Overflow :: IO ())
          >>= (@?= Left "arithmetic overflow"),
      testCase "does not catch an exception of another type" $ do
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
        tryWith show (pure (3 :: Int)) >>= (@?= Right 3),
      testCase "turns an IOException into Left, with the function applied" $ do
        r <- tryWith (const ("io" :: String)) (readFile "/nonexistent/akyuu-test-missing-file")
        r @?= Left "io",
      testCase "does not catch other exceptions" $ do
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
        ignoreIO (pure ()),
      testCase "ignores an IOException" $
        ignoreIO (() <$ readFile "/nonexistent/akyuu-test-missing-file"),
      testCase "does not ignore other exceptions" $ do
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
          BS.readFile (dir </> "f") >>= (@?= "hello"),
      testCase "temporary files have a hidden basename" $
        withTempDir $ \dir -> do
          let hook TemporaryWritten = do
                names <- listDirectory dir
                assertBool "Expected one hidden temporary file" (length names == 1 && all (isPrefixOf ".tmp") names)
              hook _ = pure ()
          atomicWriteWith hook (dir </> "f") "hello",
      testCase "writes empty content" $
        withTempDir $ \dir -> do
          atomicWrite (dir </> "f") BS.empty
          BS.readFile (dir </> "f") >>= (@?= BS.empty),
      testCase "replaces a file that is already there" $
        withTempDir $ \dir -> do
          atomicWrite (dir </> "f") "old content that is long"
          atomicWrite (dir </> "f") "new"
          BS.readFile (dir </> "f") >>= (@?= "new"),
      testCase "leaves no other file in the directory" $
        withTempDir $ \dir -> do
          atomicWrite (dir </> "f") "a"
          atomicWrite (dir </> "f") "b"
          listDirectory dir >>= (@?= ["f"]),
      testCase "throws an IOException if the directory does not exist" $
        withTempDir $ \dir -> do
          r <- try (atomicWrite (dir </> "missing" </> "f") "x")
          case r of
            Left (_ :: IOException) -> pure ()
            Right () -> assertFailure "expected an IOException",
      testProperty "reads back what it wrote" $ \ws ->
        ioProperty $ withTempDir $ \dir -> do
          let b = BS.pack ws
          atomicWrite (dir </> "f") b
          (=== b) <$> BS.readFile (dir </> "f")
    ]
