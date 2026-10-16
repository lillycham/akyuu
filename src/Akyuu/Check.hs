-- | Detection: find the memories that need attention, without a model.
--
-- 'check' is a pure function. It gets the graph, the bodies and the roots as
-- data, and returns a sorted list of 'Finding' values. It writes nothing, and
-- a result depends only on its input, so tests and other callers need no
-- store. 'Akyuu.Ops.checkStore' gathers the input from a store.
--
-- The checks look at every memory, so no finding depends on what a reader
-- noticed. They report. They do not fix: a fix is a normal @supersede@, @add@
-- or @pin@ of a person or an agent.
--
-- A check looks at the /heads/ of the graph (the memories that no @Supersedes@
-- edge points at). An old version is meant to look like the new one, and GC
-- already reports it as garbage.
module Akyuu.Check
  ( -- * Findings
    Severity (..),
    FindingKind (..),
    Finding (..),
    kindName,
    severityName,
    filterFindings,

    -- * Options
    CheckOptions (..),
    defaultCheckOptions,

    -- * Check
    Inputs (..),
    check,
    normalise,
    shingles,
    jaccard,
  )
where

import Akyuu.GC (Roots (rootRefs), allRoots, retains)
import Akyuu.Graph (Dir (In, Out), EdgeType (About, DerivedFrom, Refines, Supersedes), Graph)
import Akyuu.Graph qualified as Graph
import Akyuu.Id (Id, render)
import Akyuu.Query (resolve)
import Akyuu.Refs (Name, nameText)
import Data.List (sortOn, tails)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Text.Printf (printf)

-- Findings -------------------------------------------------------------

-- | How much a finding matters. 'Problem' comes first in a list.
data Severity
  = -- | Something is wrong, and an agent can act on it.
    Problem
  | -- | Something probably needs a decision.
    Suggestion
  | -- | A fact that can help a design. No action is needed.
    Info
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | What a finding is about.
data FindingKind
  = -- | A live memory points at an old version with an @about@ or @refines@
    -- edge. 'findingRelated' holds the current memories. A @derived-from@
    -- edge is evidence of one exact text, so an old target is right there.
    StaleLink
  | -- | Two or more heads supersede the same memory.
    Fork
  | -- | Two or more heads have the same text, apart from white space and case.
    DuplicateBody
  | -- | Two heads share most of their text.
    NearDuplicate
  | -- | A head that no ref, no pin and no memory keeps.
    Unreferenced
  | -- | A memory that many memories point at.
    Hub
  | -- | A log (a chain of episodes under a ref) with many episodes. It
    -- is time to replace it with a summary.
    LongLog
  | -- | A live memory has an @about-ref@ link to a ref that does not exist.
    MissingRef
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | One thing that 'check' found. This is plain data.
data Finding = Finding
  { findingKind :: FindingKind,
    findingSeverity :: Severity,
    -- | The memories that the finding is about. For 'StaleLink' the first one
    -- is the memory that holds the link, and the second one is the old target.
    -- For the other kinds the list is sorted.
    findingIds :: [Id],
    -- | The memories to read instead, if there are any. For 'StaleLink' and
    -- 'Fork' these are the current memories. The list is sorted.
    findingRelated :: [Id],
    -- | One sentence for a person.
    findingWhy :: Text
  }
  deriving (Eq, Show)

-- Options --------------------------------------------------------------

data CheckOptions = CheckOptions
  { -- | The least share of word triples (0 to 1) that two memories must have
    -- in common to be a 'NearDuplicate'.
    nearThreshold :: Double,
    -- | The most incoming links that a memory can have before it is a 'Hub'.
    hubDegree :: Int,
    -- | A memory with fewer words than this is not compared for near
    -- duplicates. Short texts match by chance.
    minWords :: Int,
    -- | A log with more episodes than this is a 'LongLog'.
    longLog :: Int
  }
  deriving (Eq, Show)

-- | A threshold of 0.8, a hub at more than 5 links, and 5 words at least.
defaultCheckOptions :: CheckOptions
defaultCheckOptions = CheckOptions {nearThreshold = 0.8, hubDegree = 5, minWords = 5, longLog = 30}

