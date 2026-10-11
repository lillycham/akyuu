-- | Read a store for the web UI, and fill the types of "Akyuu.Web.Model".
--
-- Every function here only reads. It writes nothing: not the store, not the
-- refs, not the pins, and not the cache. In particular it does not call
-- 'Akyuu.Cache.sync'. The health view shows the drift between the cache and
-- the store, and a sync would hide it. The graph comes from the cache and
-- from the objects of the store that the cache does not have yet, as in
-- 'Akyuu.GC.snapshot', so a stale cache does not hide a new memory.
--
-- The search is the one exception to "the store is the truth": the text
-- index is in the cache, so a memory that the cache does not have yet is not
-- found. The health view shows such a memory under "store only".
--
-- The GC views use 'webPolicy', the policy of @akyuu gc@, and no temporary
-- roots.
module Akyuu.Web.Read
  ( webPolicy,
    readGraphData,
    readStats,
    readGraph,
    readMemory,
    readRefEntries,
    readRefs,
    readSearch,
    readPlan,
    readExplain,
    readTrash,
    readVerify,
    readBundle,
  )
where

import Akyuu.Cache (Summary (Summary, sumId))
import Akyuu.Cache qualified as Cache
import Akyuu.Error (AkyuuError (BadInput, CacheFailed, GCFailed, RefFailed, StoreFailed), describe)
import Akyuu.GC (Observed (Observed), Policy (keepGenerations), defaultPolicy)
import Akyuu.GC qualified as GC
import Akyuu.Graph (EdgeType (Supersedes))
import Akyuu.Graph qualified as Graph
import Akyuu.Id (Id)
import Akyuu.Id qualified as Id
import Akyuu.Memory (Memory (memAgent, memBody, memCreated, memKind))
import Akyuu.Ops (Env (envCache, envRefs, envStore), IdSpec, getMemory, missing, resolveId, verifyStore)
import Akyuu.Query (SearchOptions)
import Akyuu.Query qualified as Query
import Akyuu.Refs (RefError)
import Akyuu.Refs qualified as Refs
import Akyuu.Store (StoreError (NotFound))
import Akyuu.Store qualified as Store
import Akyuu.Web.Model (GraphData (GraphData, gdCached, gdGraph, gdStore, gdSummaries, gdTombstones), NodeStatus (HeadNode, SupersededNode), RefEntry (RefEntry), Stats (Stats, statCached, statMemories, statNewest, statPins, statRefs, statTombstones, statTrash), Window (winAll, winFocus), defaultWindow, graphView, graphViewJSON, memoryJSON, planJSON, refHolds, refsJSON, searchJSON, statsJSON, timeJSON, trashJSON, verifyJSON, whyJSON)
import Control.Exception (IOException, displayException, try, tryJust)
import Control.Monad (forM, guard)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Trans.Except (ExceptT (ExceptT), runExceptT, throwE, withExceptT)
import Data.Aeson (Value, object, (.=))
import Data.Aeson.Key qualified as K
import Data.List (sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (catMaybes)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime, getCurrentTime)
import System.Directory (doesDirectoryExist, getModificationTime, listDirectory)
import System.FilePath ((</>))
import System.IO.Error (isDoesNotExistError)

-- | The policy of the GC views: 'defaultPolicy', as @akyuu gc@ uses.
webPolicy :: Policy
webPolicy = defaultPolicy

store :: IO (Either StoreError a) -> ExceptT AkyuuError IO a
store = withExceptT StoreFailed . ExceptT

cache :: IO (Either Cache.CacheError a) -> ExceptT AkyuuError IO a
cache = withExceptT CacheFailed . ExceptT

gc :: IO (Either GC.GCError a) -> ExceptT AkyuuError IO a
gc = withExceptT GCFailed . ExceptT

refs :: IO (Either RefError a) -> ExceptT AkyuuError IO a
refs = withExceptT RefFailed . ExceptT

-- | Run an action on a path that may not exist. A missing path gives the
-- default value.
orMissing :: a -> IO a -> IO a
orMissing d act = either (const d) id <$> tryJust (guard . isDoesNotExistError) act

