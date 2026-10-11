{-# LANGUAGE OverloadedStrings #-}

-- | Spelling tolerance for the text search.
--
-- This module is pure. It finds the terms of a vocabulary that are a small
-- number of edits away from a word that the index does not have. The text
-- index of the cache holds stems (it uses the Porter stemmer), so the
-- comparison is also made with the start of the word, as long as the term.
module Akyuu.Fuzzy
  ( editDistance,
    maxEdits,
    nearTerms,
  )
where

import Data.List (sortOn)
import Data.Ord (Down (Down))
import Data.Sequence ((|>))
import Data.Sequence qualified as Seq
import Data.Text (Text)
import Data.Text qualified as T

-- | The optimal string alignment distance: the least number of insertions,
-- deletions, substitutions and swaps of two neighbour characters that make
-- one text the other. A swap counts as one edit, because it is the most
-- common typing mistake. This function is pure.
editDistance :: Text -> Text -> Int
editDistance a b = Seq.index final n
  where
    sb = Seq.fromList (T.unpack b)
    n = Seq.length sb
    initial = Seq.fromList [0 .. n]
    (_, final, _, _) = foldl' step (initial, initial, Nothing, 0 :: Int) (T.unpack a)
    -- One row of the table: the row before (p), the one before that (pp),
    -- the character of the row before (prevC), and the number of the new row.
    step (pp, p, prevC, i) ca = (p, cur, Just ca, i')
      where
        i' = i + 1
        cur = foldl' cell (Seq.singleton i') [1 .. n]
        cell row j =
          let cb = Seq.index sb (j - 1)
              sub = Seq.index p (j - 1) + (if ca == cb then 0 else 1)
              del = Seq.index p j + 1
              ins = Seq.index row (j - 1) + 1
              swap = case prevC of
                Just pc | j > 1 && ca == Seq.index sb (j - 2) && pc == cb -> [Seq.index pp (j - 2) + 1]
                _ -> []
           in row |> minimum (sub : del : ins : swap)

-- | How many edits a word may be away from a term, by the length of the
-- word. A short word gets none: it would match too many terms.
maxEdits :: Text -> Int
maxEdits w
  | n < 4 = 0
  | n < 7 = 1
  | otherwise = 2
  where
    n = T.length w

-- | The terms of a vocabulary that are near a word, the nearest first.
--
-- The vocabulary is a list of terms with the number of memories that hold
-- each one. A term is near if it is within 'maxEdits' of the word, or of the
-- start of the word that is as long as the term (a stem is shorter than the
-- word that it comes from; that second distance counts one more, so a long
-- word is not near every term that it starts with; a term of fewer than five
-- characters, or one that does not start like the word, is not compared this
-- way: it would be near too many long words). The
-- word itself is not a result. The terms with the same distance go by number of memories. At most
-- @k@ terms are returned.
nearTerms :: Int -> Text -> [(Text, Int)] -> [Text]
nearTerms k w vocab =
  map fst . take k . sortOn (\(t, (d, c)) -> (d, Down c, t)) $
    [ (t, (d, c))
    | (t, c) <- vocab,
      t /= w,
      -- A term of another length is far, unless it can be the start of the word.
      abs (T.length t - T.length w) <= limit || T.length w > T.length t,
      let d = distance t,
      d <= limit
    ]
  where
    limit = maxEdits w
    -- The index holds stems (porter), so a plural or another ending of the
    -- word is cut too: "emcas" is one edit from the stem "emac" once the
    -- "s" is gone. Each form must stay at 4 characters or more.
    forms = w : [x | suf <- ["ing", "es", "ed", "s", "e", "y"], Just x <- [T.stripSuffix suf w], T.length x >= 4]
    distance t =
      min
        (minimum [editDistance f t | f <- forms])
        (if T.length w > T.length t && T.length t >= 5 && T.take 3 t == T.take 3 w then editDistance (T.take (T.length t) w) t + 1 else maxBound)