-- Check ----------------------------------------------------------------

-- | What 'check' reads.
data Inputs = Inputs
  { inGraph :: Graph,
    -- | The body of each memory. A memory with no entry here is not compared
    -- for duplicates.
    inBodies :: Map Id Text,
    inRoots :: Roots,
    -- | The pairs that a person or an agent judged to be different. A
    -- finding about only these memories is left out. See 'Akyuu.Review'.
    inReviewed :: Set (Id, Id),
    -- | The @about-ref@ links of each memory. A memory with no entry has none.
    inAboutRefs :: Map Id (Set Name),
    -- | The current value of each ref.
    inRefValues :: Map Name Id
  }

-- | Every finding, sorted by severity, then kind, then ids. This function is
-- pure, and the same input gives the same list.
check :: CheckOptions -> Inputs -> [Finding]
check o i =
  sortOn
    (\f -> (findingSeverity f, findingKind f, findingIds f, findingRelated f))
    ( staleLinks g kept heldBy
        <> missingRefs kept (inAboutRefs i) (inRefValues i)
        <> filter (not . judged) (forks g)
        <> filter (not . judged) (duplicates g hs bodies)
        <> filter (not . judged) (nearDuplicates o g hs bodies)
        <> unreferenced g hs (inRoots i)
        <> hubs o g kept
        <> longLogs o g (rootRefs (inRoots i))
    )
  where
    g = inGraph i
    hs = Graph.heads g
    bodies = inBodies i
    heldBy = Map.fromListWith (<>) [(v, [n]) | (n, v) <- Map.toAscList (inRefValues i)]
    -- A finding is left out when every pair of the memories in it is judged.
    judged f =
      let is = if findingKind f == Fork then findingRelated f else findingIds f
          ps = [(min a b, max a b) | (a : rest) <- tails is, b <- rest]
       in findingKind f `elem` [Fork, DuplicateBody, NearDuplicate] && not (null ps) && all (`Set.member` inReviewed i) ps
    -- The heads that something keeps. A head that nothing keeps is garbage
    -- (it has its own finding), so its links do not count.
    kept = Set.filter (\h -> h `Set.member` allRoots (inRoots i) || any (retains . fst) (ins h g)) hs

-- Detectors ------------------------------------------------------------

-- | An @about@ or @refines@ edge from a head to a memory that something
-- replaced. If a ref holds a current memory, the text names it: an
-- @about-ref@ link to that ref follows it and does not go stale.
staleLinks :: Graph -> Set Id -> Map Id [Name] -> [Finding]
staleLinks g hs heldBy =
  [ Finding
      { findingKind = StaleLink,
        findingSeverity = Problem,
        findingIds = [m, t],
        findingRelated = Set.toAscList now,
        findingWhy =
          render m
            <> " has a link to "
            <> render t
            <> ", which a newer memory replaces."
            <> useRef now
      }
  | m <- Set.toAscList hs,
    (k, t) <- outs m g,
    k `elem` [About, Refines],
    let now = resolve t g `Set.difference` Set.singleton t,
    not (Set.null now)
  ]
  where
    useRef now = case concat [Map.findWithDefault [] h heldBy | h <- Set.toAscList now] of
      [] -> ""
      ns -> " To follow the topic, link to the ref with about-ref " <> T.intercalate " or " (map nameText ns) <> " instead."

-- | An @about-ref@ link from a head to a ref that does not exist. A link
-- resolves to nothing then: the ref was deleted or renamed.
missingRefs :: Set Id -> Map Id (Set Name) -> Map Name Id -> [Finding]
missingRefs hs links values =
  [ Finding
      { findingKind = MissingRef,
        findingSeverity = Problem,
        findingIds = [m],
        findingRelated = [],
        findingWhy = render m <> " has an about-ref link to " <> nameText n <> ", which is not a ref. Supersede it with a link to the right ref."
      }
  | (m, ns) <- Map.toAscList links,
    m `Set.member` hs,
    n <- Set.toAscList ns,
    n `Map.notMember` values
  ]