-- | An 'IOException' becomes a 'BadInput' with its text. The paths here
-- are fixed directories of the store, so this is rare.
io :: IO a -> ExceptT AkyuuError IO a
io act = do
  r <- liftIO (try act)
  either (\e -> throwE (BadInput ("A file of the store could not be read: " <> T.pack (displayException (e :: IOException))))) pure r

-- The graph ---------------------------------------------------------------

-- | The facts for the graph view, and the file time of each object.
--
-- The graph is 'GC.snapshot': the cache, and the objects of the store that
-- the cache does not have. A memory that the cache does not have gets its
-- summary from the store. The tombstones are read once, for the dangling
-- targets.
readGraphData :: Env -> IO (Either AkyuuError (GraphData, Map Id UTCTime))
readGraphData env = runExceptT $ do
  let s = envStore env
      c = envCache env
  (g, ages) <- gc (GC.snapshot c s)
  stored <- Set.fromList <$> store (Store.list s)
  cached <- cache (Cache.cachedIds c)
  sums <- cache (Cache.summaries c)
  let fromCache = Map.fromList [(sumId x, x) | x <- sums]
      needed = filter (`Map.notMember` fromCache) (Set.toList (stored `Set.intersection` Graph.nodes g))
  extra <- catMaybes <$> traverse (summaryFromStore env) needed
  tombs <- gc (GC.listTombstones s)
  let dead = Graph.dangling g
  pure
    ( GraphData
        { gdGraph = g,
          gdSummaries = fromCache <> Map.fromList [(sumId x, x) | x <- extra],
          gdStore = stored,
          gdCached = cached,
          gdTombstones = Map.fromList [(i, GC.prunedAt t) | (i, t) <- tombs, i `Set.member` dead]
        },
      ages
    )

-- | The summary of a memory, read from the store. An object that GC moved
-- away in the meantime gives 'Nothing'.
summaryFromStore :: Env -> Id -> ExceptT AkyuuError IO (Maybe Summary)
summaryFromStore env i = do
  r <- liftIO (Store.get (envStore env) i)
  case r of
    Left (NotFound _) -> pure Nothing
    Left e -> throwE (StoreFailed e)
    Right m -> pure (Just (Summary i (memKind m) (memAgent m) (memCreated m) (Cache.firstLine (memBody m))))

-- | The graph view of a window ('graphView').
--
-- A focus must be a memory or a dangling target of the graph. Any other
-- 'Id' gives 'NotFound', or 'Pruned' if it has a tombstone.
readGraph :: Env -> Window -> IO (Either AkyuuError Value)
readGraph env w = runExceptT $ do
  (d, _) <- ExceptT (readGraphData env)
  let g = gdGraph d
  case winFocus w of
    Just i | i `Set.notMember` (Graph.nodes g <> Graph.dangling g) -> missing env i
    _ -> pure ()
  pure (graphViewJSON (graphView w d))

-- Stats --------------------------------------------------------------------

