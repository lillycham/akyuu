{-# LANGUAGE OverloadedStrings #-}

-- | Small changes to the text of a memory.
--
-- A memory never changes, so to fix one sentence an agent had to read the
-- whole body, write it again with the change, and supersede the ref. That
-- costs the whole text twice and is easy to get wrong. An 'Edit' says only
-- the change, and "Akyuu.Ops" does the read, the supersede and the edges.
-- This module is pure.
module Akyuu.Amend
  ( Edit (..),
    AmendError (..),
    applyEdits,
    describeAmend,
  )
where

import Data.Text (Text)
import Data.Text qualified as T

-- | One change to a body.
data Edit
  = -- | Replace this text with that text. The text to replace must occur in
    -- the body exactly once, so that the change is the one that was meant.
    Replace Text Text
  | -- | Add a text after the body, on a new line.
    Append Text
  deriving (Eq, Show)

-- | Why an edit cannot be applied.
data AmendError
  = -- | The text to replace is empty.
    EmptyFrom
  | -- | The text to replace does not occur in the body.
    NotInBody Text
  | -- | The text to replace occurs more than once. The number is the count.
    MoreThanOnce Text Int
  | -- | There is no edit.
    NoEdits
  deriving (Eq, Show)

-- | Apply the edits in order. Each one works on the result of the one
-- before. The first problem is the result.
applyEdits :: [Edit] -> Text -> Either AmendError Text
applyEdits [] _ = Left NoEdits
applyEdits es body = go es body
  where
    go [] b = Right b
    go (Replace from to : rest) b
      | T.null from = Left EmptyFrom
      | otherwise = case T.count from b of
          0 -> Left (NotInBody from)
          1 -> let (pre, post) = T.breakOn from b in go rest (pre <> to <> T.drop (T.length from) post)
          n -> Left (MoreThanOnce from n)
    go (Append t : rest) b = go rest (b <> (if T.null b || "\n" `T.isSuffixOf` b then "" else "\n") <> t)

-- | The text of an error, for a person or an agent.
describeAmend :: AmendError -> Text
describeAmend e = case e of
  EmptyFrom -> "The text to replace is empty."
  NotInBody t -> "The text to replace is not in the memory: " <> quote t
  MoreThanOnce t n -> "The text to replace occurs " <> T.pack (show n) <> " times: " <> quote t <> ". Give more text, so that it occurs once."
  NoEdits -> "There is nothing to change. Give a replacement or text to append."
  where
    quote t = "'" <> T.take 60 t <> "'"
