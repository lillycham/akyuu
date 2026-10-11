-- | Garbage collection: find the memories that nothing needs, and remove them.
--
-- GC has a pure part and an I/O part. The pure part, 'plan', gets the roots,
-- the graph and the ages of the objects as data, and returns the set of
-- 'Id' values to collect. A dry run is a call to 'plan' and nothing else, so
-- it is free and it cannot change the store.
--
-- The I/O part reads the inputs ('readRoots', 'snapshot') and does the work
-- ('sweep', 'sweepAndSync'). 'collect' is one whole run, under the lock of
-- GC. 'dryRun' is the same run up to the plan, and it writes nothing.
--
-- = Which way liveness flows
--
-- An edge goes from the memory that holds it (the newer one) to its target
-- (the older one). Liveness flows the same way, from source to target: if a
-- memory is live and it has an edge of kind @k@ to a target, the target is
-- live when @'retains' k@ is true. Liveness never flows backwards. A live
-- old memory does not keep alive a newer memory that is 'About' it.
--
-- 'Supersedes' does not retain. When a new memory replaces an old one, and a
-- ref moves to the new one, the old one is garbage, unless a ref generation,
-- a pin, or another retaining edge keeps it.
--
-- = Layout, under the root directory of the store
--
-- > trash/sha256-9f3a….md      an object that phase 1 of 'sweep' moved
-- > tombstones/sha256-9f3a…    one file for each object that phase 2 deleted
-- > pins/sha256-9f3a…          one empty file for each pin
-- > gc.lock                    the lock of a run (see 'withGCLock')
--
-- = What GC trusts
--
-- 'plan' returns only nodes of the graph. An object that is not in the graph
-- (for example an object that an agent added after the graph was read) is
-- never collected. The edges of a node come from an immutable object, so a
-- node's edges are always right. The graph must hold every object that is old
-- enough to collect, so 'snapshot' adds the objects that the cache does not
-- have yet.
--
-- = One run at a time
--
-- 'collect', 'sweep' and 'sweepAndSync' run under an exclusive lock on
-- @gc.lock@. A second run that cannot get the lock in about one second
-- returns 'GCLocked' and changes nothing. 'dryRun' does not take the lock,
-- because it writes nothing.
--
-- = The window that is not closed
--
-- GC and the agents do not share a lock, so an agent can change the store
-- during a run. 'collect' looks again just before the sweep ('recheck'), and
-- 'sweep' checks the file time of each object just before it moves it. This
-- makes the window small, but it does not close it. Let @O@ be an old object
-- in the plan. It goes to @trash@ although something now needs it, if one of
-- these happens:
--
-- * Between the 'Akyuu.Store.list' of 'recheck' and the move of @O@, an agent
--   writes a new memory with a retaining edge to @O@ (or to a memory that
--   retains @O@), or moves a ref to @O@, or pins @O@.
-- * Between the check of the file time of @O@ in 'sweep' and its move, an
--   agent adds @O@ again. 'Akyuu.Store.add' then returns, and the object
--   is in @trash@ just after.
--
-- In each case @O@ stays in @trash@ for 'trashTTL', so it can be put back by
-- hand. After that, a link to it says "pruned".
--
-- Functions return @IO (Either GCError a)@. A caller never has to catch an
-- exception from this module.
module Akyuu.GC
  ( -- * Liveness
    retains,

    -- * Policy
    Policy (..),
    defaultPolicy,
    Observed (..),
    young,

    -- * Roots
    Roots (..),
    allRoots,
    readRoots,
    readRefRoots,

    -- * Pins
    pinPath,
    pin,
    unpin,
    listPins,

    -- * The plan
    plan,

    -- * Why an object stays
    Reason (..),
    Why (..),
    explain,
    explainAll,

    -- * Inputs from disk
    storedTimes,
    extendGraph,
    snapshot,
    recheck,

    -- * Errors
    GCError (..),

    -- * Sweep
    SweepReport (..),
    sweep,
    sweepAndSync,

    -- * A whole run
    RunReport (..),
    collect,
    dryRun,
    withGCLock,
    gcLockPath,

    -- * Tombstones
    Tombstone (..),
    TombstoneParseError (..),
    renderTombstone,
    parseTombstone,
    tombstonePath,
    lookupTombstone,
    listTombstones,

    -- * Trash
    listTrash,
  )
where