-- | Two or more heads that replace the same memory.
forks :: Graph -> [Finding]
forks g =
  [ Finding
      { findingKind = Fork,
        findingSeverity = Problem,
        findingIds = [x],
        findingRelated = Set.toAscList hs,
        findingWhy =
          T.pack (show (Set.size hs))
            <> " memories replace "
            <> render x
            <> " and none replaces another. Say which one is right."
      }
  | x <- Set.toAscList replaced,
    let hs = resolve x g,
    Set.size hs >= 2
  ]
  where
    replaced = Set.filter (not . Set.null . flip (Graph.predecessors Supersedes) g) (Graph.nodes g <> Graph.dangling g)

-- | Heads with the same normalised text, outside one line of versions.
duplicates :: Graph -> Set Id -> Map Id Text -> [Finding]
duplicates g hs bodies =
  [ Finding
      { findingKind = DuplicateBody,
        findingSeverity = Suggestion,
        findingIds = Set.toAscList grp,
        findingRelated = [],
        findingWhy = "These memories have the same text. Keep one and supersede the others."
      }
  | grp <- Map.elems groups,
    Set.size grp >= 2,
    not (sameLine g grp)
  ]
  where
    groups =
      Map.fromListWith
        (<>)
        [(normalise b, Set.singleton i) | i <- Set.toAscList hs, Just b <- [Map.lookup i bodies]]

-- | Pairs of heads that share most of their word triples, but are not equal.
nearDuplicates :: CheckOptions -> Graph -> Set Id -> Map Id Text -> [Finding]
nearDuplicates o g hs bodies =
  [ Finding
      { findingKind = NearDuplicate,
        findingSeverity = Suggestion,
        findingIds = [a, b],
        findingRelated = [],
        findingWhy =
          T.pack (printf "These memories share %d%% of their text. Is one a copy of the other?" (round (100 * s) :: Int))
      }
  | ((a, b), _) <- Map.toAscList candidates,
    Just sa <- [Map.lookup a sets],
    Just sb <- [Map.lookup b sets],
    let s = jaccard sa sb,
    s >= nearThreshold o,
    Map.lookup a norm /= Map.lookup b norm,
    not (sameLine g (Set.fromList [a, b]))
  ]
  where
    texts = Map.fromList [(i, b) | i <- Set.toAscList hs, Just b <- [Map.lookup i bodies]]
    norm = Map.map normalise texts
    long = Map.filter ((>= minWords o) . length . T.words) texts
    sets = Map.map (shingles . normalise) long
    -- An inverted index. A triple in more than a tenth of the memories says
    -- nothing, so it makes no pairs.
    index = Map.fromListWith (<>) [(s, [i]) | (i, ss) <- Map.toAscList sets, s <- Set.toList ss]
    cap = max 5 (Map.size sets `div` 10)
    candidates =
      Map.fromList
        [ ((a, b), ())
        | is <- Map.elems index,
          length is <= cap,
          (a : rest) <- tails is,
          b <- rest
        ]

-- | Heads that nothing keeps: no ref, no pin, and no retaining link.
unreferenced :: Graph -> Set Id -> Roots -> [Finding]
unreferenced g hs roots =
  [ Finding
      { findingKind = Unreferenced,
        findingSeverity = Suggestion,
        findingIds = [h],
        findingRelated = [],
        findingWhy = "No ref, pin or memory keeps this one. GC collects it after the grace period."
      }
  | h <- Set.toAscList hs,
    h `Set.notMember` allRoots roots,
    not (any (retains . fst) (ins h g))
  ]

-- | Memories with many incoming retaining links.
hubs :: CheckOptions -> Graph -> Set Id -> [Finding]
hubs o g hs =
  [ Finding
      { findingKind = Hub,
        findingSeverity = Info,
        findingIds = [t],
        findingRelated = [],
        findingWhy =
          T.pack (show n)
            <> " memories link to this one. A tier may fit better than links."
      }
  | t <- Set.toAscList (Graph.nodes g),
    let n = Set.size (Set.fromList [m | (k, m) <- ins t g, retains k, m `Set.member` hs]),
    n > hubDegree o
  ]