-- | The cheap facts that the page polls ('Stats').
--
-- The function lists the directories and reads their file times. It does
-- not open an object. The newest time covers the directories of the store,
-- @trash@, @pins@ and @tombstones@, and every directory and file under
-- @refs@. A new object, a move, a new pin or a moved ref changes one of
-- them. An 'Akyuu.Store.add' of an object that is already there changes only
-- the time of that file, and not these times.
readStats :: Env -> IO (Either AkyuuError Stats)
readStats env = runExceptT $ do
  let s = envStore env
      root = Store.storeRoot s
  ids <- store (Store.list s)
  cached <- cache (Cache.cachedIds (envCache env))
  names <- refs (Refs.listRefs (envRefs env))
  pins <- gc (GC.listPins s)
  trash <- io (orMissing [] (listDirectory (root </> "trash")))
  tombs <- io (orMissing [] (listDirectory (root </> "tombstones")))
  shards <- io (orMissing [] (listDirectory (root </> "store")))
  refPaths <- io (walk (root </> "refs"))
  let dirs =
        [root </> "store", root </> "trash", root </> "pins", root </> "tombstones"]
          <> map ((root </> "store") </>) shards
          <> refPaths
  times <- io (catMaybes <$> traverse (\p -> orMissing Nothing (Just <$> getModificationTime p)) dirs)
  pure
    Stats
      { statMemories = length ids,
        statCached = Set.size cached,
        statRefs = length names,
        statPins = Set.size pins,
        statTrash = length (filter isObjectName trash),
        statTombstones = length (filter isIdName tombs),
        statNewest = if null times then Nothing else Just (maximum times)
      }
  where
    isIdName n = either (const False) (const True) (Id.parse (T.pack n))
    isObjectName n = maybe False (isIdName . T.unpack) (T.stripSuffix ".md" (T.pack n))
    -- Every directory and file under @refs@, and @refs@ itself.
    walk :: FilePath -> IO [FilePath]
    walk dir = orMissing [] $ do
      names <- listDirectory dir
      rest <- forM names $ \n -> do
        let p = dir </> n
        isDir <- doesDirectoryExist p
        if isDir then walk p else pure [p]
      pure (dir : concat rest)

-- Memories -----------------------------------------------------------------

-- | One memory with its edges, the refs that hold it, its status and its
-- file time. The 'Id' can be the start of one ('resolveId').
--
-- The read checks the hash ('getMemory'). A memory that GC deleted gives
-- 'Pruned'.
readMemory :: Env -> IdSpec -> IO (Either AkyuuError Value)
readMemory env spec = runExceptT $ do
  i <- ExceptT (resolveId env spec)
  m <- ExceptT (getMemory env i)
  cached <- cache (Cache.loadGraph (envCache env))
  g <- gc (GC.extendGraph (envStore env) cached)
  es <- liftIO (readRefEntries env)
  holds <- either throwE (pure . (`refHolds` i)) es
  stored <- io (orMissing Nothing (Just <$> getModificationTime (Store.objectPath (envStore env) i)))
  let st = if Set.null (Graph.predecessors Supersedes i g) then HeadNode else SupersededNode
  pure (memoryJSON i m (Query.neighbourList i g) holds st stored)

-- Refs ---------------------------------------------------------------------

-- | Every ref, sorted by name, with its value or the error of its file.
readRefEntries :: Env -> IO (Either AkyuuError [RefEntry])
readRefEntries env = runExceptT $ do
  names <- refs (Refs.listRefs (envRefs env))
  forM (sortOn Refs.nameText names) $ \n ->
    RefEntry n <$> liftIO (Refs.getRef (envRefs env) n)

-- | The JSON of every ref ('refsJSON').
readRefs :: Env -> IO (Either AkyuuError Value)
readRefs env = fmap (refsJSON (keepGenerations webPolicy)) <$> readRefEntries env

-- Search -------------------------------------------------------------------

-- | A search of the text index ('Akyuu.Query.search'). This does not sync
-- the cache first. See the module header.
readSearch :: Env -> SearchOptions -> Text -> IO (Either AkyuuError Value)
readSearch env o q = runExceptT $ searchJSON q <$> cache (Query.search (envCache env) o q)

-- GC -----------------------------------------------------------------------

-- | The inputs of a GC run now: the graph, the facts of the run and the
-- roots. This writes nothing, like 'GC.dryRun'.
gcInputs :: Env -> ExceptT AkyuuError IO (Graph.Graph, Observed, GC.Roots)
gcInputs env = do
  t <- liftIO getCurrentTime
  (g, ages) <- gc (GC.snapshot (envCache env) (envStore env))
  r <- gc (GC.readRoots webPolicy (envRefs env) (envStore env))
  pure (g, Observed t ages, r)

-- | The plan of a GC run now ('planJSON').
readPlan :: Env -> IO (Either AkyuuError Value)
readPlan env = runExceptT $ do
  (g, o, r) <- gcInputs env
  let ns = Graph.nodes g
  pure (planJSON webPolicy o r ns (Set.filter (GC.young webPolicy o) ns) (GC.plan webPolicy o r g))