import Akyuu.Cache (Cache, CacheError, SyncReport)
import Akyuu.Cache qualified as Cache
import Akyuu.Fs (atomicWrite, tryWith)
import Akyuu.Graph (EdgeType (About, DerivedFrom, Refines, Supersedes), Graph, nodes, predecessors, reachable, singleton, successors)
import Akyuu.Id (Id)
import Akyuu.Id qualified as Id
import Akyuu.Memory (Memory (memEdges))
import Akyuu.Refs (RefError (NoSuchRef), Refs, getRef, listRefs, retained)
import Akyuu.Store (Store, StoreError (NotFound), objectPath, storeRoot, trashPath)
import Akyuu.Store qualified as Store
import Control.Concurrent (threadDelay)
import Control.Exception (IOException, tryJust)
import Control.Monad (guard, unless)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Trans.Except (ExceptT (ExceptT), runExceptT, withExceptT)
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Foldable (toList)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (catMaybes, fromMaybe, mapMaybe)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time
  ( NominalDiffTime,
    UTCTime,
    defaultTimeLocale,
    diffUTCTime,
    formatTime,
    getCurrentTime,
    nominalDay,
    parseTimeM,
  )
import System.Directory
  ( createDirectoryIfMissing,
    doesFileExist,
    getModificationTime,
    listDirectory,
    removeFile,
    setModificationTime,
  )
import System.FileLock (SharedExclusive (Exclusive), withTryFileLock)
import System.FilePath ((</>))
import System.IO.Error (isDoesNotExistError)

-- Liveness -------------------------------------------------------------

-- | Does an edge of this kind keep its target alive?
--
-- If a live memory has an edge of this kind, and the result is 'True', then
-- the target of the edge is live too. See the module header for the
-- direction.
--
-- Only 'Supersedes' does not retain. The function names each kind, with no
-- catch-all case, so a new kind of edge gives a warning here and someone must
-- decide.
retains :: EdgeType -> Bool
retains Supersedes = False
retains About = True
retains DerivedFrom = True
retains Refines = True

-- Policy ---------------------------------------------------------------

-- | The settings of GC. They do not change from one run to the next, so a
-- caller can keep one value and use it for every run. The facts of one run
-- are in 'Observed'.
data Policy = Policy
  { -- | How many older generations of each ref to keep, as well as the
    -- current value. 'readRoots' passes it to 'Akyuu.Refs.retained'.
    -- 'plan' does not read it: the roots already hold the generations.
    keepGenerations :: Int,
    -- | An object that came into the store less than this long ago is not
    -- collected. It covers the time between @Store.add@ and @setRef@, in
    -- which a new object has no ref yet.
    gracePeriod :: NominalDiffTime,
    -- | 'sweep' deletes a file in @trash@ when it was moved there more than
    -- this long ago.
    trashTTL :: NominalDiffTime
  }
  deriving (Eq, Show)

-- | The default settings: keep 5 older generations of each ref, a grace
-- period of one hour, and a trash TTL of seven days.
defaultPolicy :: Policy
defaultPolicy =
  Policy
    { keepGenerations = 5,
      gracePeriod = 3600,
      trashTTL = 7 * nominalDay
    }

-- | The facts about time that one run needs.
--
-- 'plan' is pure, so it cannot read a clock or a file time. The caller reads
-- them once, at the start of the run, and puts them here. 'storedTimes'
-- gives 'storedAt'.
data Observed = Observed
  { -- | The time of this run.
    now :: UTCTime,
    -- | When each object came into the store: the modification time of its
    -- file (see 'storedTimes'). An object that is not in the map counts as
    -- young, so 'plan' does not collect it.
    storedAt :: Map Id UTCTime
  }
  deriving (Eq, Show)

-- | Is this object younger than the grace period? An object with no known
-- age is young. An object with a time in the future (a clock that moved
-- back) is young too.
young :: Policy -> Observed -> Id -> Bool
young p o i = maybe True fresh (Map.lookup i (storedAt o))
  where
    fresh t = diffUTCTime (now o) t < gracePeriod p

-- Roots ----------------------------------------------------------------

-- | The roots of the graph. Everything that a root reaches through
-- 'retains' edges is live.
data Roots = Roots
  { -- | The values of the refs that 'Akyuu.Refs.retained' keeps: the current
    -- value and the newest older generations of each ref.
    rootRefs :: Set Id,
    -- | The pins: objects that a person or agent asked GC to keep. They are
    -- on disk, in @pins/@ (see 'pin').
    rootPins :: Set Id,
    -- | Temporary roots of this run, for example the objects that an agent
    -- is about to point a ref at. They are not on disk. The caller sets
    -- them. The grace period protects new objects in most cases.
    rootTemps :: Set Id
  }
  deriving (Eq, Show)

-- | All the roots in one set.
allRoots :: Roots -> Set Id
allRoots r = rootRefs r <> rootPins r <> rootTemps r

-- | Run an action that can throw an 'IOException'. An exception becomes
-- 'GCIO'. Other exceptions, for example a timeout, are not caught.
tryIO :: IO a -> IO (Either GCError a)
tryIO = tryWith GCIO

-- | Run an action. If it fails because a file or directory is missing, give
-- the default value. Other exceptions go up.
ifMissing :: a -> IO a -> IO a
ifMissing d act = either (const d) id <$> tryJust (guard . isDoesNotExistError) act

