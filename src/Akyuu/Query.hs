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
    defaultSearchOptions,
    Match (..),
    SearchResult (..),
    searchResult,
    headsFirst,
    search,

    -- * Neighbours
    Neighbour (..),
    neighbourList,
    neighbours,
  )
where

import Akyuu.Cache (Cache, CacheError, Hit (..))
import Akyuu.Cache qualified as Cache
import Akyuu.Graph (Dir, EdgeType (Supersedes), Graph)
import Akyuu.Graph qualified as Graph
import Akyuu.Id (Id)
import Control.Monad.Trans.Except (ExceptT (ExceptT), runExceptT)
import Data.List (partition)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)

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
    context :: Set Id
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
      context = near `Set.difference` ids
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
search c o q = runExceptT $ do
  hits <- ExceptT (Cache.search c q (fetchCount (searchLimit o)))
  g <- ExceptT (Cache.loadGraph c)
  pure (searchResult o g (take (searchLimit o) (headsFirst g hits)))

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
