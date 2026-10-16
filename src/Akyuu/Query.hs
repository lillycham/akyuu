-- | Queries over the store: text search widened to a neighbourhood, and the
-- edges around one memory.
--
-- The module has a pure part and a thin I/O part. The pure part
-- ('searchResult', 'neighbourList') gets the graph and the hits of the cache
-- as data, so tests and other callers can use it without a database. The I/O
-- part ('search', 'neighbours') only reads the cache and calls the pure part.
--
-- The results are plain data. This module does not make text for a person:
-- the CLI and the MCP server each render the same values in their own way.
--
-- The I/O functions do not call 'Akyuu.Cache.sync'. The caller decides when
-- the cache must match the store.
module Akyuu.Query
  ( -- * Search
    SearchOptions (..),
    Semantic (..),
    defaultSearchOptions,
    Match (..),
    SearchResult (..),
    searchResult,
    headsFirst,
    Boost (..),
    noBoost,
    rankHits,
    Tuning (..),
    defaultTuning,
    search,
    searchWith,

    -- * Neighbours
    Neighbour (..),
    neighbourList,
    neighbours,
    RefLink (..),
    refLinkList,

    -- * Resolve
    resolve,
  )
where

import Akyuu.Cache (Cache, CacheError, Correction (AddedByMeaning), Hit (Hit, hitId, hitSnippet))
import Akyuu.Cache qualified as Cache
import Akyuu.Embed (fuse)
import Akyuu.Graph (Dir (In, Out), EdgeType (Supersedes), Graph)
import Akyuu.Graph qualified as Graph
import Akyuu.Id (Id)
import Akyuu.Refs (Name)
import Control.Monad.Trans.Except (ExceptT (ExceptT), runExceptT)
import Data.List (partition, sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (mapMaybe)
import Data.Ord (Down (Down))
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Time (UTCTime, diffUTCTime)

-- Search ---------------------------------------------------------------

-- | The settings of one search.
data SearchOptions = SearchOptions
  { -- | The most text hits to return. See 'Akyuu.Cache.search'.
    searchLimit :: Int,
    -- | How many edges away from a hit the context reaches. 0 means no
    -- context.
    searchHops :: Int,
    -- | The kinds of edge that the context follows. A set and not a
    -- predicate, so the options can be shown and compared.
    searchFollow :: Set EdgeType
  }
  deriving (Eq, Show)

-- | Ten hits, one hop of context, along every kind of edge.
defaultSearchOptions :: SearchOptions
defaultSearchOptions =
  SearchOptions
    { searchLimit = 10,
      searchHops = 1,
      searchFollow = Set.fromList [minBound .. maxBound]
    }

-- | One text hit, with what the graph knows about it.
data Match = Match
  { -- | The memory that matched.
    matchId :: Id,
    -- | The piece of the body around the match, from 'Akyuu.Cache.search'.
    matchSnippet :: Text,
    -- | The memories that have a 'Supersedes' edge to this one. If the set
    -- is not empty, the match is an old version, and an agent should read
    -- the newer one. More than one means a fork. This module does not
    -- choose between them.
    matchSupersededBy :: Set Id
  }
  deriving (Eq, Show)

-- | The result of a search.
data SearchResult = SearchResult
  { -- | The text hits, best first.
    matches :: [Match],
    -- | The memories within 'searchHops' edges of a hit, that are not hits
    -- themselves. This can hold a dangling target: an 'Id' that some edge
    -- names but that is not in the graph.
    context :: Set Id,
    -- | What the fuzzy step changed in the query: a word that the index does
    -- not have, searched as a prefix or as a near term. Empty for a query
    -- of words that exist.
    corrections :: [Correction]
  }
  deriving (Eq, Show)

-- | Widen the hits of a text search with the graph. This function is pure.
--
-- The context is @'Graph.withinHops' (searchHops o)@ from the hits, along
-- the kinds in 'searchFollow', minus the hits. The order of the hits does not
-- change. The function does not apply 'searchLimit': the hits are already
-- limited.
searchResult :: SearchOptions -> Graph -> [Hit] -> SearchResult
searchResult o g hits =
  SearchResult
    { matches = map toMatch hits,
      context = near `Set.difference` ids,
      corrections = []
    }
  where
    ids = Set.fromList (map hitId hits)
    near = Graph.withinHops (searchHops o) (`Set.member` searchFollow o) ids g
    toMatch h =
      Match
        { matchId = hitId h,
          matchSnippet = hitSnippet h,
          matchSupersededBy = Graph.predecessors Supersedes (hitId h) g
        }

-- | Put the current memories before the old versions. This function is pure.
--
-- A hit is an old version if a memory has a 'Supersedes' edge to it. The
-- order inside each group does not change, so the best text match is still
-- first in its group. A person or an agent that asks for a few hits then gets
-- the current memories, and not the ones that something replaced.
headsFirst :: Graph -> [Hit] -> [Hit]
headsFirst g hits = current <> old
  where
    (old, current) = partition replaced hits
    replaced h = not (Set.null (Graph.predecessors Supersedes (hitId h) g))

-- | How many hits 'search' asks the text index for, for a limit of @n@.
--
-- The text index does not know the graph. If it returned only @n@ hits, all
-- of them could be old versions, and 'headsFirst' could not help. So 'search'
-- reads more, puts the current memories first, and then cuts the list to @n@.
fetchCount :: Int -> Int
fetchCount n = max 0 n * 4

-- | Search the bodies with 'Akyuu.Cache.search', then widen the hits with
-- the graph of the cache ('searchResult').
--
-- The current memories come before the old versions ('headsFirst'). The
-- function reads @4 * 'searchLimit'@ hits from the text index, orders them,
-- and keeps the first 'searchLimit'. An old version stays in the result if
-- there are not enough current memories to fill it.
search :: Cache -> SearchOptions -> Text -> IO (Either CacheError SearchResult)
search c = searchWith c defaultTuning

-- | What 'searchWith' does besides the text match.
data Tuning = Tuning
  { -- | Forgive a word that the index does not have: search it as a prefix,
    -- or as a near term ('Akyuu.Cache.searchFuzzy'). A word that exists is
    -- never changed.
    tuneFuzzy :: Bool,
    -- | The signals that reorder the hits.
    tuneBoost :: Boost,
    -- | Memories in the order of their meaning, from 'Akyuu.Embed'. 'Nothing'
    -- is a text search only.
    tuneSemantic :: Maybe Semantic
  }
  deriving (Eq, Show)

-- | A ranking by meaning, and how to use it.
data Semantic = Semantic
  { -- | The memories nearest to the query, nearest first.
    semRanked :: [Id],
    -- | 'True': return only these. 'False': fuse them with the text hits
    -- ('Akyuu.Embed.fuse').
    semOnly :: Bool
  }
  deriving (Eq, Show)

-- | Fuzzy on, and no boost: the order is the order of the text index.
defaultTuning :: Tuning
defaultTuning = Tuning {tuneFuzzy = True, tuneBoost = noBoost, tuneSemantic = Nothing}

-- | Signals from outside the text index that rank a hit higher.
data Boost = Boost
  { -- | The time now. With a time, a newer memory ranks higher. 'Nothing'
    -- means no preference for the new.
    boostNow :: Maybe UTCTime,
    -- | The memories that a ref holds now. A ref is a topic that somebody
    -- chose to keep current, so its memory ranks higher.
    boostHeld :: Set Id
  }
  deriving (Eq, Show)

-- | No boost: 'rankHits' keeps the order.
noBoost :: Boost
noBoost = Boost {boostNow = Nothing, boostHeld = Set.empty}

-- | Reorder the hits of the text index. This function is pure.
--
-- Each hit gets the score @1 / (3 + r)@, where @ is its place in the
-- text index order (best first), so the text match stays the main signal.
-- The score is multiplied by 1.3 if a ref holds the memory, and by a factor
-- from 1.3 (a new memory) down to 1 (an old one) that loses half of its gain
-- every 90 days. One signal moves a hit up about one place. A held memory
-- that is also new can pass the best match from the next place, and no
-- boost lifts a hit from far down. The sort is stable, and with 'noBoost'
-- the order does not change.
rankHits :: Boost -> Map Id UTCTime -> [Hit] -> [Hit]
rankHits b created hits = map snd (sortOn (Down . fst) (zip scores hits))
  where
    scores = [score r h | (r, h) <- zip [0 :: Int ..] hits]
    score r h = 1 / (3 + fromIntegral r) * held h * recent h :: Double
    held h = if hitId h `Set.member` boostHeld b then 1.3 else 1
    recent h = case (boostNow b, Map.lookup (hitId h) created) of
      (Just now, Just t) -> 1 + 0.3 * 0.5 ** (max 0 (realToFrac (diffUTCTime now t) / 86400) / 90)
      _ -> 1

-- | 'search' with a 'Tuning'.
--
-- The text index is asked for @4 * 'searchLimit'@ hits. They are reordered
-- by 'rankHits', the current memories go before the old versions
-- ('headsFirst'), and the list is cut to the limit.
searchWith :: Cache -> Tuning -> SearchOptions -> Text -> IO (Either CacheError SearchResult)
searchWith c t o q = runExceptT $ do
  let n = fetchCount (searchLimit o)
  (hits, notes) <-
    if tuneFuzzy t
      then ExceptT (Cache.searchFuzzy c q n)
      else (\h -> (h, [])) <$> ExceptT (Cache.search c q n)
  g <- ExceptT (Cache.loadGraph c)
  created <-
    if tuneBoost t == noBoost || null hits
      then pure Map.empty
      else ExceptT (Cache.createdTimes c (map hitId hits))
  let textRanked = rankHits (tuneBoost t) created hits
  (joined, byMeaning) <- case tuneSemantic t of
    Nothing -> pure (textRanked, 0)
    Just (Semantic ids only) -> do
      let textIds = map hitId textRanked
          order = if only then ids else fuse [textIds, ids]
          absent = [i | i <- order, i `notElem` textIds]
      firsts <- if null absent then pure Map.empty else Map.fromList . map (\s -> (Cache.sumId s, Cache.sumFirstLine s)) <$> ExceptT (Cache.summaries c)
      let known = Map.fromList [(hitId h, h) | h <- textRanked]
          make i = case Map.lookup i known of
            Just h -> Just h
            Nothing -> Hit i <$> Map.lookup i firsts
          found = mapMaybe make order
      pure (found, length [h | h <- found, hitId h `Map.notMember` known])
  let ranked = headsFirst g joined
      shown = take (searchLimit o) ranked
      added = length [h | h <- shown, hitId h `notElem` map hitId hits]
  pure (searchResult o g shown) {corrections = notes <> [AddedByMeaning added | byMeaning > 0, added > 0]}

-- Neighbours -----------------------------------------------------------

-- | One edge of a memory, as seen from that memory.
data Neighbour = Neighbour
  { -- | 'Graph.Out' if the memory points at the other one, 'Graph.In' if
    -- the other one points at the memory.
    neighbourDir :: Dir,
    -- | The kind of the edge.
    neighbourKind :: EdgeType,
    -- | The memory at the other end. It can be a dangling target.
    neighbourId :: Id
  }
  deriving (Eq, Ord, Show)

-- | Every edge of a memory, in both directions. This function is pure.
--
-- The list is sorted: the 'Graph.Out' edges first, then by kind, then by
-- 'Id'. An 'Id' that is not in the graph has no edges, unless some memory
-- points at it.
neighbourList :: Id -> Graph -> [Neighbour]
neighbourList i g =
  [Neighbour d k x | (d, k, x) <- Set.toAscList (Graph.neighbours i g)]

-- | 'neighbourList' over the graph of the cache.
neighbours :: Cache -> Id -> IO (Either CacheError [Neighbour])
neighbours c i = fmap (neighbourList i) <$> Cache.loadGraph c

-- | One @about-ref@ link of a memory, as seen from that memory. The links
-- are not edges of the graph: a link names a ref, and it reaches the memory
-- that the ref names now.
data RefLink = RefLink
  { -- | 'Graph.Out' if the memory has the link, 'Graph.In' if the other
    -- memory has a link to a ref that names this memory now.
    linkDir :: Dir,
    -- | The ref of the link.
    linkRef :: Name,
    -- | For 'Graph.Out', the memory that the ref names now, or 'Nothing' if
    -- the ref does not exist. For 'Graph.In', the memory with the link.
    linkId :: Maybe Id
  }
  deriving (Eq, Ord, Show)

-- | Every about-ref link of a memory, in both directions, from the links of
-- all memories and the current values of the refs. This function is pure.
--
-- The list is sorted: the 'Graph.Out' links first, then by ref and 'Id'. A
-- link in reaches only the current value of a ref, not an older one.
refLinkList :: Id -> Map Id (Set Name) -> Map Name Id -> [RefLink]
refLinkList i links values =
  Set.toAscList . Set.fromList $
    [RefLink Out n (Map.lookup n values) | n <- Set.toAscList (Map.findWithDefault Set.empty i links)]
      <> [ RefLink In n (Just m)
         | (n, v) <- Map.toAscList values,
           v == i,
           (m, ns) <- Map.toAscList links,
           n `Set.member` ns
         ]

-- Resolve --------------------------------------------------------------

-- | The memories that now stand for an 'Id'. This function is pure.
--
-- It follows the @Supersedes@ edges backwards, from an older memory to the
-- memories that replace it, until it reaches memories that nothing replaces.
-- It returns those ends. An 'Id' that nothing replaces gives itself if it is a
-- memory in the graph.
--
-- The 'Id' does not have to be in the graph. The edge of the newer memory
-- stays in the graph after GC deleted the older one, so a deleted memory
-- still resolves while a newer memory exists. A fork gives more than one
-- memory: this function does not choose. A memory that is neither in the
-- graph nor replaced gives the empty set.
--
-- The chain breaks if a middle memory is deleted too, because its own edge
-- goes with it. The ends that are reached are still current memories.
resolve :: Id -> Graph -> Set Id
resolve i g = go (Set.singleton i) [i] Set.empty
  where
    go _ [] ends = ends
    go seen (n : ns) ends =
      case Set.toList (Graph.predecessors Supersedes n g) of
        []
          | n `Set.member` Graph.nodes g -> go seen ns (Set.insert n ends)
          | otherwise -> go seen ns ends
        ps ->
          let new = filter (`Set.notMember` seen) ps
           in go (foldr Set.insert seen new) (new <> ns) ends