-- | Read the roots from disk: the refs and the pins. 'rootTemps' is empty.
-- Set it in the result if the run has temporary roots.
readRoots :: Policy -> Refs -> Store -> IO (Either GCError Roots)
readRoots p rs s = runExceptT $ do
  refs <- ExceptT (readRefRoots (keepGenerations p) rs)
  pins <- ExceptT (listPins s)
  pure Roots {rootRefs = refs, rootPins = pins, rootTemps = Set.empty}

-- | The values that the refs keep: @'retained' n@ of each ref, joined.
--
-- A ref that is gone between 'listRefs' and 'getRef' is skipped. A corrupt
-- ref is an error ('GCRefs'): GC cannot know what it keeps, so it must not
-- guess and collect.
readRefRoots :: Int -> Refs -> IO (Either GCError (Set Id))
readRefRoots n rs = runExceptT $ do
  names <- withExceptT GCRefs (ExceptT (listRefs rs))
  Set.unions <$> traverse one names
  where
    one name = withExceptT GCRefs $ ExceptT $ do
      r <- getRef rs name
      pure $ case r of
        Left (NoSuchRef _) -> Right Set.empty
        _ -> retained n <$> r

-- Pins -----------------------------------------------------------------

-- | The directory of the pins: @\<root\>/pins@.
pinsDir :: Store -> FilePath
pinsDir s = storeRoot s </> "pins"

-- | The file of a pin: @\<root\>/pins/sha256-…@. The file is empty. Its name
-- is the pin.
--
-- This function is pure: it does not look at the disk.
pinPath :: Store -> Id -> FilePath
pinPath s i = pinsDir s </> T.unpack (Id.render i)

-- | Pin an object, so that GC keeps it and what it retains. Pinning an object
-- twice is the same as once. The object does not have to be in the store.
pin :: Store -> Id -> IO (Either GCError ())
pin s i = tryIO $ do
  createDirectoryIfMissing True (pinsDir s)
  atomicWrite (pinPath s i) BS.empty

-- | Remove a pin. If the object is not pinned, the function does nothing.
unpin :: Store -> Id -> IO (Either GCError ())
unpin s i = tryIO $ ifMissing () (removeFile (pinPath s i))

-- | All the pins. If there is no @pins@ directory, there are no pins. The
-- function skips each name that is not an 'Id', for example a temporary
-- file of 'atomicWrite'.
listPins :: Store -> IO (Either GCError (Set Id))
listPins s = tryIO $ do
  names <- ifMissing [] (listDirectory (pinsDir s))
  pure $ Set.fromList $ mapMaybe (either (const Nothing) Just . Id.parse . T.pack) names

-- The plan -------------------------------------------------------------

-- | The objects to collect. This function is pure.
--
-- An object is live if a root reaches it through edges for which 'retains'
-- is true, or if it is younger than the grace period. A young object is a
-- root too, so what it retains is also live. Then a new memory that points
-- at an old one, before its ref is set, cannot lose its target.
--
-- The result is the nodes of the graph that are not live. It never holds a
-- root, a young object, or an 'Id' that is not a node of the graph.
--
-- 'reachable' can return dangling targets ('Id' values that are not nodes).
-- This function does not rely on that either way: it takes the live set
-- away from the nodes, so a dangling target in the live set has no effect.
plan :: Policy -> Observed -> Roots -> Graph -> Set Id
plan p o r g = ns `Set.difference` live
  where
    ns = nodes g
    fresh = Set.filter (young p o) ns
    live = reachable retains (allRoots r <> fresh) g

-- Why an object stays ---------------------------------------------------

-- | One reason why GC keeps an object.
--
-- The order of the constructors is the order in which 'explain' lists the
-- reasons: the roots first, then the age, then the edges.
data Reason
  = -- | A ref holds it: the current value, or a generation that
    -- 'keepGenerations' keeps. 'Roots' does not say which ref. A caller that
    -- needs the name can look in the refs.
    HeldByRef
  | -- | A pin holds it.
    HeldByPin
  | -- | A temporary root of the run holds it.
    HeldByTemp
  | -- | It is a node that is younger than 'gracePeriod', or whose age is not
    -- known.
    IsYoung
  | -- | A live memory has a retaining edge of this kind to it. The 'Id' is
    -- that memory.
    RetainedBy EdgeType Id
  deriving (Eq, Ord, Show)

-- | What 'explain' found out about one 'Id'. This is plain data.
data Why = Why
  { -- | 'True' if the 'Id' is a node of the graph. 'plan' never returns an
    -- 'Id' that is not a node.
    whyIsNode :: Bool,
    -- | 'True' if the 'Id' is live: a root, a young node, or the target of a
    -- retaining edge from a live memory.
    whyLive :: Bool,
    -- | Every reason why the 'Id' is live, in the order of 'Reason'. For a
    -- node, the list is empty exactly when the node is not live.
    whyReasons :: [Reason],
    -- | One shortest chain of retaining edges to the 'Id'. Each step is a
    -- memory and the kind of its edge to the next memory, or to the 'Id'
    -- after the last step. The first memory is a root or a young node.
    -- The list is empty if the 'Id' is a root or a young node itself, and
    -- if it is not live.
    whyPath :: [(Id, EdgeType)]
  }
  deriving (Eq, Show)

