{-# LANGUAGE OverloadedStrings #-}

-- | Related topics: which other topics belong with a topic, and why.
--
-- The list is derived data. It is computed when it is asked for, from the
-- topics as they are now, and it is never written to the store, so a
-- suggestion cannot become evidence for the next one.
--
-- For a topic @a@ and another topic @b@ the score is
--
-- > z(cosine a b) + 2 * link a b + 1 * mention a b - penalty
--
-- * @z@ is the cosine minus the mean over all pairs of topics, divided by the
--   spread over all pairs ('Stats').
-- * A @link@ is an explicit edge from the current memory of one topic to the
--   other topic. A @mention@ is the name of one topic in the text of the
--   other. Both count in either direction, and both are weaker when their
--   source points at many topics: the strength is @1 / sqrt n@ for a source
--   that points at @n@ topics. Without this a summary that links to every
--   project would become a hub.
-- * The penalty is for two topics that sit side by side in a namespace that
--   the person lists as made of parallel instances (projects, say), and that
--   have neither a link nor a mention. Such topics look alike because they
--   share a template, not because they are related.
--
-- Only a candidate with a score above zero is listed, and at most
-- 'relatedLimit' of them, the best first, ties by name. A topic without a
-- vector has no cosine term. It is listed only if it has a link or a
-- mention. That is the whole fallback when no embedder is set up.
--
-- This module is pure. "Akyuu.Ops" reads the store, builds the 'Topic's and
-- calls it. The weights are fixed: they came from an experiment on one
-- store, and @docs/plans/related-topics.md@ says how far to trust them.
module Akyuu.Related
  ( -- * Input
    Topic (..),
    Config (..),
    defaultConfig,
    topicVector,

    -- * Ranking
    Stats,
    similarityStats,
    Reason (..),
    Related (..),
    relatedLimit,
    relatedTo,

    -- * Evidence
    mentions,

    -- * Showing a reason
    reasonText,
  )
where

import Akyuu.Embed (Vector, cosine)
import Akyuu.Refs (Name, nameText)
import Data.Char (isAlphaNum)
import Data.List (find, sortOn, tails)
import Data.Map qualified as Map
import Data.Maybe (mapMaybe)
import Data.Ord (Down (Down))
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T

-- Input ----------------------------------------------------------------

-- | A topic as the ranking sees it. Logs are not topics: leave them out.
data Topic = Topic
  { -- | The ref name.
    rtName :: Name,
    -- | The vector of its current memory ('topicVector'), if it has one.
    rtVector :: Maybe Vector,
    -- | The topics that its current memory links to: through an
    -- @about-ref@, or through an edge to a memory that the other ref now
    -- names or named before.
    rtLinks :: Set Name,
    -- | The text of its current memory.
    rtText :: Text
  }
  deriving (Eq, Show)

-- | The settings that the ranking reads.
newtype Config = Config
  { -- | Namespaces whose topics are parallel instances of one kind, such as
    -- @work/projects@. Two topics directly under one of them need a link or
    -- a mention to be related.
    cfgParallel :: [Text]
  }
  deriving (Eq, Show)

-- | No namespace is parallel.
defaultConfig :: Config
defaultConfig = Config []

-- | The vector of a topic: the mean of the unit-length vectors of the chunks
-- of its current memory. Chunks of a length other than the first one's, and
-- chunks of length zero, are left out. 'Nothing' if none is left.
topicVector :: [Vector] -> Maybe Vector
topicVector chunks = case mapMaybe unit chunks of
  [] -> Nothing
  us@(u : _) ->
    let same = filter ((== length u) . length) us
     in Just (map (/ fromIntegral (length same)) (foldr1 (zipWith (+)) same))

unit :: Vector -> Maybe Vector
unit v
  | norm == 0 = Nothing
  | otherwise = Just (map (/ realToFrac norm) v)
  where
    norm = sqrt (sum [realToFrac x * realToFrac x | x <- v]) :: Double

-- Ranking --------------------------------------------------------------

-- | The mean and the spread of the cosine over all pairs of topics. They
-- depend on every topic, so a caller that asks for many topics computes them
-- once.
data Stats = Stats Double Double

-- | The mean and the spread of the cosine of every pair of topics that have
-- a vector. This costs one cosine for each pair.
similarityStats :: [Topic] -> Stats
similarityStats topics
  | null sims = Stats 0 0
  | otherwise = Stats m (sqrt var)
  where
    vs = mapMaybe rtVector topics
    sims = [cosine u v | (u : rest) <- tails vs, v <- rest]
    n = fromIntegral (length sims)
    m = sum sims / n
    var = sum [(s - m) ^ (2 :: Int) | s <- sims] / n

-- | The cosine in units of the spread. With no spread, nothing stands out.
zScore :: Stats -> Double -> Double
zScore (Stats m s) x
  | s < 1e-9 = 0
  | otherwise = (x - m) / s

-- | Why a topic is listed, the strongest reason that applies.
data Reason
  = -- | An explicit link, in either direction.
    Linked
  | -- | The name of one topic is in the text of the other.
    Mentioned
  | -- | Only the text is alike. The weakest reason.
    SimilarText
  deriving (Eq, Show)

data Related = Related
  { relName :: Name,
    relReason :: Reason,
    relScore :: Double
  }
  deriving (Eq, Show)

-- | The most topics that 'relatedTo' lists.
relatedLimit :: Int
relatedLimit = 3

linkWeight, mentionWeight, siblingPenalty :: Double
linkWeight = 2
mentionWeight = 1
siblingPenalty = 2

-- | The topics that are related to one topic, the best first. An empty list
-- for a name that is not among the topics.
--
-- The names in the set are left out, and the limit counts what is left. A
-- caller that already shows some topics (the ones that a topic is about) asks
-- for the others.
relatedTo :: Config -> Stats -> Set Name -> Name -> [Topic] -> [Related]
relatedTo cfg stats leaveOut self topics = case find ((== self) . rtName) topics of
  Nothing -> []
  Just me ->
    take relatedLimit . sortOn rankKey $
      mapMaybe (candidate (rtVector me)) (filter shown topics)
  where
    shown t = rtName t /= self && rtName t `Set.notMember` leaveOut
    g = graph topics
    candidate v b
      | s > 0 = Just (Related (rtName b) (reason ev) s)
      | otherwise = Nothing
      where
        ev = evidenceBetween g self (rtName b)
        s = score cfg stats self (rtName b) (cosine <$> v <*> rtVector b) ev

-- | The best first. Scores that differ only in the last digits, because the
-- sums ran in another order, are equal: the name decides, as the order of the
-- topics must not.
rankKey :: Related -> (Down Integer, Name)
rankKey r = (Down (round (relScore r * 1e9)), relName r)

-- | For each topic, the other topics that it points at: through a link, and
-- through a mention of the name. Only the names of topics count.
--
-- Every set is used, because the strength of a pointer depends on the size of
-- its source's set and a candidate is looked up in both directions. So the
-- graph costs one 'mentions' for each pair of topics.
data Graph = Graph
  { gLinks :: Map.Map Name (Set Name),
    gMentions :: Map.Map Name (Set Name)
  }

graph :: [Topic] -> Graph
graph topics =
  Graph
    { gLinks = Map.fromList [(rtName t, Set.delete (rtName t) (rtLinks t) `Set.intersection` names) | t <- topics],
      gMentions = Map.fromList [(rtName t, Set.filter (\n -> n /= rtName t && mentions n (rtText t)) names) | t <- topics]
    }
  where
    names = Set.fromList (map rtName topics)

-- | How strongly two topics point at each other, in the stronger direction.
data Evidence = Evidence
  { evLink :: Double,
    evMention :: Double
  }

evidenceBetween :: Graph -> Name -> Name -> Evidence
evidenceBetween g a b = Evidence (stronger (gLinks g)) (stronger (gMentions g))
  where
    stronger m = max (strength m a b) (strength m b a)

hasEvidence :: Evidence -> Bool
hasEvidence ev = evLink ev > 0 || evMention ev > 0

-- | How strongly a source points at a target: 1 / sqrt of the number of
-- topics that the source points at, or 0 if it does not.
strength :: Map.Map Name (Set Name) -> Name -> Name -> Double
strength m from to = case Map.lookup from m of
  Just s | to `Set.member` s -> 1 / sqrt (fromIntegral (Set.size s))
  _ -> 0

-- | The score in the module header, for a topic @a@ and a candidate @b@, with
-- their cosine if both have a vector. Without a cosine and without evidence
-- the score is at most zero, so such a candidate is never listed.
score :: Config -> Stats -> Name -> Name -> Maybe Double -> Evidence -> Double
score cfg stats a b sim ev =
  maybe 0 (zScore stats) sim + linkWeight * evLink ev + mentionWeight * evMention ev - penalty
  where
    penalty
      | siblings cfg a b && not (hasEvidence ev) = siblingPenalty
      | otherwise = 0

-- | The strongest reason that applies.
reason :: Evidence -> Reason
reason ev
  | evLink ev > 0 = Linked
  | evMention ev > 0 = Mentioned
  | otherwise = SimilarText

-- | Do two topics sit directly under one namespace that is listed as parallel?
siblings :: Config -> Name -> Name -> Bool
siblings cfg a b = not (T.null p) && p == parent b && p `elem` cfgParallel cfg
  where
    p = parent a

-- | The namespace of a name: all but the last part. Empty for a name of one
-- part.
parent :: Name -> Text
parent = T.dropEnd 1 . fst . T.breakOnEnd "/" . nameText

-- Evidence -------------------------------------------------------------

-- | Is the whole name in the text? A longer name or path that contains it does
-- not count: @kitchen/oven2@, @home/kitchen/oven@, @kitchen/oven/door@ and
-- @kitchen/oven.l1@ do not mention @kitchen/oven@. A full stop that ends a
-- sentence does.
mentions :: Name -> Text -> Bool
mentions n text = any whole (T.breakOnAll needle text)
  where
    needle = nameText n
    whole (before, rest) = okBefore before && okAfter (T.drop (T.length needle) rest)
    okBefore before = maybe True (not . partOfName . snd) (T.unsnoc before)
    okAfter after = case T.uncons after of
      Nothing -> True
      Just (c, r)
        | c `elem` ("/." :: String) -> maybe True (not . isNameChar . fst) (T.uncons r)
        | otherwise -> not (isNameChar c)
    isNameChar c = isAlphaNum c || c `elem` ("_-" :: String)
    partOfName c = isNameChar c || c `elem` ("/." :: String)

-- Showing a reason -----------------------------------------------------

-- | The words that the agent reads.
reasonText :: Reason -> Text
reasonText Linked = "linked"
reasonText Mentioned = "mentioned"
reasonText SimilarText = "similar text"
