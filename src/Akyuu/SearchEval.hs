{-# LANGUAGE OverloadedStrings #-}

-- | A set of searches with the answers that a person expects, to judge a
-- change of the search (for example the search by meaning).
--
-- The set is a memory, so it has a history. Each line is
--
-- > category | query => ref ref ...
--
-- A line that does not have this form is skipped, so the memory can have
-- notes. A trailing @(?)@ after the refs marks a guess. An empty list of refs
-- means that no memory is relevant. This module is pure.
module Akyuu.SearchEval
  ( Case (..),
    parseCases,
    passes,
    defaultEvalSetRef,
  )
where

import Data.Text (Text)
import Data.Text qualified as T

-- | The ref of the set of searches when none is given.
defaultEvalSetRef :: Text
defaultEvalSetRef = "policy/embedding-eval"

-- | One search and the answer that is expected.
data Case = Case
  { caseCategory :: Text,
    caseQuery :: Text,
    -- | The names of the refs whose memory should be among the first hits.
    -- Empty: nothing is relevant.
    caseExpect :: [Text],
    -- | The line ends with @(?)@.
    caseGuess :: Bool
  }
  deriving (Eq, Show)

-- | The cases of a set.
parseCases :: Text -> [Case]
parseCases = concatMap line . T.lines
  where
    line l = case T.breakOn "|" l of
      (cat, rest)
        | T.null rest -> []
        | otherwise -> case T.breakOn "=>" (T.drop 1 rest) of
            (q, arrow)
              | T.null arrow || not (validCat (T.strip cat)) -> []
              | otherwise ->
                  let ws = T.words (T.drop 2 arrow)
                      guess = "(?)" `elem` ws
                   in [Case (T.strip cat) (T.strip q) (filter (/= "(?)") ws) guess]
    validCat c = not (T.null c) && T.all (\ch -> ch >= 'a' && ch <= 'z') c

-- | Does a result pass? For a case with refs: one of them is in the refs of
-- the hits (the caller gives the first k hits). For a case with no refs: there
-- are no hits at all.
passes :: Case -> [Text] -> Bool
passes c hitRefs
  | null (caseExpect c) = null hitRefs
  | otherwise = any (`elem` hitRefs) (caseExpect c)