-- | Why GC keeps one object now, or why not ('GC.explain', 'whyJSON').
readExplain :: Env -> Id -> IO (Either AkyuuError Value)
readExplain env i = runExceptT $ do
  (g, o, r) <- gcInputs env
  es <- ExceptT (readRefEntries env)
  let w = GC.explain webPolicy o r g i
  if not (whyIsNodeOrRoot w)
    then missing env i
    else pure (whyJSON webPolicy o i w (refHolds es i))
  where
    whyIsNodeOrRoot w = GC.whyIsNode w || not (null (GC.whyReasons w))

-- | The trash, the tombstones and the pins ('trashJSON'). A pin can name an
-- object that is not in the store, so each pin says if it is there.
readTrash :: Env -> IO (Either AkyuuError Value)
readTrash env = runExceptT $ do
  let s = envStore env
  trash <- gc (GC.listTrash s)
  tombs <- gc (GC.listTombstones s)
  pins <- gc (GC.listPins s)
  there <- forM (Set.toAscList pins) $ \i -> (,) i <$> store (Store.exists s i)
  pure (trashJSON webPolicy trash tombs there)

-- | The report of 'verifyStore', and the drift between the cache and the
-- store ('verifyJSON'). This reads and hashes every object, so it is slow on
-- a big store.
readVerify :: Env -> IO (Either AkyuuError Value)
readVerify env = runExceptT $ do
  cached <- cache (Cache.cachedIds (envCache env))
  stored <- Set.fromList <$> store (Store.list (envStore env))
  r <- ExceptT (verifyStore env)
  pure (verifyJSON r cached stored)

-- The static export ----------------------------------------------------------

-- | Everything that the page shows, in one value, for @akyuu viz@.
--
-- The graph is the whole graph. Each memory of the store is there in full,
-- and each node has its 'GC.explain' (from 'GC.explainAll'). There is no
-- text index in the page, so the page searches the bodies itself.
--
-- A part that fails is an object with an @error@ text, so one problem does
-- not stop the export.
readBundle :: Env -> IO Value
readBundle env = do
  t <- getCurrentTime
  stats <- part (fmap statsJSON <$> readStats env)
  graph <- part (readGraph env defaultWindow {winAll = True})
  refsV <- part (readRefs env)
  plan <- part (readPlan env)
  trash <- part (readTrash env)
  verify <- part (readVerify env)
  mems <- either (\e -> (errorValue e, errorValue e)) id <$> memories t
  pure $
    object
      [ "generatedAt" .= timeJSON t,
        "stats" .= stats,
        "graph" .= graph,
        "refs" .= refsV,
        "plan" .= plan,
        "trash" .= trash,
        "verify" .= verify,
        "memories" .= fst mems,
        "explain" .= snd mems
      ]
  where
    part :: IO (Either AkyuuError Value) -> IO Value
    part act = either errorValue id <$> act
    errorValue e = object ["error" .= describe e]
    memories t = runExceptT $ do
      (d, ages) <- ExceptT (readGraphData env)
      es <- ExceptT (readRefEntries env)
      r <- gc (GC.readRoots webPolicy (envRefs env) (envStore env))
      let g = gdGraph d
          o = Observed t ages
          whys = GC.explainAll webPolicy o r g
      ms <- forM (Set.toAscList (gdStore d)) $ \i -> do
        m <- liftIO (getMemory env i)
        pure $ case m of
          Left _ -> Nothing
          Right x ->
            let st = if Set.null (Graph.predecessors Supersedes i g) then HeadNode else SupersededNode
             in Just (K.fromText (Id.render i) .= memoryJSON i x (Query.neighbourList i g) (refHolds es i) st (Map.lookup i ages))
      pure
        ( object (catMaybes ms),
          object [K.fromText (Id.render i) .= whyJSON webPolicy o i w (refHolds es i) | (i, w) <- Map.toAscList whys]
        )
