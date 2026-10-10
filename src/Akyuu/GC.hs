-- | Garbage collection: find the memories that nothing needs, and remove them.
--
-- GC has a pure part and an I/O part. The pure part, 'plan', gets the roots,
-- the graph and the ages of the objects as data, and returns the set of
-- 'Id' values to collect. A dry run is a call to 'plan' and nothing else, so
-- it is free and it cannot change the store.
--
-- The I/O part reads the inputs ('readRoots', 'snapshot') and does the work
-- ('sweep', 'sweepAndSync').
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
--
-- = What GC trusts
--
-- 'plan' returns only nodes of the graph. An object that is not in the graph
-- (for example an object that an agent added after the graph was read) is
-- never collected. The edges of a node come from an immutable object, so a
-- node's edges are always right. The graph must hold every object that is old
-- enough to collect, so 'snapshot' syncs the cache before it reads the graph.
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

    -- * Inputs from disk
    storedTimes,
    snapshot,

    -- * Errors
    GCError (..),

    -- * Sweep
    SweepReport (..),
    sweep,
    sweepAndSync,

    -- * Tombstones
    Tombstone (..),
    TombstoneParseError (..),
    renderTombstone,
    parseTombstone,
    tombstonePath,
    lookupTombstone,
  )
where

import Akyuu.Cache (Cache, CacheError, SyncReport)
import Akyuu.Cache qualified as Cache
import Akyuu.Fs (atomicWrite, tryWith)
import Akyuu.Graph (EdgeType (..), Graph, nodes, reachable)
import Akyuu.Id (Id)
import Akyuu.Id qualified as Id
import Akyuu.Refs (RefError (NoSuchRef), Refs, getRef, listRefs, retained)
import Akyuu.Store (Store, StoreError (NotFound), objectPath, storeRoot, trashPath)
import Akyuu.Store qualified as Store
import Control.Exception (IOException, tryJust)
import Control.Monad (guard, unless)
import Control.Monad.Trans.Except (ExceptT (ExceptT), runExceptT, withExceptT)
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
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
-- Note: 'Akyuu.Store.add' does not write an object that is already there,
-- so it does not change the file time.
--
-- An object that is gone between 'Akyuu.Store.list' and the read is skipped.
storedTimes :: Store -> IO (Either GCError (Map Id UTCTime))
storedTimes s = runExceptT $ do
  ids <- withExceptT GCStore (ExceptT (Store.list s))
  ExceptT $ tryIO $ Map.fromList . catMaybes <$> traverse age ids
  where
    age i = ifMissing Nothing (Just . (i,) <$> getModificationTime (objectPath s i))

-- | Read the graph and the ages that 'plan' needs.
--
-- The steps are: 'Akyuu.Cache.sync', then 'Akyuu.Cache.loadGraph', then
-- 'storedTimes'. The sync comes first, so that the graph holds every object
-- of the store. An object that comes after the sync is not in the graph, so
-- 'plan' cannot collect it.
--
-- This changes the cache, but not the store. The cache is not the truth, so
-- a dry run can call this function.
snapshot :: Cache -> Store -> IO (Either GCError (Graph, Map Id UTCTime))
snapshot c s = runExceptT $ do
  _ <- withExceptT GCCache (ExceptT (Cache.sync c s))
  g <- withExceptT GCCache (ExceptT (Cache.loadGraph c))
  ages <- ExceptT (storedTimes s)
  pure (g, ages)

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

-- | Sweep in two phases.
--
-- Phase 1 moves each object of the set to @trash@ with
-- 'Akyuu.Store.trash', and sets the file time of the moved file to the time
-- of the run (the 'UTCTime' argument).
-- A rename keeps the old file time, so without this step phase 2 could
-- delete the object at once. An object that is not in the store is skipped.
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
sweep s p t doomed = runExceptT $ do
  moved <- catMaybes <$> traverse (ExceptT . moveOne) (Set.toList doomed)
  gone <- ExceptT (purge s p t)
  pure SweepReport {trashed = moved, deleted = gone}
  where
    moveOne i = do
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
-- objects. GC does not call 'Akyuu.Cache.forget' itself.
--
-- The sync runs also if the sweep fails, because a sweep that stops in the
-- middle can still have moved some objects. The first error is the result.
sweepAndSync :: Cache -> Store -> Policy -> UTCTime -> Set Id -> IO (Either GCError (SweepReport, SyncReport))
sweepAndSync c s p t doomed = do
  r <- sweep s p t doomed
  synced <- Cache.sync c s
  pure $ (,) <$> r <*> first GCCache synced

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