-- | Why GC keeps an object, or why not. This function is pure.
--
-- It uses the same rule as 'plan', so the two agree: an 'Id' is in the
-- result of 'plan' exactly when 'whyIsNode' is 'True' and 'whyLive' is
-- 'False'. A property test checks this.
--
-- The function lists every reason, not only the first. A person who asks
-- "why is this still here?" then sees all the things that must change before
-- GC takes it. The path shows one way in which liveness reached the 'Id'.
explain :: Policy -> Observed -> Roots -> Graph -> Id -> Why
explain p o r g i = whyOf lv (pathTo (parentsFrom (lvSeeds lv) g (Just i)) i) i
  where
    lv = liveness p o r g

-- | 'explain' for every node of the graph. This function is pure.
--
-- It finds the live set and the chains once for the whole graph, so it costs
-- about as much as one call of 'explain'. A call of 'explain' for each node
-- would cost that much for each node. For each node @i@, the value is
-- @explain p o r g i@. A property test checks this.
explainAll :: Policy -> Observed -> Roots -> Graph -> Map Id Why
explainAll p o r g = Map.fromSet (\i -> whyOf lv (pathTo parents i) i) (nodes g)
  where
    lv = liveness p o r g
    parents = parentsFrom (lvSeeds lv) g Nothing

-- | The facts that 'explain' needs about the whole graph.
data Liveness = Liveness
  { lvRoots :: Roots,
    lvGraph :: Graph,
    lvNodes :: Set Id,
    -- | The young nodes.
    lvFresh :: Set Id,
    -- | The roots and the young nodes.
    lvSeeds :: Set Id,
    -- | What the seeds reach through retaining edges, as in 'plan'.
    lvLive :: Set Id
  }

-- | The live set, with the same rule as 'plan'.
liveness :: Policy -> Observed -> Roots -> Graph -> Liveness
liveness p o r g = Liveness r g ns fresh seeds (reachable retains seeds g)
  where
    ns = nodes g
    fresh = Set.filter (young p o) ns
    seeds = allRoots r <> fresh

-- | The 'Why' of one 'Id', with a chain that the caller found.
whyOf :: Liveness -> [(Id, EdgeType)] -> Id -> Why
whyOf lv path i =
  Why
    { whyIsNode = i `Set.member` lvNodes lv,
      whyLive = i `Set.member` lvLive lv,
      whyReasons = rootReasons <> [IsYoung | i `Set.member` lvFresh lv] <> edgeReasons,
      whyPath = if i `Set.member` lvSeeds lv then [] else path
    }
  where
    r = lvRoots lv
    rootReasons =
      [HeldByRef | i `Set.member` rootRefs r]
        <> [HeldByPin | i `Set.member` rootPins r]
        <> [HeldByTemp | i `Set.member` rootTemps r]
    edgeReasons =
      [ RetainedBy k s
      | k <- [minBound .. maxBound],
        retains k,
        s <- Set.toAscList (predecessors k i (lvGraph lv)),
        s `Set.member` lvLive lv
      ]

-- | The first parent of each node on the shortest chains of retaining edges
-- from the seeds. A seed has no parent, and neither has a node that no chain
-- reaches.
--
-- The function walks forward from the seeds, one level at a time, and keeps
-- the first parent that it finds for each node. Each level goes in ascending
-- order of 'Id' and kind, so the result is always the same. With a goal, it
-- stops after the level that reaches the goal. The parent of the goal, and
-- of each node before it, is then the same as in a full walk.
parentsFrom :: Set Id -> Graph -> Maybe Id -> Map Id (Id, EdgeType)
parentsFrom seeds g goal = go seeds seeds Map.empty
  where
    -- visited, frontier, parent of each node found so far
    go visited frontier parents
      | maybe False (`Map.member` parents) goal = parents
      | Set.null frontier = parents
      | otherwise = go (visited <> found) found (parents <> new)
      where
        found = Map.keysSet new
        new =
          Map.fromListWith
            (\_ firstSeen -> firstSeen)
            [ (t, (s, k))
            | s <- Set.toAscList frontier,
              k <- [minBound .. maxBound],
              retains k,
              t <- Set.toAscList (successors k s g),
              t `Set.notMember` visited
            ]

