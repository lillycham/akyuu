-- | The read model of the web UI: plain data about a store, and its JSON.
--
-- This module is pure. "Akyuu.Web.Read" reads a store and fills these
-- types. "Akyuu.Web.Api" sends them as JSON. The page of the UI and the
-- static export (@akyuu viz@) read the same JSON, so they show the same
-- thing.
--
-- The JSON is made by the functions in this module, not by 'ToJSON'
-- instances. The types of the library ('Id', 'Summary', 'Why' …) live in
-- other modules, and an instance here would be an orphan.
module Akyuu.Web.Model
  ( -- * Small values
    idJSON,
    idsJSON,
    edgeKindJSON,
    timeJSON,

    -- * The graph
    NodeStatus (..),
    GraphData (..),
    GraphNode (..),
    GraphEdge (..),
    GraphView (..),
    Window (..),
    defaultWindow,
    selectWindow,
    graphView,
    graphViewJSON,
    nodeJSON,

    -- * Refs
    RefEntry (..),
    refHolds,
    refsJSON,

    -- * Stats
    Stats (..),
    statsJSON,

    -- * Other views
    memoryJSON,
    searchJSON,
    planJSON,
    whyJSON,
    trashJSON,
    verifyJSON,
  )
where

import Akyuu.Cache (Correction (AddedByMeaning, MeaningUnavailable, PrefixOf, SpelledAs), Summary (sumAgent, sumCreated, sumFirstLine, sumKind))
import Akyuu.Error (AkyuuError (RefFailed), describe, describeParse)
import Akyuu.GC (Observed (now, storedAt), Policy (gracePeriod, keepGenerations, trashTTL), Reason (HeldByPin, HeldByRef, HeldByTemp, IsYoung, RetainedBy), Roots (rootPins, rootRefs, rootTemps), Tombstone (prunedAt), Why (whyIsNode, whyLive, whyPath, whyReasons))
import Akyuu.Graph (Dir (In, Out), EdgeType, Graph)
import Akyuu.Graph qualified as Graph
import Akyuu.Id (Id)
import Akyuu.Id qualified as Id
import Akyuu.Memory (Memory (memAgent, memBody, memCreated, memKind), edgeToHeader)
import Akyuu.Ops (VerifyReport (badRefs, checkedObjects, corruptObjects, missingTargets, prunedTargets, refsToMissing, unreadableObjects), verifyOk)
import Akyuu.Query (Match (matchId, matchSnippet, matchSupersededBy), Neighbour (neighbourDir, neighbourId, neighbourKind), SearchResult (context, corrections, matches))
import Akyuu.Refs (Name, Ref (current, history), RefError, nameText)
import Data.Aeson (KeyValue ((.=)), Value (String), object)
import Data.Aeson qualified as A
import Data.List (sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Ord (Down (Down))
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Time (NominalDiffTime, UTCTime, addUTCTime, diffUTCTime)

-- Small values -----------------------------------------------------------

-- | An 'Id' in its text form, @sha256-…@.
idJSON :: Id -> Value
idJSON = String . Id.render

-- | A list of 'Id' values.
idsJSON :: (Foldable f) => f Id -> Value
idsJSON = A.toJSON . map Id.render . foldr (:) []

-- | The name of a kind of edge, as in the file format.
edgeKindJSON :: EdgeType -> Value
edgeKindJSON = String . edgeToHeader

-- | A time in ISO 8601 form, in UTC.
timeJSON :: UTCTime -> Value
timeJSON = A.toJSON

seconds :: NominalDiffTime -> Value
seconds d = A.toJSON (realToFrac d :: Double)

-- The graph --------------------------------------------------------------

-- | What the graph knows about one 'Id'.
data NodeStatus
  = -- | A memory that no 'Supersedes' edge points at.
    HeadNode
  | -- | A memory that a newer memory supersedes.
    SupersededNode
  | -- | A target of an edge that GC deleted, at this time (its tombstone).
    PrunedTarget UTCTime
  | -- | A target of an edge that is not in the store and has no tombstone.
    -- This is damage, or an edge to an object that was never added.
    MissingTarget
  deriving (Eq, Show)

-- | The facts that 'graphView' needs. "Akyuu.Web.Read" fills them.
data GraphData = GraphData
  { -- | The graph of the cache, with the objects of the store that the
    -- cache does not have yet (see 'Akyuu.GC.snapshot').
    gdGraph :: Graph,
    -- | A summary of each memory that the graph has.
    gdSummaries :: Map Id Summary,
    -- | The objects in the store now.
    gdStore :: Set Id,
    -- | The memories in the cache now.
    gdCached :: Set Id,
    -- | The tombstone time of each dangling target that has one.
    gdTombstones :: Map Id UTCTime
  }

-- | One node of the graph view: a memory, or a dangling target.
data GraphNode = GraphNode
  { gnId :: Id,
    -- | 'Nothing' for a dangling target, or for a memory with no summary.
    gnSummary :: Maybe Summary,
    gnStatus :: NodeStatus,
    -- | 'False' if only the cache has it: the store lost the object and the
    -- cache did not catch up yet.
    gnInStore :: Bool,
    gnInCache :: Bool
  }
  deriving (Eq, Show)

-- | One edge, from the newer memory to the older one.
data GraphEdge = GraphEdge
  { geSrc :: Id,
    geKind :: EdgeType,
    geDst :: Id
  }
  deriving (Eq, Ord, Show)

-- | The part of the graph that the page draws.
data GraphView = GraphView
  { gvNodes :: [GraphNode],
    gvEdges :: [GraphEdge],
    -- | 'True' if the view leaves out some nodes or edges.
    gvTruncated :: Bool,
    -- | The nodes of the whole graph, with the dangling targets.
    gvTotalNodes :: Int,
    gvTotalEdges :: Int,
    -- | Where the window started: the focus, or the newest heads.
    gvSeeds :: [Id],
    gvWindow :: Window
  }
  deriving (Eq, Show)

-- | Which part of the graph to show.
--
-- A big store has too many nodes to draw at once. By default the view starts
-- at the newest heads ('winLimit' of them) and adds every node within
-- 'winHops' edges, in both directions. With a focus, it starts at that one
-- node. 'winAll' shows the whole graph.
data Window = Window
  { winFocus :: Maybe Id,
    winHops :: Int,
    winLimit :: Int,
    winAll :: Bool
  }
  deriving (Eq, Show)

-- | No focus, 2 hops, the 200 newest heads, not all.
defaultWindow :: Window
defaultWindow = Window {winFocus = Nothing, winHops = 2, winLimit = 200, winAll = False}

-- | The 'Id' values to show, and the seeds of the window. This function is
-- pure.
--
-- The heads are sorted newest first by their @created@ time (the function
-- gives it), then by 'Id', so the choice is always the same. The result can
-- hold dangling targets: they are one edge away from a memory.
selectWindow :: Window -> (Id -> Maybe UTCTime) -> Graph -> (Set Id, [Id])
selectWindow w created g
  | winAll w = (everything, [])
  | otherwise = (Graph.withinHops (winHops w) (const True) (Set.fromList seeds) g, seeds)
  where
    everything = Graph.nodes g <> Graph.dangling g
    seeds = case winFocus w of
      Just i -> [i]
      Nothing ->
        take (max 0 (winLimit w)) $
          sortOn (\i -> (Down (created i), i)) (Set.toList (Graph.heads g))

-- | The view of the graph for a window. This function is pure.
--
-- The nodes are sorted by 'Id'. The edges are every edge between two shown
-- nodes, sorted. 'gvTruncated' is 'True' if a node or an edge of the whole
-- graph is not in the view.
graphView :: Window -> GraphData -> GraphView
graphView w d =
  GraphView
    { gvNodes = map node (Set.toAscList shown),
      gvEdges = shownEdges,
      gvTruncated = Set.size shown < Set.size everything || length shownEdges < totalEdges,
      gvTotalNodes = Set.size everything,
      gvTotalEdges = totalEdges,
      gvSeeds = seeds,
      gvWindow = w
    }
  where
    g = gdGraph d
    ns = Graph.nodes g
    everything = ns <> Graph.dangling g
    old = Graph.superseded g
    (shown, seeds) = selectWindow w (fmap sumCreated . (`Map.lookup` gdSummaries d)) g
    outOf i = [GraphEdge i k t | (Out, k, t) <- Set.toAscList (Graph.neighbours i g)]
    totalEdges = sum (map (length . outOf) (Set.toList ns))
    shownEdges =
      [ e
      | i <- Set.toAscList (shown `Set.intersection` ns),
        e <- outOf i,
        geDst e `Set.member` shown
      ]
    node i =
      GraphNode
        { gnId = i,
          gnSummary = Map.lookup i (gdSummaries d),
          gnStatus = status i,
          gnInStore = i `Set.member` gdStore d,
          gnInCache = i `Set.member` gdCached d
        }
    status i
      | i `Set.member` ns = if i `Set.member` old then SupersededNode else HeadNode
      | otherwise = maybe MissingTarget PrunedTarget (Map.lookup i (gdTombstones d))

-- | The JSON of a graph view.
graphViewJSON :: GraphView -> Value
graphViewJSON v =
  object
    [ "nodes" .= map nodeJSON (gvNodes v),
      "edges" .= map edgeJSON (gvEdges v),
      "truncated" .= gvTruncated v,
      "total" .= object ["nodes" .= gvTotalNodes v, "edges" .= gvTotalEdges v],
      "shown" .= object ["nodes" .= length (gvNodes v), "edges" .= length (gvEdges v)],
      "seeds" .= idsJSON (gvSeeds v),
      "window"
        .= object
          [ "focus" .= fmap idJSON (winFocus (gvWindow v)),
            "hops" .= winHops (gvWindow v),
            "limit" .= winLimit (gvWindow v),
            "all" .= winAll (gvWindow v)
          ]
    ]
  where
    edgeJSON e = object ["src" .= idJSON (geSrc e), "kind" .= edgeKindJSON (geKind e), "dst" .= idJSON (geDst e)]

-- | The JSON of one node. A dangling target has @null@ for the fields of a
-- memory.
nodeJSON :: GraphNode -> Value
nodeJSON n =
  object $
    [ "id" .= idJSON (gnId n),
      "kind" .= fmap sumKind s,
      "agent" .= fmap sumAgent s,
      "created" .= fmap (timeJSON . sumCreated) s,
      "line" .= fmap sumFirstLine s,
      "status" .= statusText (gnStatus n),
      "inStore" .= gnInStore n,
      "inCache" .= gnInCache n
    ]
      <> case gnStatus n of
        PrunedTarget t -> ["prunedAt" .= timeJSON t]
        _ -> []
  where
    s = gnSummary n
    statusText :: NodeStatus -> Text
    statusText st = case st of
      HeadNode -> "head"
      SupersededNode -> "superseded"
      PrunedTarget _ -> "pruned"
      MissingTarget -> "missing"

-- Refs -------------------------------------------------------------------

-- | A ref as the UI shows it: its value, or the error that its file gives.
data RefEntry = RefEntry
  { reName :: Name,
    reValue :: Either RefError Ref
  }
  deriving (Eq, Show)

-- | The refs that hold an 'Id', with the generation: 0 is the current value,
-- 1 the value before it, and so on. This function is pure. It skips a ref
-- that cannot be read.
refHolds :: [RefEntry] -> Id -> [(Name, Int)]
refHolds es i =
  [ (reName e, gen)
  | e <- es,
    Right r <- [reValue e],
    (gen, x) <- zip [0 ..] (current r : history r),
    x == i
  ]

-- | The JSON of the refs. @kept@ is the number of older generations that GC
-- keeps, so the page can mark them.
refsJSON :: Int -> [RefEntry] -> Value
refsJSON kept es = object ["kept" .= kept, "refs" .= map one es]
  where
    one e = case reValue e of
      Right r ->
        object
          [ "name" .= nameText (reName e),
            "current" .= idJSON (current r),
            "history" .= idsJSON (history r)
          ]
      Left err -> object ["name" .= nameText (reName e), "error" .= describe (RefFailed err)]

-- Stats ------------------------------------------------------------------

-- | Cheap facts about a store, for the page to poll. If any of them changes,
-- the page loads the other views again.
data Stats = Stats
  { statMemories :: Int,
    statCached :: Int,
    statRefs :: Int,
    statPins :: Int,
    statTrash :: Int,
    statTombstones :: Int,
    -- | The newest modification time of the directories of the store and of
    -- the ref files. A new object, a move to trash or a new ref value
    -- changes it.
    statNewest :: Maybe UTCTime
  }
  deriving (Eq, Show)

-- | The JSON of the stats, with a @fingerprint@: one text that changes when
-- any field changes.
statsJSON :: Stats -> Value
statsJSON s =
  object
    [ "memories" .= statMemories s,
      "cached" .= statCached s,
      "refs" .= statRefs s,
      "pins" .= statPins s,
      "trash" .= statTrash s,
      "tombstones" .= statTombstones s,
      "newest" .= fmap timeJSON (statNewest s),
      "fingerprint" .= fingerprint
    ]
  where
    fingerprint =
      show
        ( [statMemories s, statCached s, statRefs s, statPins s, statTrash s, statTombstones s],
          statNewest s
        )

-- Other views ------------------------------------------------------------

-- | The JSON of one memory: its headers, its body, its edges in both
-- directions, the refs that hold it, and its status in the graph.
memoryJSON :: Id -> Memory -> [Neighbour] -> [(Name, Int)] -> NodeStatus -> Maybe UTCTime -> Value
memoryJSON i m ns holds st stored =
  object
    [ "id" .= idJSON i,
      "kind" .= memKind m,
      "agent" .= memAgent m,
      "created" .= timeJSON (memCreated m),
      "body" .= memBody m,
      "status" .= nodeStatus,
      "storedAt" .= fmap timeJSON stored,
      "edges"
        .= [ object
               [ "dir" .= (case neighbourDir n of Out -> "out" :: Text; In -> "in"),
                 "kind" .= edgeKindJSON (neighbourKind n),
                 "id" .= idJSON (neighbourId n)
               ]
           | n <- ns
           ],
      "refs" .= [object ["name" .= nameText n, "generation" .= gen] | (n, gen) <- holds]
    ]
  where
    nodeStatus :: Text
    nodeStatus = case st of
      SupersededNode -> "superseded"
      _ -> "head"

-- | The JSON of a search result.
searchJSON :: Text -> SearchResult -> Value
searchJSON q r =
  object
    [ "query" .= q,
      "matches"
        .= [ object
               [ "id" .= idJSON (matchId m),
                 "snippet" .= matchSnippet m,
                 "supersededBy" .= idsJSON (matchSupersededBy m)
               ]
           | m <- matches r
           ],
      "context" .= idsJSON (context r),
      "corrections"
        .= [ case c of
               PrefixOf w -> object ["word" .= w, "kind" .= ("prefix" :: Text), "used" .= ([w <> "*"] :: [Text])]
               SpelledAs w ts -> object ["word" .= w, "kind" .= ("spelling" :: Text), "used" .= ts]
               AddedByMeaning n -> object ["kind" .= ("meaning" :: Text), "count" .= n]
               MeaningUnavailable why -> object ["kind" .= ("unavailable" :: Text), "why" .= why]
           | c <- corrections r
           ]
    ]

policyJSON :: Policy -> Value
policyJSON p =
  object
    [ "keepGenerations" .= keepGenerations p,
      "gracePeriod" .= seconds (gracePeriod p),
      "trashTTL" .= seconds (trashTTL p)
    ]

-- | The JSON of a GC plan: what a run now would move to trash, and the
-- roots and young nodes that keep the rest.
planJSON :: Policy -> Observed -> Roots -> Set Id -> Set Id -> Set Id -> Value
planJSON p o r ns young planned =
  object
    [ "now" .= timeJSON (now o),
      "policy" .= policyJSON p,
      "nodes" .= Set.size ns,
      "planned" .= idsJSON planned,
      "young" .= idsJSON young,
      "roots"
        .= object
          [ "refs" .= idsJSON (rootRefs r),
            "pins" .= idsJSON (rootPins r),
            "temps" .= idsJSON (rootTemps r)
          ]
    ]

-- | The JSON of 'Akyuu.GC.explain', with the details that it does not have:
-- which ref generations hold the 'Id', and when the object came into the
-- store.
whyJSON :: Policy -> Observed -> Id -> Why -> [(Name, Int)] -> Value
whyJSON p o i w holds =
  object
    [ "id" .= idJSON i,
      "isNode" .= whyIsNode w,
      "live" .= whyLive w,
      "planned" .= (whyIsNode w && not (whyLive w)),
      "storedAt" .= fmap timeJSON stored,
      "reasons" .= map reason (whyReasons w),
      "path" .= [object ["id" .= idJSON s, "kind" .= edgeKindJSON k] | (s, k) <- whyPath w]
    ]
  where
    stored = Map.lookup i (storedAt o)
    reason :: Reason -> Value
    reason r = case r of
      HeldByRef ->
        object
          [ "reason" .= ("ref" :: Text),
            "refs" .= [object ["name" .= nameText n, "generation" .= gen] | (n, gen) <- holds, gen <= keepGenerations p]
          ]
      HeldByPin -> object ["reason" .= ("pin" :: Text)]
      HeldByTemp -> object ["reason" .= ("temp" :: Text)]
      IsYoung ->
        object
          [ "reason" .= ("young" :: Text),
            "ageSeconds" .= fmap (\t -> seconds (diffUTCTime (now o) t)) stored,
            "gracePeriod" .= seconds (gracePeriod p)
          ]
      RetainedBy k s -> object ["reason" .= ("edge" :: Text), "kind" .= edgeKindJSON k, "from" .= idJSON s]

-- | The JSON of the trash, the tombstones and the pins. Each file in trash
-- has the time when phase 2 of a sweep may delete it.
trashJSON :: Policy -> [(Id, UTCTime)] -> [(Id, Tombstone)] -> [(Id, Bool)] -> Value
trashJSON p trash tombs pins =
  object
    [ "trash" .= [object ["id" .= idJSON i, "movedAt" .= timeJSON t, "deleteAfter" .= timeJSON (addUTCTime (trashTTL p) t)] | (i, t) <- trash],
      "tombstones" .= [object ["id" .= idJSON i, "prunedAt" .= timeJSON (prunedAt t)] | (i, t) <- tombs],
      "pins" .= [object ["id" .= idJSON i, "inStore" .= there] | (i, there) <- pins]
    ]

-- | The JSON of a verify report, with the drift between the cache and the
-- store: the 'Id' values that only the cache has, and those that only the
-- store has.
verifyJSON :: VerifyReport -> Set Id -> Set Id -> Value
verifyJSON r cached stored =
  object
    [ "ok" .= verifyOk r,
      "checked" .= checkedObjects r,
      "corrupt" .= idsJSON (corruptObjects r),
      "unreadable" .= [object ["id" .= idJSON i, "why" .= describeParse e] | (i, e) <- unreadableObjects r],
      "missing" .= idsJSON (missingTargets r),
      "pruned" .= idsJSON (prunedTargets r),
      "badRefs" .= [object ["name" .= nameText n, "why" .= describe (RefFailed e)] | (n, e) <- badRefs r],
      "refsToMissing" .= [object ["name" .= nameText n, "id" .= idJSON i] | (n, i) <- refsToMissing r],
      "drift"
        .= object
          [ "inSync" .= (cached == stored),
            "cacheOnly" .= idsJSON (cached `Set.difference` stored),
            "storeOnly" .= idsJSON (stored `Set.difference` cached)
          ],
      "counts" .= object ["cached" .= Set.size cached, "stored" .= Set.size stored]
    ]
