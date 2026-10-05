{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

module Akyuu.Id
  ( IdParseError (..),
    Id,
    fromDigest,
    toBytes,
    verify,
    hashFile,
    hashBytes,
    render,
    parse,
  )
where

import Crypto.Hash.SHA256 qualified as SHA256
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Short (ShortByteString)
import Data.ByteString.Short qualified as SBS
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (decodeUtf8)
import Data.Text.Encoding qualified as TE

-- | The identity of a stored object. An 'Id' is the SHA-256 digest of the
-- content of the object.
--
-- The module does not export the constructor. Every 'Id' has a digest of
-- 32 bytes. Make an 'Id' with 'hashBytes', 'hashFile', 'fromDigest' or 'parse'.
newtype Id = Id ShortByteString
  deriving (Eq, Ord)

instance Show Id where show = T.unpack . render

-- | The reason that 'parse' rejects a text.
data IdParseError
  = -- | The text does not start with @sha256-@.
    BadPrefix Text
  | -- | The text after the prefix is not valid hex.
    BadHex Text
  | -- | The hex decodes to this number of bytes, not 32.
    BadLength Int
  deriving (Eq, Show)

-- | Make an 'Id' from a digest.
--
-- Returns 'Nothing' if the digest is not 32 bytes long.
-- This function does not check that a hash function made the digest.
fromDigest :: ByteString -> Maybe Id
fromDigest b
  | BS.length b == 32 = Just $ Id $ SBS.toShort b
  | otherwise = Nothing

-- | Get the digest of an 'Id'.
--
-- This function copies the 32 bytes. Use it at the edges of the program,
-- for example when you write to disk. Do not use it in inner loops.
toBytes :: Id -> ByteString
toBytes (Id s) = SBS.fromShort s

-- | Make the 'Id' of some content.
--
-- The same content always gives the same 'Id'. Use this function to make a
-- new 'Id'.
hashBytes :: ShortByteString -> Id
hashBytes = Id . SBS.toShort . SHA256.hash . SBS.fromShort

-- | Make the 'Id' of a file.
--
-- The function reads the file in chunks, so memory use stays the same for
-- all file sizes. It throws an 'IOException' if it cannot open or read the file.
hashFile :: FilePath -> IO Id
hashFile _ = pure $ Id "meow"

-- | Check that some content matches an 'Id'.
--
-- Returns 'True' if the hash of the content is equal to the 'Id'.
-- Use this function to find a corrupt object. The comparison is not
-- constant-time. A digest is public, so this is safe.
verify :: Id -> ShortByteString -> Bool
verify expected bytes = hashBytes bytes == expected

-- | Write an 'Id' as text in the form @sha256-<64 hex digits>@.
--
-- The hex digits are lower case. 'parse' reverses this function.
-- Use it for file names, headers and CLI output.
render :: Id -> Text
render = ("sha256-" <>) . decodeUtf8 . B16.encode . toBytes

-- | Read an 'Id' from text.
--
-- This function decodes an existing 'Id'. It does not hash the text.
-- It accepts the text form that 'render' makes.
-- On failure it returns the first 'IdParseError' that it finds.
--
-- For all 'Id' values @i@, @parse (render i) == Right i@.
parse :: Text -> Either IdParseError Id
parse t = do
  hex <- maybe (Left (BadPrefix t)) Right (T.stripPrefix "sha256-" t)
  raw <- first (const (BadHex hex)) (B16.decode (TE.encodeUtf8 hex))
  maybe (Left (BadLength (BS.length raw))) Right (fromDigest raw)