-- | Follow the parents back from an 'Id' to a node with no parent. The
-- result goes from that node to the 'Id'.
pathTo :: Map Id (Id, EdgeType) -> Id -> [(Id, EdgeType)]
pathTo parents = go []
  where
    go acc x = case Map.lookup x parents of
      Just (s, k) -> go ((s, k) : acc) s
      Nothing -> acc

-- Inputs from disk ------------------------------------------------------

-- | When each object came into the store: the modification time of its
-- file.
--
-- GC uses the file time, not the @created@ header of the memory. An agent
-- writes @created@, and it can be old (an import) or wrong (a bad clock).
-- The file time says when the object came to /this/ store, and the grace
-- period is about that. A rename to @trash@ keeps the file time, so 'sweep'
-- sets it again.
--
-- 'Akyuu.Store.add' of an object that is already there sets its file time to
-- now. So an agent that adds an old object again gets the grace period too.
--
-- An object that is gone between 'Akyuu.Store.list' and the read is skipped.
storedTimes :: Store -> IO (Either GCError (Map Id UTCTime))
storedTimes s = runExceptT $ do
  ids <- withExceptT GCStore (ExceptT (Store.list s))
  ExceptT (timesOf s ids)

-- | The file times of these objects. A missing object is left out, so it
-- counts as young.
timesOf :: (Foldable f) => Store -> f Id -> IO (Either GCError (Map Id UTCTime))
timesOf s ids = tryIO $ Map.fromList . catMaybes <$> traverse age (toList ids)
  where
    age i = ifMissing Nothing (Just . (i,) <$> getModificationTime (objectPath s i))

-- | Add to a graph each object of the store that is not a node of it yet.
--
-- The function lists the store and reads only the new objects, so it is
-- cheap when few objects are new. An object that is gone before the read is
-- skipped. Any other store error stops it: GC cannot know the edges of an
-- object that it cannot read, so it must not guess.
extendGraph :: Store -> Graph -> IO (Either GCError Graph)
extendGraph s g = runExceptT $ do
  ids <- withExceptT GCStore (ExceptT (Store.list s))
  new <- catMaybes <$> traverse (ExceptT . fetch) (filter (`Set.notMember` nodes g) ids)
  pure (g <> foldMap (\(i, m) -> singleton i (Set.toList (memEdges m))) new)
  where
    fetch i = do
      r <- Store.get s i
      pure $ case r of
        Left (NotFound _) -> Right Nothing
        Left e -> Left (GCStore e)
        Right m -> Right (Just (i, m))

-- | Read the graph and the ages that 'plan' needs. This function writes
-- nothing: not the store, and not the cache.
--
-- The steps are: 'Akyuu.Cache.loadGraph', then 'extendGraph' with the
-- objects that the cache does not have yet, then 'storedTimes'. So the graph
-- holds every object of the store, also if the cache is out of date. An
-- object that comes later is not in the graph, so 'plan' cannot collect it.
--
-- The cache can also hold a memory that is no longer in the store. It has no
-- file time, so it counts as young: 'plan' does not return it, and it keeps
-- what it retains. This is safe. 'sweepAndSync' brings the cache up to date.
snapshot :: Cache -> Store -> IO (Either GCError (Graph, Map Id UTCTime))
snapshot c s = runExceptT $ do
  cached <- withExceptT GCCache (ExceptT (Cache.loadGraph c))
  g <- ExceptT (extendGraph s cached)
  ages <- ExceptT (storedTimes s)
  pure (g, ages)

-- | Plan again, just before a sweep, with what changed since the snapshot.
-- The result is a subset of the old plan.
--
-- The function adds the new objects of the store to the graph
-- ('extendGraph'), reads the refs and pins again and adds them to the old
-- roots, and reads the file times of the planned objects only. Then it calls
-- 'plan' again. Every other node has no file time here, so it counts as
-- young. That is safe: it was live in the first plan, so what it retains was
-- live too.
--
-- This drops an object that an agent added again, pinned, pointed a ref at,
-- or linked from a new memory, since the snapshot. It costs one
-- 'Akyuu.Store.list', a read of each new object, and one file time for each
-- planned object.
recheck :: Store -> Refs -> Policy -> UTCTime -> Roots -> Graph -> Set Id -> IO (Either GCError (Set Id))
recheck s rs p t r g doomed = runExceptT $ do
  g' <- ExceptT (extendGraph s g)
  fresh <- ExceptT (readRoots p rs s)
  ages <- ExceptT (timesOf s doomed)
  let r' =
        r
          { rootRefs = rootRefs r <> rootRefs fresh,
            rootPins = rootPins r <> rootPins fresh
          }
  pure (doomed `Set.intersection` plan p (Observed t ages) r' g')

-- Errors ---------------------------------------------------------------

