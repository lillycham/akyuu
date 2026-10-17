-- | The relation graph of the memory store.
--
-- This module is pure. It does not read the store or the cache. A 'Graph' is
-- a 'Monoid': build one 'Graph' for each memory with 'singleton' and join
-- them with '<>'. A full rebuild and an incremental update use the same code.
--
-- Edges point from a newer memory to an older one. The module does not
-- export the 'Graph' constructor, so the reverse index is always the exact
-- transpose of the forward index.
module Akyuu.Graph
  ( -- * Types
    EdgeType (..),
    Edge (..),
    Graph,

    -- * Construction
    singleton,

    -- * Queries
    Dir (..),
    nodes,
    successors,
    predecessors,
    neighbours,

    -- * Traversal
    reachable,
    withinHops,

    -- * Supersession and integrity
    superseded,
    heads,
    dangling,
  )
where

import Akyuu.Id (Id)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set

-- | The meaning of an edge.
data EdgeType
  = -- | The new memory replaces the old memory.
    Supersedes
  | -- | The new memory is about the old memory.
    About
  | -- | The new memory comes from the old memory.
    DerivedFrom
  | -- | The new memory adds detail to the old memory.
    Refines
  | -- | The new memory is the next episode of a log, after the old memory.
    Follows
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | An edge from a memory to an older memory. The source of the edge is the
-- memory that holds it, so the edge stores only the kind and the target.
data Edge = Edge
  { -- | The meaning of the edge.
    kind :: EdgeType,
    -- | The older memory that the edge points at.
    target :: Id
  }
  deriving (Eq, Ord, Show)

-- | The relation graph.
--
-- Invariants:
--
-- * Every memory in the store is a key of the forward map, also when it has
--   no edges.
-- * The reverse map is the exact transpose of the forward map.
-- * An edge can point at an 'Id' that is not a node. See 'dangling'.
data Graph = Graph
  { -- | Node to the nodes that it points at.
    fwd :: !(Map Id (Set (EdgeType, Id))),
    -- | Node to the nodes that point at it.
    rev :: !(Map Id (Set (EdgeType, Id)))
  }
  deriving (Eq, Show)

-- | Join two graphs.
--
-- At a key that is in both maps, the result holds the union of both sets.
-- Do not use the 'Semigroup' instance of 'Map' here. It keeps the left
-- value and drops the right value.
instance Semigroup Graph where
  Graph f1 r1 <> Graph f2 r2 = Graph (merge f1 f2) (merge r1 r2)
    where
      merge = Map.unionWith Set.union

instance Monoid Graph where
  mempty = Graph Map.empty Map.empty

-- | The graph of one memory.
--
-- The memory is a node, also if the list of edges is empty. Each edge adds
-- one forward entry and one reverse entry. The target of an edge does not
-- become a node.
singleton :: Id -> [Edge] -> Graph
singleton i es =
  Graph
    { fwd = Map.singleton i $ Set.fromList [(kind e, target e) | e <- es],
      rev = Map.fromListWith Set.union [(target e, Set.singleton (kind e, i)) | e <- es]
    }

-- | All memories in the graph. This does not include dangling targets.
nodes :: Graph -> Set Id
nodes g = Map.keysSet $ fwd g

-- | The nodes that this node points at with an edge of the given kind.
-- The result is empty if the node is not in the graph.
successors :: EdgeType -> Id -> Graph -> Set Id
successors k i g =
  Set.map snd
    . Set.filter ((== k) . fst)
    $ Map.findWithDefault Set.empty i (fwd g)

-- | The nodes that point at this node with an edge of the given kind.
-- The result is empty if nothing points at the node.
predecessors :: EdgeType -> Id -> Graph -> Set Id
predecessors k i g =
  Set.map snd
    . Set.filter ((== k) . fst)
    $ Map.findWithDefault Set.empty i (rev g)

-- | The direction of an edge, as seen from one node.
data Dir
  = -- | This node points at the other node.
    Out
  | -- | The other node points at this node.
    In
  deriving (Eq, Ord, Show)

-- | Tag a Set (EdgeType, Id) with a direction.
tag :: Dir -> Set (EdgeType, Id) -> Set (Dir, EdgeType, Id)
tag d = Set.map (\(k, x) -> (d, k, x))

-- | All edges of a node, in both directions, with the kind of each edge,
-- the direction, and the other node.
-- Use this function to show the context of one memory.
neighbours :: Id -> Graph -> Set (Dir, EdgeType, Id)
neighbours i g = (tag Out $ look $ fwd g) <> (tag In $ look $ rev g)
  where
    look = Map.findWithDefault Set.empty i

-- | The nodes that you can reach from the roots, along forward edges only.
--
-- The predicate selects the kinds of edge to follow. The result includes the
-- roots. The function terminates also when the graph has a cycle. GC uses it
-- with a predicate that rejects 'Supersedes'.
-- This function can include dangling targets in its result.
reachable :: (EdgeType -> Bool) -> Set Id -> Graph -> Set Id
reachable = walk Forward Nothing

-- | The nodes within a number of steps of the roots, along edges in both
-- directions.
--
-- The predicate selects the kinds of edge to follow. @withinHops 0@ returns
-- the roots. Search uses it to widen a text match to its neighbourhood.
withinHops :: Int -> (EdgeType -> Bool) -> Set Id -> Graph -> Set Id
withinHops n = walk Both (Just n)

-- | The direction in which 'walk' follows edges.
data WalkMode
  = -- | From a node to the nodes that it points at.
    Forward
  | -- | In both directions.
    Both

-- | The shared traversal behind 'reachable' and 'withinHops'.
--
-- Keep a set of visited nodes, so that a cycle cannot make the function loop.
-- A limit of 'Nothing' means that the walk has no limit on the number of
-- steps. Treats a limit of zero or less the same as zero.
walk :: WalkMode -> Maybe Int -> (EdgeType -> Bool) -> Set Id -> Graph -> Set Id
walk dir limit p roots g = go limit roots roots
  where
    -- visited, frontier
    go (Just n) visited _
      | n <= 0 = visited
    go lim visited frontier
      | Set.null frontier = visited
      | otherwise = go (subtract 1 <$> lim) (visited <> new) new
      where
        new = foldMap step frontier `Set.difference` visited

    -- the nodes one edge away from n, in the chosen direction
    step n = case dir of
      Forward -> out n
      Both -> out n <> inn n

    out = follow (fwd g)
    inn = follow (rev g)

    -- look up a node's edges, keep the selected kinds, drop the kind
    follow m n =
      Set.map snd . Set.filter (p . fst) $
        Map.findWithDefault Set.empty n m

-- | The nodes that a 'Supersedes' edge points at. These memories have a
-- newer version.
superseded :: Graph -> Set Id
superseded g =
  Map.keysSet
    (Map.filter hasSupersedes (rev g))
    `Set.intersection` nodes g
  where
    hasSupersedes = any ((== Supersedes) . fst)

-- | The nodes that no 'Supersedes' edge points at. These are the current
-- versions of memories.
--
-- If two memories supersede the same old memory, both are heads. The graph
-- does not choose between them.
heads :: Graph -> Set Id
heads g = nodes g `Set.difference` superseded g

-- | The targets of edges that are not nodes of the graph. A target is
-- dangling when GC removed the memory, or when the store is corrupt.
-- The @verify@ command reports these targets.
dangling :: Graph -> Set Id
dangling g = (Map.keysSet $ rev g) `Set.difference` (Map.keysSet $ fwd g)
