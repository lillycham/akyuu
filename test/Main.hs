{-# LANGUAGE OverloadedStrings #-}
module Main (main) where

import Akyuu.Id
import CacheTests (cacheTests)
import FsTests (fsTests)
import GCTests (gcTests)
import GraphTests (graphTests)
import MemoryTests (memoryTests)
import QueryTests (queryTests)
import RefsTests (refsTests)
import StoreTests (storeTests)
import SupersedeTests (supersedeTests)
import Control.Exception (IOException, bracket, try)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Word (Word8)
import System.Directory (getTemporaryDirectory, removeFile)
import System.IO (hClose, openBinaryTempFile)
import Test.Tasty
import Test.Tasty.HUnit
import Test.Tasty.QuickCheck

main :: IO ()
main = defaultMain $ testGroup "akyuu" [idTests, graphTests, memoryTests, fsTests, storeTests, refsTests, cacheTests, supersedeTests, gcTests, queryTests]

idTests :: TestTree
idTests =
  testGroup
    "Akyuu.Id"
    [ digestTests
    , toBytesTests
    , hashTests
    , hashFileTests
    , verifyTests
    , renderTests
    , showTests
    , parseTests
    , properties
    ]

-- SHA-256 test vectors (FIPS 180-4 / NIST).
emptyHex, abcHex :: Text
emptyHex = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
abcHex = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

-- Decode hex that the tests know is valid.
hexBytes :: Text -> BS.ByteString
hexBytes = either error id . B16.decode . TE.encodeUtf8

-- An Id for 32 arbitrary bytes. Any 32 bytes are a valid digest.
idFromBytes :: [Word8] -> Id
idFromBytes ws = case fromDigest (BS.pack (take 32 (ws ++ repeat 0))) of
  Just i -> i
  Nothing -> error "idFromBytes: digest is not 32 bytes"

-- Run an action with a temporary file that holds the given content.
withTempFileContaining :: BS.ByteString -> (FilePath -> IO a) -> IO a
withTempFileContaining content = bracket create removeFile
  where
    create = do
      dir <- getTemporaryDirectory
      (path, h) <- openBinaryTempFile dir "akyuu-test"
      BS.hPut h content
      hClose h
      pure path

isJust' :: Maybe a -> Bool
isJust' = maybe False (const True)

digestTests :: TestTree
digestTests =
  testGroup
    "fromDigest"
    [ testCase "accepts 32 bytes" $
        assertBool "expected Just" (isJust' (fromDigest (BS.replicate 32 0)))
    , testCase "rejects empty input" $
        assertBool "expected Nothing" (not (isJust' (fromDigest BS.empty)))
    , testCase "rejects 31 bytes" $
        assertBool "expected Nothing" (not (isJust' (fromDigest (BS.replicate 31 0))))
    , testCase "rejects 33 bytes" $
        assertBool "expected Nothing" (not (isJust' (fromDigest (BS.replicate 33 0))))
    , testCase "does not check that a hash function made the digest" $
        assertBool "expected Just" (isJust' (fromDigest (BS.replicate 32 0xff)))
    , testCase "gives the same Id as hashBytes for a real digest" $
        fromDigest (hexBytes emptyHex) @?= Just (hashBytes BS.empty)
    ]

toBytesTests :: TestTree
toBytesTests =
  testGroup
    "toBytes"
    [ testCase "gives the SHA-256 digest of the empty string" $
        toBytes (hashBytes BS.empty) @?= hexBytes emptyHex
    , testCase "gives the SHA-256 digest of \"abc\"" $
        toBytes (hashBytes "abc") @?= hexBytes abcHex
    , testCase "gives back the digest that fromDigest got" $
        fmap toBytes (fromDigest (BS.replicate 32 7)) @?= Just (BS.replicate 32 7)
    ]

hashTests :: TestTree
hashTests =
  testGroup
    "hashBytes"
    [ testCase "matches the SHA-256 vector for the empty string" $
        parse ("sha256-" <> emptyHex) @?= Right (hashBytes BS.empty)
    , testCase "matches the SHA-256 vector for \"abc\"" $
        parse ("sha256-" <> abcHex) @?= Right (hashBytes "abc")
    , testCase "is deterministic" $
        hashBytes "akyuu" @?= hashBytes "akyuu"
    , testCase "distinguishes different inputs" $
        assertBool "ids equal" (hashBytes "a" /= hashBytes "b")
    ]

hashFileTests :: TestTree
hashFileTests =
  testGroup
    "hashFile"
    [ testCase "gives the Id of an empty file" $
        withTempFileContaining BS.empty hashFile >>= (@?= hashBytes BS.empty)
    , testCase "gives the Id of a small file" $
        withTempFileContaining "abc" hashFile >>= (@?= hashBytes "abc")
    , testCase "gives the Id of a file that is larger than one chunk" $ do
        -- About 1 MiB, and not a round multiple of any usual chunk size.
        let content = BS.pack (take (1024 * 1024 + 17) (cycle [0 .. 250]))
        withTempFileContaining content hashFile
          >>= (@?= hashBytes (content))
    , testCase "gives a different Id for a file with different content" $ do
        a <- withTempFileContaining "a" hashFile
        b <- withTempFileContaining "b" hashFile
        assertBool "ids equal" (a /= b)
    , testCase "throws an IOException if the file does not exist" $ do
        r <- try (hashFile "/nonexistent/akyuu-test-missing-file")
        case r of
          Left (_ :: IOException) -> pure ()
          Right i -> assertFailure ("expected an IOException, got " <> show i)
    ]

verifyTests :: TestTree
verifyTests =
  testGroup
    "verify"
    [ testCase "accepts content that matches the Id" $
        assertBool "expected True" (verify (hashBytes "abc") "abc")
    , testCase "accepts the empty content for the Id of the empty string" $
        assertBool "expected True" (verify (hashBytes BS.empty) BS.empty)
    , testCase "rejects content that does not match the Id" $
        assertBool "expected False" (not (verify (hashBytes "abc") "abd"))
    , testCase "rejects content for an Id that no content made" $
        assertBool "expected False" (not (verify (idFromBytes []) BS.empty))
    ]

renderTests :: TestTree
renderTests =
  testGroup
    "render"
    [ testCase "writes sha256- and lower case hex for the empty string" $
        render (hashBytes BS.empty) @?= "sha256-" <> emptyHex
    , testCase "writes sha256- and lower case hex for \"abc\"" $
        render (hashBytes "abc") @?= "sha256-" <> abcHex
    , testCase "writes 64 hex digits for the all-zero digest" $
        render (idFromBytes []) @?= "sha256-" <> T.replicate 64 "0"
    ]

showTests :: TestTree
showTests =
  testGroup
    "Show Id"
    [ testCase "shows the same text as render" $
        show (hashBytes BS.empty) @?= T.unpack ("sha256-" <> emptyHex)
    ]

parseTests :: TestTree
parseTests =
  testGroup
    "parse"
    [ testCase "accepts a valid id" $
        parse ("sha256-" <> emptyHex) @?= Right (hashBytes BS.empty)
    , testCase "reads back what render wrote for a known id" $
        parse (render (hashBytes BS.empty)) @?= Right (hashBytes BS.empty)
    , testCase "reports the prefix error before the hex error" $
        parse "md5-zz" @?= Left (BadPrefix "md5-zz")
    , testCase "reports the hex error before the length error" $
        parse "sha256-abc" @?= Left (BadHex "abc")
    , testCase "rejects a missing prefix" $
        parse emptyHex @?= Left (BadPrefix emptyHex)
    , testCase "rejects a wrong prefix" $
        parse ("md5-" <> emptyHex) @?= Left (BadPrefix ("md5-" <> emptyHex))
    , testCase "rejects non-hex characters" $
        parse "sha256-zz" @?= Left (BadHex "zz")
    , testCase "rejects odd-length hex" $
        parse "sha256-abc" @?= Left (BadHex "abc")
    , testCase "rejects a digest that is too short" $
        parse "sha256-abcd" @?= Left (BadLength 2)
    , testCase "rejects a digest that is too long" $
        parse ("sha256-" <> emptyHex <> "00") @?= Left (BadLength 33)
    , testCase "rejects an empty digest" $
        parse "sha256-" @?= Left (BadLength 0)
    ]

properties :: TestTree
properties =
  testGroup
    "properties"
    [ testProperty "fromDigest succeeds exactly for 32-byte inputs" $ \ws ->
        let b = BS.pack ws
         in isJust' (fromDigest b) === (BS.length b == 32)
    , testProperty "toBytes gives back what fromDigest got" $ \ws ->
        let b = BS.pack (take 32 (ws ++ repeat 0))
         in fmap toBytes (fromDigest b) === Just b
    , testProperty "toBytes always gives 32 bytes" $ \ws ->
        BS.length (toBytes (hashBytes (BS.pack ws))) === 32
    , testProperty "verify accepts the content that hashBytes hashed" $ \ws ->
        let c = BS.pack ws
         in verify (hashBytes c) c
    , testProperty "verify rejects other content" $ \ws ws' ->
        ws /= ws' ==> not (verify (hashBytes (BS.pack ws)) (BS.pack ws'))
    , testProperty "parse accepts every hex-encoded 32-byte digest" $ \ws ->
        let b = BS.pack (take 32 (ws ++ repeat 0))
            t = "sha256-" <> TE.decodeUtf8 (B16.encode b)
         in fmap toBytes (parse t) === Right b
    , testProperty "parse rejects every hex-encoded digest that is not 32 bytes" $ \ws ->
        let b = BS.pack ws
            t = "sha256-" <> TE.decodeUtf8 (B16.encode b)
         in BS.length b /= 32 ==> parse t === Left (BadLength (BS.length b))
    , testProperty "parse (render i) == Right i for hashed content" $ \ws ->
        let i = hashBytes (BS.pack ws)
         in parse (render i) === Right i
    , testProperty "parse (render i) == Right i for any 32-byte digest" $ \ws ->
        let i = idFromBytes ws
         in parse (render i) === Right i
    , testProperty "render writes sha256- and 64 lower case hex digits" $ \ws ->
        let t = render (idFromBytes ws)
            hex = T.drop 7 t
         in conjoin
              [ T.take 7 t === "sha256-"
              , T.length hex === 64
              , T.all (`elem` ['0' .. '9'] ++ ['a' .. 'f']) hex === True
              ]
    , testProperty "show agrees with render" $ \ws ->
        let i = idFromBytes ws
         in show i === T.unpack (render i)
    , testProperty "hashBytes gives the same Id for the same content" $ \ws ->
        hashBytes (BS.pack ws) === hashBytes (BS.pack ws)
    ]