-- | Why a GC function failed.
data GCError
  = -- | The disk gave an error.
    GCIO IOException
  | -- | A store function failed.
    GCStore StoreError
  | -- | A refs function failed, for example a corrupt ref.
    GCRefs RefError
  | -- | A cache function failed.
    GCCache CacheError
  | -- | The tombstone of this 'Id' is not a valid tombstone.
    CorruptTombstone Id TombstoneParseError
  | -- | Another run of GC held the lock for more than about one second. This
    -- run changed nothing. Try again later.
    GCLocked
  deriving (Eq, Show)

-- Sweep ----------------------------------------------------------------

-- | What 'sweep' did. The order of each list is not defined.
data SweepReport = SweepReport
  { -- | The objects that phase 1 moved to @trash@.
    trashed :: [Id],
    -- | The files that phase 2 deleted from @trash@.
    deleted :: [Id]
  }
  deriving (Eq, Show)

-- | Sweep in two phases, under the lock of GC (see 'withGCLock').
--
-- Phase 1 moves each object of the set to @trash@ with
-- 'Akyuu.Store.trash', and sets the file time of the moved file to the time
-- of the run (the 'UTCTime' argument).
-- A rename keeps the old file time, so without this step phase 2 could
-- delete the object at once. An object that is not in the store is skipped.
--
-- Just before it moves an object, phase 1 reads its file time again. If the
-- object is younger than 'gracePeriod' now (an agent added it again since the
-- plan), it is skipped. See the module header for the gap that is left.
--
-- Phase 2 deletes each file in @trash@ whose file time is more than
-- 'trashTTL' before the time of the run. This includes files of earlier runs.
-- Before it
-- deletes a file, it writes a tombstone (see 'Tombstone'), so that a link to
-- the object can say "pruned". If the object is in the store again (an agent
-- added it again after phase 1), the copy in @trash@ is deleted with no
-- tombstone.
--
-- The tombstone comes before the delete. After a crash between them, the
-- next run deletes the file and writes the tombstone again.
--
-- If a crash comes between the move and the new file time, the file keeps
-- its old time, and phase 2 of a later run can delete it early. It was
-- garbage, so this is safe, but the time to undo is shorter.
--
-- This function does not tell the cache. Use 'sweepAndSync'.
sweep :: Store -> Policy -> UTCTime -> Set Id -> IO (Either GCError SweepReport)
sweep s p t doomed = withGCLock s (sweepUnlocked s p t doomed)

-- | 'sweep' without the lock. The caller holds it.
sweepUnlocked :: Store -> Policy -> UTCTime -> Set Id -> IO (Either GCError SweepReport)
sweepUnlocked s p t doomed = runExceptT $ do
  moved <- catMaybes <$> traverse (ExceptT . moveOne) (Set.toList doomed)
  gone <- ExceptT (purge s p t)
  pure SweepReport {trashed = moved, deleted = gone}
  where
    moveOne i = do
      stamp <- tryIO $ ifMissing Nothing (Just <$> getModificationTime (objectPath s i))
      case stamp of
        Left e -> pure (Left e)
        Right Nothing -> pure (Right Nothing) -- not in the store
        Right (Just m) | diffUTCTime t m < gracePeriod p -> pure (Right Nothing) -- young again
        Right (Just _) -> do
          r <- Store.trash s i
          case r of
            Left (NotFound _) -> pure (Right Nothing)
            Left e -> pure (Left (GCStore e))
            Right () -> tryIO (Just i <$ setModificationTime (trashPath s i) t)

-- | Phase 2 of 'sweep': delete the old files in @trash@, and leave a
-- tombstone for each one. Returns the 'Id' of each deleted file.
purge :: Store -> Policy -> UTCTime -> IO (Either GCError [Id])
purge s p t = tryIO $ do
  names <- ifMissing [] (listDirectory (storeRoot s </> "trash"))
  catMaybes <$> traverse one (mapMaybe trashId names)
  where
    one i = do
      moved <- ifMissing Nothing (Just <$> getModificationTime (trashPath s i))
      case moved of
        Just m | diffUTCTime t m > trashTTL p -> do
          back <- doesFileExist (objectPath s i)
          unless back $ writeTombstone s i (Tombstone t)
          ifMissing () (removeFile (trashPath s i))
          pure (Just i)
        _ -> pure Nothing

-- | Read an 'Id' from the name of a file in @trash@: the text form and
-- @.md@. Other names (for example a file that a person put there) are
-- skipped.
trashId :: FilePath -> Maybe Id
trashId n = do
  stem <- T.stripSuffix ".md" (T.pack n)
  either (const Nothing) Just (Id.parse stem)

-- | 'sweep', then 'Akyuu.Cache.sync', so that the cache forgets the swept
-- objects. GC does not call 'Akyuu.Cache.forget' itself. Both steps run
-- under the lock of GC.
--
-- The sync runs also if the sweep fails, because a sweep that stops in the
-- middle can still have moved some objects. The first error is the result.
sweepAndSync :: Cache -> Store -> Policy -> UTCTime -> Set Id -> IO (Either GCError (SweepReport, SyncReport))
sweepAndSync c s p t doomed = withGCLock s (sweepAndSyncUnlocked c s p t doomed)