-- | A log that has grown long: a value of a ref that no episode follows,
-- with a chain of more than 'longLog' episodes behind it. The chain goes
-- through the one @derived_from@ edge of each episode, as 'Akyuu.Episode'
-- writes it, and stops at a memory with no such edge, or with more than one.
longLogs :: CheckOptions -> Graph -> Set Id -> [Finding]
longLogs o g refs =
  [ Finding
      { findingKind = LongLog,
        findingSeverity = Info,
        findingIds = [h],
        findingRelated = [],
        findingWhy =
          "This log has "
            <> T.pack (show n)
            <> " episodes. Replace it with a summary (supersede the ref) when you can, so that it stays short."
      }
  | h <- Set.toAscList refs,
    null [() | (k, _) <- ins h g, k == DerivedFrom],
    let n = chainLength h,
    n > longLog o
  ]
  where
    chainLength = go Set.empty (0 :: Int)
    go seen n x
      | x `Set.member` seen = n
      | otherwise = case [t | (DerivedFrom, t) <- outs x g] of
          [t] -> go (Set.insert x seen) (n + 1) t
          _ -> n + 1

-- Helpers --------------------------------------------------------------

-- | The edges that start at a memory, as (kind, target).
outs :: Id -> Graph -> [(EdgeType, Id)]
outs i g = [(k, t) | (Out, k, t) <- Set.toList (Graph.neighbours i g)]

-- | The edges that end at a memory, as (kind, source).
ins :: Id -> Graph -> [(EdgeType, Id)]
ins i g = [(k, s) | (In, k, s) <- Set.toList (Graph.neighbours i g)]

-- | Do two or more memories belong to one line of versions? They do if one
-- replaces another, or if they have an older memory in common.
sameLine :: Graph -> Set Id -> Bool
sameLine g is = any shared pairs
  where
    pairs = [(a, b) | (a : rest) <- tails (Set.toAscList is), b <- rest]
    shared (a, b) =
      let la = lineOf a
          lb = lineOf b
       in not (Set.null (la `Set.intersection` lb))
    -- The memory and everything that it replaces, along Supersedes edges.
    lineOf i = go Set.empty [i]
      where
        go seen [] = seen
        go seen (n : ns)
          | n `Set.member` seen = go seen ns
          | otherwise = go (Set.insert n seen) (Set.toList (Graph.successors Supersedes n g) <> ns)

-- | The text with its white space made one space, in lower case.
normalise :: Text -> Text
normalise = T.unwords . T.words . T.toLower

-- | The sets of three words in a row. A text of fewer than three words gives
-- one set item: the whole text.
shingles :: Text -> Set Text
shingles t = case T.words t of
  ws
    | length ws < 3 -> Set.singleton (T.unwords ws)
    | otherwise -> Set.fromList [T.unwords [a, b, c] | (a : b : c : _) <- tails ws]

-- | The size of the common part divided by the size of the union. Two empty
-- sets give 0.
jaccard :: (Ord a) => Set a -> Set a -> Double
jaccard a b
  | u == 0 = 0
  | otherwise = fromIntegral (Set.size (a `Set.intersection` b)) / fromIntegral u
  where
    u = Set.size (a `Set.union` b)

-- | The name of a kind, as the command line and the JSON write it:
-- @stale-link@, @fork@, @duplicate-body@, @near-duplicate@, @unreferenced@, @hub@,
-- @long-log@, @missing-ref@.
kindName :: FindingKind -> Text
kindName StaleLink = "stale-link"
kindName Fork = "fork"
kindName DuplicateBody = "duplicate-body"
kindName NearDuplicate = "near-duplicate"
kindName Unreferenced = "unreferenced"
kindName Hub = "hub"
kindName LongLog = "long-log"
kindName MissingRef = "missing-ref"

-- | The name of a severity: @problem@, @suggestion@ or @info@.
severityName :: Severity -> Text
severityName Problem = "problem"
severityName Suggestion = "suggestion"
severityName Info = "info"

-- | The findings of these kinds, and of this severity or a more serious one.
-- An empty list of kinds and 'Nothing' for the severity keep every finding.
filterFindings :: [FindingKind] -> Maybe Severity -> [Finding] -> [Finding]
filterFindings ks s = filter keep
  where
    keep f =
      (null ks || findingKind f `elem` ks)
        && maybe True (\lvl -> findingSeverity f <= lvl) s
