-- | Compare the text of two memories.
--
-- This is the pure part of @compare@. It answers one question for a person
-- or an agent that must choose between two memories: what does each one say
-- that the other one does not?
--
-- A memory is cut into sentences, and a sentence is the unit of the
-- comparison. The order of the sentences does not matter, and neither do
-- white space and case. So a memory that has one more sentence than the other
-- shows exactly that sentence.
--
-- The result is also a guard. A memory can be dropped in favour of another
-- one only if it has no sentence that the other one lacks ('canDrop'). A
-- verdict "these are duplicates" that fails this test lost a fact.
module Akyuu.Compare
  ( Comparison (..),
    compareText,
    canDropA,
    canDropB,
    sentences,
  )
where

import Akyuu.Check (jaccard, normalise, shingles)
import Data.Char (isSpace)
import Data.List (nub)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T

-- | What two texts share, and what each one has alone.
data Comparison = Comparison
  { -- | The share of word triples that the texts have in common, from 0 to 1.
    -- It is the number that @check@ uses for near duplicates.
    cmpShared :: Double,
    -- | The sentences of the first text that the second one lacks, in order.
    cmpOnlyA :: [Text],
    -- | The sentences of the second text that the first one lacks, in order.
    cmpOnlyB :: [Text]
  }
  deriving (Eq, Show)

-- | Compare two texts. This function is pure.
compareText :: Text -> Text -> Comparison
compareText a b =
  Comparison
    { cmpShared = jaccard (shingles (normalise a)) (shingles (normalise b)),
      cmpOnlyA = missingFrom sb sa,
      cmpOnlyB = missingFrom sa sb
    }
  where
    sa = sentences a
    sb = sentences b
    -- The sentences of the second list, that the first list lacks.
    missingFrom have xs =
      let known = Set.fromList (map normalise have)
       in nub [x | x <- xs, normalise x `Set.notMember` known]

-- | Can the first memory be dropped in favour of the second? Only if it has
-- no sentence that the second one lacks.
canDropA :: Comparison -> Bool
canDropA = null . cmpOnlyA

-- | Can the second memory be dropped in favour of the first?
canDropB :: Comparison -> Bool
canDropB = null . cmpOnlyB

-- | The sentences of a text. A sentence ends with @.@, @?@ or @!@ before white
-- space or the end, or at the end of a line. Blank lines give nothing.
sentences :: Text -> [Text]
sentences = concatMap (map T.pack . go . T.unpack . T.strip) . T.lines
  where
    go "" = []
    go s = let (x, rest) = one s in x : go (dropWhile isSpace rest)
    one [] = ([], [])
    one (c : r)
      | c `elem` (".?!" :: String), all isSpace (take 1 r) = ([c], r)
      | otherwise = let (x, rest) = one r in (c : x, rest)