-- | 'sweepAndSync' without the lock. The caller holds it.
sweepAndSyncUnlocked :: Cache -> Store -> Policy -> UTCTime -> Set Id -> IO (Either GCError (SweepReport, SyncReport))
sweepAndSyncUnlocked c s p t doomed = do
  r <- sweepUnlocked s p t doomed
  synced <- Cache.sync c s
  pure $ (,) <$> r <*> first GCCache synced

-- A whole run -----------------------------------------------------------

-- | What 'collect' did.
data RunReport = RunReport
  { -- | The objects that the run passed to the sweep: the plan, after
    -- 'recheck'.
    planned :: Set Id,
    -- | What the sweep did.
    swept :: SweepReport,
    -- | What the sync of the cache did.
    synced :: SyncReport
  }
  deriving (Eq, Show)

-- | The path of the lock file of GC: @\<root\>/gc.lock@.
gcLockPath :: Store -> FilePath
gcLockPath s = storeRoot s </> "gc.lock"

-- | Run an action with the lock of GC, so that only one run sweeps at a time.
--
-- The lock is an exclusive @flock@ on 'gcLockPath'. The OS releases it when
-- the holder ends, so a crash cannot leave it held. The lock file stays on
-- disk. This is normal.
--
-- Like the locks of "Akyuu.Refs" and "Akyuu.Cache", the function does not
-- wait inside the lock call, because a blocked call would also block the
-- other Haskell threads of the program. It tries the lock, and if it is
-- taken, waits 10 ms with 'threadDelay' and tries again, up to 100 times
-- (about one second). Then it returns 'GCLocked'. A run takes much longer
-- than that, so a second run gives up and does not wait for the first.
--
-- The lock is not re-entrant: do not call 'sweep' or 'sweepAndSync' inside
-- this function. An 'IOException' from the lock, or from the action, becomes
-- 'GCIO'.
withGCLock :: Store -> IO (Either GCError a) -> IO (Either GCError a)
withGCLock s act = go (100 :: Int)
  where
    go 0 = pure (Left GCLocked) -- tried 100 times: give up
    go k = do
      got <- tryIO (withTryFileLock (gcLockPath s) Exclusive (const act))
      case got of
        Left e -> pure (Left e)
        Right Nothing -> threadDelay 10000 >> go (k - 1)
        Right (Just v) -> pure v

-- | Read the inputs and make the plan, for a run at this time. The roots
-- get these temporary roots. This writes nothing.
planAt :: Cache -> Store -> Refs -> Policy -> Set Id -> UTCTime -> IO (Either GCError (Roots, Graph, Set Id))
planAt c s rs p temps t = runExceptT $ do
  (g, ages) <- ExceptT (snapshot c s)
  r <- ExceptT (readRoots p rs s)
  let roots = r {rootTemps = temps}
  pure (roots, g, plan p (Observed t ages) roots g)

-- | The plan of a run now, with these temporary roots. This writes nothing:
-- not the store, not the cache, and not the lock. Use it for
-- @akyuu gc --dry-run@.
dryRun :: Cache -> Store -> Refs -> Policy -> Set Id -> IO (Either GCError (Set Id))
dryRun c s rs p temps = do
  t <- getCurrentTime
  fmap (\(_, _, d) -> d) <$> planAt c s rs p temps t

