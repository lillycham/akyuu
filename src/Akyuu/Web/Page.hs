{-# LANGUAGE TemplateHaskell #-}

-- | The page of the web UI, and the static export.
--
-- The page is one HTML file, @web/index.html@, with its CSS and JavaScript
-- inside it. It loads nothing from the network. The build puts the file in
-- the binary ('embedFile'), so the server never reads a file from disk to
-- answer a request.
--
-- The static export ('vizPage') is the same page with the data inside it,
-- in a @\<script type="application/json"\>@ element. The page finds that
-- element and then reads the data from it, and not from the server.
module Akyuu.Web.Page
  ( indexPage,
    dataMarker,
    vizPage,
    scriptSafeJSON,
  )
where

import Data.Aeson (Value)
import Data.Aeson qualified as A
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Builder qualified as B
import Data.ByteString.Lazy qualified as BL
import Data.FileEmbed (embedFile)

-- | The page, as the build read it from @web/index.html@.
indexPage :: ByteString
indexPage = $(embedFile "web/index.html")

-- | The place in the page where 'vizPage' puts the data. It is an HTML
-- comment, so the live page ignores it.
dataMarker :: ByteString
dataMarker = "<!--AKYUU-DATA-->"

-- | The page with this data inside it, for @akyuu viz@.
--
-- The data goes in place of 'dataMarker', in an element
-- @\<script type="application/json" id="akyuu-data"\>@. The JSON is made safe
-- for that place with 'scriptSafeJSON'. If the page has no marker, the
-- element goes at the end.
vizPage :: Value -> ByteString
vizPage v = before <> element <> BS.drop (BS.length dataMarker) after
  where
    (before, after) = BS.breakSubstring dataMarker indexPage
    element =
      "<script type=\"application/json\" id=\"akyuu-data\">"
        <> BL.toStrict (scriptSafeJSON v)
        <> "</script>"

-- | Encode a value as JSON that is safe inside a @\<script\>@ element.
--
-- A memory body is untrusted text. It can hold @\</script\>@ or @\<!--@,
-- which would end the element or change how the browser reads it. So each
-- @<@, @>@ and @&@ becomes a JSON escape (@\\u003c@ and so on). Outside of
-- strings, JSON has none of these characters, so the result is still the
-- same JSON value.
scriptSafeJSON :: Value -> BL.ByteString
scriptSafeJSON = B.toLazyByteString . BL.foldr (\w acc -> esc w <> acc) mempty . A.encode
  where
    esc 0x3c = B.string7 "\\u003c"
    esc 0x3e = B.string7 "\\u003e"
    esc 0x26 = B.string7 "\\u0026"
    esc w = B.word8 w
