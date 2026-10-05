{-# LANGUAGE OverloadedStrings #-}
module Main (main) where

import Akyuu.Id
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Short qualified as SBS
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Test.Tasty
import Test.Tasty.HUnit
import Test.Tasty.QuickCheck

main :: IO ()
main = defaultMain $ testGroup "Akyuu.Id" [digestTests, hashTests, renderTests, parseTests, properties]

-- An Id for 32 arbitrary bytes. Any 32 bytes are a valid digest.
idFromBytes ws = case fromDigest (BS.pack (take 32 (ws ++ repeat 0))) of
  Just i  -> i
  Nothing -> error "idFromBytes: digest is not 32 bytes"

-- SHA-256 test vectors (FIPS 180-4 / NIST).
emptyHex, abcHex :: Text
emptyHex = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
abcHex   = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

-- `Id` has no `Show` instance, so compare parse results by their shape.
shape :: Either IdParseError a -> String
shape = either show (const "ok")

digestTests :: TestTree
digestTests = testGroup "fromDigest"
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
      fmap (== hashBytes SBS.empty) (fromDigest (hexBytes emptyHex)) @?= Just True
  ]
  where
    isJust' = maybe False (const True)

hashTests :: TestTree
hashTests = testGroup "hashBytes"
  [ testCase "matches the SHA-256 vector for the empty string" $
      assertBool "ids differ" (parse ("sha256-" <> emptyHex) == Right (hashBytes SBS.empty))
  , testCase "matches the SHA-256 vector for \"abc\"" $
      assertBool "ids differ" (parse ("sha256-" <> abcHex) == Right (hashBytes (SBS.toShort "abc")))
  , testCase "is deterministic" $
      assertBool "ids differ" (hashBytes (SBS.toShort "akyuu") == hashBytes (SBS.toShort "akyuu"))
  , testCase "distinguishes different inputs" $
      assertBool "ids equal" (hashBytes (SBS.toShort "a") /= hashBytes (SBS.toShort "b"))
  ]

renderTests :: TestTree
renderTests = testGroup "render"
  [ testCase "writes sha256- and lower case hex for the empty string" $
      render (hashBytes SBS.empty) @?= "sha256-" <> emptyHex
  , testCase "writes sha256- and lower case hex for \"abc\"" $
      render (hashBytes (SBS.toShort "abc")) @?= "sha256-" <> abcHex
  , testCase "writes 64 hex digits for the all-zero digest" $
      render (idFromBytes []) @?= "sha256-" <> T.replicate 64 "0"
  ]

parseTests :: TestTree
parseTests = testGroup "parse"
  [ testCase "accepts a valid id" $
      shape (parse ("sha256-" <> emptyHex)) @?= "ok"
  , testCase "reads back what render wrote for a known id" $
      parse (render (hashBytes SBS.empty)) == Right (hashBytes SBS.empty) @? "ids differ"
  , testCase "reports the prefix error before the hex error" $
      shape (parse "md5-zz") @?= show' "BadPrefix" "md5-zz"
  , testCase "reports the hex error before the length error" $
      shape (parse "sha256-abc") @?= show' "BadHex" "abc"
  , testCase "rejects a missing prefix" $
      shape (parse emptyHex) @?= show' "BadPrefix" emptyHex
  , testCase "rejects a wrong prefix" $
      shape (parse ("md5-" <> emptyHex)) @?= show' "BadPrefix" ("md5-" <> emptyHex)
  , testCase "rejects non-hex characters" $
      shape (parse "sha256-zz") @?= show' "BadHex" "zz"
  , testCase "rejects odd-length hex" $
      shape (parse "sha256-abc") @?= show' "BadHex" "abc"
  , testCase "rejects a digest that is too short" $
      shape (parse "sha256-abcd") @?= "BadLength 2"
  , testCase "rejects a digest that is too long" $
      shape (parse ("sha256-" <> emptyHex <> "00")) @?= "BadLength 33"
  , testCase "rejects an empty digest" $
      shape (parse "sha256-") @?= "BadLength 0"
  ]
  where
    show' con t = con <> " " <> show (T.unpack t)

properties :: TestTree
properties = testGroup "properties"
  [ testProperty "fromDigest succeeds exactly for 32-byte inputs" $ \ws ->
      let b = BS.pack ws
       in maybe False (const True) (fromDigest b) === (BS.length b == 32)
  , testProperty "parse accepts every hex-encoded 32-byte digest" $ \ws ->
      let b = BS.pack (take 32 (ws ++ repeat 0))
          t = "sha256-" <> TE.decodeUtf8 (B16.encode b)
       in shape (parse t) === "ok"
  , testProperty "parse rejects every hex-encoded digest that is not 32 bytes" $ \ws ->
      let b = BS.pack ws
          t = "sha256-" <> TE.decodeUtf8 (B16.encode b)
       in BS.length b /= 32 ==> shape (parse t) === ("BadLength " <> show (BS.length b))
  , testProperty "parse (render i) == Right i for hashed content" $ \ws ->
      let i = hashBytes (SBS.pack ws)
       in parse (render i) == Right i
  , testProperty "parse (render i) == Right i for any 32-byte digest" $ \ws ->
      let i = idFromBytes ws
       in parse (render i) == Right i
  , testProperty "render writes sha256- and 64 lower case hex digits" $ \ws ->
      let t = render (idFromBytes ws)
          hex = T.drop 7 t
       in conjoin
            [ T.take 7 t === "sha256-"
            , T.length hex === 64
            , T.all (`elem` ['0' .. '9'] ++ ['a' .. 'f']) hex === True
            ]
  , testProperty "hashBytes gives the same Id for the same content" $ \ws ->
      hashBytes (SBS.pack ws) == hashBytes (SBS.pack ws)
  ]

-- Decode hex that the tests know is valid.
hexBytes :: Text -> BS.ByteString
hexBytes = either error id . B16.decode . TE.encodeUtf8