-- | One whole run of GC now, with these temporary roots.
--
-- The steps, under the lock of GC ('withGCLock'):
--
-- 1. Read the graph, the ages and the roots, and make the plan.
-- 2. Look again with 'recheck', and drop what is live now.
-- 3. 'sweep', then 'Akyuu.Cache.sync'.
--
-- Returns 'GCLocked' if another run holds the lock.
collect :: Cache -> Store -> Refs -> Policy -> Set Id -> IO (Either GCError RunReport)
collect c s rs p temps = withGCLock s $ runExceptT $ do
  t <- liftIO getCurrentTime
  (r, g, doomed) <- ExceptT (planAt c s rs p temps t)
  doomed' <- ExceptT (recheck s rs p t r g doomed)
  (rep, syn) <- ExceptT (sweepAndSyncUnlocked c s p t doomed')
  pure RunReport {planned = doomed', swept = rep, synced = syn}

-- Tombstones -----------------------------------------------------------

-- | A record that GC deleted an object. A dangling link uses it to say
-- "pruned" and not "missing" (which would mean a damaged store).
--
-- The file is @tombstones/sha256-…@, with one line of UTF-8 text:
--
-- > pruned: 2026-10-10T12:00:00Z
--
-- The time is when phase 2 of 'sweep' deleted the object, in UTC, in whole
-- seconds. A tombstone means only "GC deleted this once". An agent can add
-- the same object again later, so check the store first.
newtype Tombstone = Tombstone
  { -- | When GC deleted the object.
    prunedAt :: UTCTime
  }
  deriving (Eq, Show)

-- | Why some bytes are not a valid tombstone.
data TombstoneParseError
  = -- | The bytes are not UTF-8 text.
    TombstoneNotUtf8
  | -- | The text is not @pruned: \<time\>@. The error holds the text.
    BadTombstone Text
  deriving (Eq, Show)

-- | The format of the time, for example @2026-10-10T12:00:00Z@. It is the
-- same format as the @created@ header of a memory.
timeFormat :: String
timeFormat = "%Y-%m-%dT%H:%M:%SZ"

-- | Write a tombstone as bytes: @pruned: \<time\>@ and a newline. The time
-- keeps whole seconds only.
renderTombstone :: Tombstone -> ByteString
renderTombstone (Tombstone t) =
  TE.encodeUtf8 ("pruned: " <> T.pack (formatTime defaultTimeLocale timeFormat t) <> "\n")

-- | Read a tombstone from bytes. This reverses 'renderTombstone', for a time
-- in whole seconds. The final newline can be missing.
--
-- Like the @created@ header, the time must be in exactly the form that
-- 'renderTombstone' writes.
parseTombstone :: ByteString -> Either TombstoneParseError Tombstone
parseTombstone bs = do
  t <- first (const TombstoneNotUtf8) (TE.decodeUtf8' bs)
  let line = fromMaybe t (T.stripSuffix "\n" t)
      bad = Left (BadTombstone t)
  case T.stripPrefix "pruned: " line of
    Nothing -> bad
    Just v -> case parseTimeM False defaultTimeLocale timeFormat (T.unpack v) of
      Just u | formatTime defaultTimeLocale timeFormat u == T.unpack v -> Right (Tombstone u)
      _ -> bad

-- | The directory of the tombstones: @\<root\>/tombstones@.
tombstonesDir :: Store -> FilePath
tombstonesDir s = storeRoot s </> "tombstones"

-- | The file of a tombstone: @\<root\>/tombstones/sha256-…@.
--
-- This function is pure: it does not look at the disk.
tombstonePath :: Store -> Id -> FilePath
tombstonePath s i = tombstonesDir s </> T.unpack (Id.render i)

-- | Write a tombstone. A tombstone that is already there is replaced. This
-- function throws an 'IOException' on failure. 'purge' catches it.
writeTombstone :: Store -> Id -> Tombstone -> IO ()
writeTombstone s i t = do
  createDirectoryIfMissing True (tombstonesDir s)
  atomicWrite (tombstonePath s i) (renderTombstone t)

-- | Read the tombstone of an object. Returns 'Nothing' if there is none.
-- Returns 'CorruptTombstone' if the file is not a valid tombstone.
lookupTombstone :: Store -> Id -> IO (Either GCError (Maybe Tombstone))
lookupTombstone s i = do
  r <- tryIO $ ifMissing Nothing (Just <$> BS.readFile (tombstonePath s i))
  pure $ r >>= traverse (first (CorruptTombstone i) . parseTombstone)

-- | All the tombstones, sorted by 'Id'. If there is no @tombstones@
-- directory, there are none. The function skips each name that is not an
-- 'Id', for example a temporary file of 'atomicWrite'.
--
-- A tombstone that is not valid is an error for the whole list
-- ('CorruptTombstone'), like a damaged ref in a list of refs. A person then
-- sees that something is wrong, and not only a shorter list.
listTombstones :: Store -> IO (Either GCError [(Id, Tombstone)])
listTombstones s = do
  names <- tryIO $ ifMissing [] (listDirectory (tombstonesDir s))
  case names of
    Left e -> pure (Left e)
    Right ns -> runExceptT $ do
      let ids = Set.toAscList (Set.fromList (mapMaybe (either (const Nothing) Just . Id.parse . T.pack) ns))
      catMaybes <$> traverse (\i -> fmap ((,) i) <$> ExceptT (lookupTombstone s i)) ids

-- Trash ----------------------------------------------------------------

-- | The objects in @trash@, sorted by 'Id', each with the time that phase 1
-- of 'sweep' moved it there (the file time, which 'sweep' sets). Phase 2
-- deletes a file when this time is more than 'trashTTL' ago.
--
-- If there is no @trash@ directory, the list is empty. A name that is not an
-- object is skipped. A file that phase 2 deletes during the call is skipped.
listTrash :: Store -> IO (Either GCError [(Id, UTCTime)])
listTrash s = tryIO $ do
  names <- ifMissing [] (listDirectory (storeRoot s </> "trash"))
  let ids = Set.toAscList (Set.fromList (mapMaybe trashId names))
  catMaybes <$> traverse (\i -> ifMissing Nothing (Just . (i,) <$> getModificationTime (trashPath s i))) ids
