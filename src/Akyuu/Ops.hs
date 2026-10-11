-- | The operations of the program: the layer that the CLI and the MCP server
-- share.
--
-- Each operation joins the modules below it and returns an 'AkyuuError', so
-- the two front ends do the same thing and fail with the same text. The
-- front ends only parse their input and render the results.
--
-- An operation that reads the graph or the text index ('searchMemories',
-- 'neighboursOf') calls 'Akyuu.Cache.sync' first. On a cache that is up to
-- date, 'sync' reads only file names, so it is cheap. Then a memory that
-- another process added is found at once.
module Akyuu.Ops
  ( -- * The environment
    Env (..),
    resolveRoot,
    withEnv,

    -- * New memories
    NewMemory (..),
    checkField,
    buildMemory,

    -- * Operations
    addMemory,
    getMemory,
    missing,
    supersedeMemory,
    amendMemory,
    readRef,
    setRefTo,
    listRefNames,
    listRefValues,
    firstLines,
    pinMemory,
    unpinMemory,
    listPinned,
    IdSpec (..),
    parseIdSpec,
    resolveId,
    searchMemories,
    searchTuning,
    neighboursOf,
    parseDuration,
    dryRunGC,
    runGC,
    reindexCache,
    checkStore,
    reviewPair,
    appendEpisode,
    readLog,
    unreviewPair,
    listReviewed,
    ContextEntry (..),
    ContextReport (..),
    contextFor,
    CompareSide (..),
    CompareReport (..),
    compareMemories,

    -- * Verify
    VerifyReport (..),
    verifyOk,
    verifyStore,
  )
where

import Akyuu.Amend qualified as Amend
import Akyuu.Cache (Cache, SyncReport, closeCache, openCache)
import Akyuu.Cache qualified as Cache
import Akyuu.Check (CheckOptions, Finding)
import Akyuu.Check qualified as Check
import Akyuu.Compare (Comparison)
import Akyuu.Compare qualified as Compare
import Akyuu.Episode (Walk)
import Akyuu.Episode qualified as Episode
import Akyuu.Error (AkyuuError (AmbiguousPrefix, BadField, BadIdSpec, BadInput, CacheFailed, GCFailed, NoRoot, NoSuchPrefix, Pruned, RefFailed, RootMissing, StoreFailed), fromSupersede)
import Akyuu.GC (Policy, RunReport)
import Akyuu.GC qualified as GC
import Akyuu.Graph (Edge (Edge), EdgeType (DerivedFrom, Supersedes), Graph)
import Akyuu.Graph qualified as Graph
import Akyuu.Id (Id)
import Akyuu.Id qualified as Id
import Akyuu.Memory (Memory (memAgent, memBody, memEdges, memKind), MemoryError (InvalidField), MemoryParseError, mkMemory, validField)
import Akyuu.Query (Neighbour, SearchOptions, SearchResult)
import Akyuu.Query qualified as Query
import Akyuu.Refs (Expected, Name, Ref (current), RefError, Refs, openRefs)
import Akyuu.Refs qualified as Refs
import Akyuu.Review (Review (Review))
import Akyuu.Review qualified as Review
import Akyuu.Store (Store, StoreError (BadMemory, Corrupt, NotFound, StoreIO), openStore)
import Akyuu.Store qualified as Store
import Akyuu.Supersede (supersede, supersedeFrom)
import Akyuu.Tier (TierError (BadTierName, BadTierRef, NoColon), parseManifest, tierNames, tierRefs)
import Control.Exception (finally)
import Control.Monad (forM, forM_, unless)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Trans.Except (ExceptT (ExceptT), except, runExceptT, throwE, withExceptT)
import Data.Bifunctor (first)
import Data.Char (isDigit, isHexDigit)
import Data.Either (partitionEithers)
import Data.List (sort, sortOn)
import Data.Map.Strict qualified as Map
import Data.Maybe (catMaybes, fromMaybe)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (NominalDiffTime, UTCTime, getCurrentTime)
import System.Directory (doesDirectoryExist)

-- The environment ------------------------------------------------------

-- | An open store, with its refs and its cache.
data Env = Env
  { envStore :: Store,
    envRefs :: Refs,
    envCache :: Cache
  }

-- | Choose the root directory of the store. This function is pure.
--
-- The @--root@ option comes first, then the @AKYUU_ROOT@ variable. An empty
-- value counts as no value. There is no default directory: a wrong guess
-- would make a new, empty store in a place that the person did not choose.
resolveRoot :: Maybe FilePath -> Maybe String -> Either AkyuuError FilePath
resolveRoot opt env = case filter (not . null) (catMaybes [opt, env]) of
  (r : _) -> Right r
  [] -> Left NoRoot

-- | Open the store, the refs and the cache under a root, and run an action.
-- The cache is closed when the action ends, also if it throws.
--
-- The root directory must exist ('RootMissing'). The function makes the
-- directories inside it (@store@, @trash@, @refs@) if they are not there.
-- A typo in the root then gives an error, and not a new store.
withEnv :: FilePath -> (Env -> IO (Either AkyuuError a)) -> IO (Either AkyuuError a)
withEnv root act = do
  there <- doesDirectoryExist root
  if not there
    then pure (Left (RootMissing root))
    else do
      opened <- runExceptT $ do
        s <- withExceptT StoreFailed (ExceptT (openStore root))
        rs <- withExceptT RefFailed (ExceptT (openRefs root))
        c <- withExceptT CacheFailed (ExceptT (openCache root))
        pure (Env s rs c)
      case opened of
        Left e -> pure (Left e)
        Right env -> act env `finally` closeCache (envCache env)

-- New memories ---------------------------------------------------------

-- | What a person or an agent gives for a new memory. The time of creation
-- is not here: 'buildMemory' gets it.
data NewMemory = NewMemory
  { newKind :: Text,
    newAgent :: Text,
    newEdges :: Set Edge,
    newBody :: Text
  }
  deriving (Eq, Show)

-- | Check a value for the @kind@ or @agent@ header. The first argument is
-- the name of the header, for the error.
--
-- The value must not be empty, must have one line, and must have no white
-- space at either end. 'Akyuu.Memory.renderMemory' needs this, and does not
-- check it. A line feed in a kind would write a second header line.
--
-- The check is here, at the edge of the program, and not in "Akyuu.Memory".
-- The smart constructor for 'Memory' is still an open decision.
checkField :: Text -> Text -> Either AkyuuError Text
checkField header v
  | validField v = Right v
  | otherwise = Left (BadField header v)

-- | Make a memory, created at this time. This function is pure.
--
-- The time is cut to whole seconds, because 'Akyuu.Memory.renderMemory'
-- keeps whole seconds only. The memory then equals what the store reads
-- back.
buildMemory :: UTCTime -> NewMemory -> Either AkyuuError Memory
buildMemory t n =
  first (\(InvalidField h v) -> BadField h v) (mkMemory (newKind n) t (newAgent n) (newEdges n) (newBody n))

-- | 'buildMemory' at the time now.
buildNow :: NewMemory -> ExceptT AkyuuError IO Memory
buildNow n = do
  t <- liftIO getCurrentTime
  except (buildMemory t n)

-- Operations -----------------------------------------------------------

store :: IO (Either StoreError a) -> ExceptT AkyuuError IO a
store = withExceptT StoreFailed . ExceptT

refs :: IO (Either RefError a) -> ExceptT AkyuuError IO a
refs = withExceptT RefFailed . ExceptT

cache :: IO (Either Cache.CacheError a) -> ExceptT AkyuuError IO a
cache = withExceptT CacheFailed . ExceptT

gc :: IO (Either GC.GCError a) -> ExceptT AkyuuError IO a
gc = withExceptT GCFailed . ExceptT

-- | Add a new memory to the store, and return its 'Id'. No ref changes.
--
-- An edge can point at an 'Id' that is not in the store. The graph allows
-- that, so this function does not check it.
addMemory :: Env -> NewMemory -> IO (Either AkyuuError Id)
addMemory env n = runExceptT $ do
  m <- buildNow n
  store (Store.add (envStore env) m)

-- | The error for an 'Id' that is not in the store: 'Pruned' if GC left a
-- tombstone for it, or else 'NotFound'.
--
-- 'Pruned' also holds the memories that replace the deleted one
-- ('Akyuu.Query.resolve'). The graph comes from 'Akyuu.GC.snapshot', which
-- writes nothing, so a read-only caller can use this. If the graph cannot be
-- read, the set is empty and the error is still 'Pruned'.
missing :: Env -> Id -> ExceptT AkyuuError IO a
missing env i = do
  t <- gc (GC.lookupTombstone (envStore env) i)
  case t of
    Nothing -> throwE (StoreFailed (NotFound i))
    Just tomb -> do
      snap <- liftIO (GC.snapshot (envCache env) (envStore env))
      let successors = either (const Set.empty) (Query.resolve i . fst) snap
      throwE (Pruned i tomb successors)

-- | Read a memory, and check its hash ('Akyuu.Store.getVerified').
-- A memory that GC deleted gives 'Pruned'.
getMemory :: Env -> Id -> IO (Either AkyuuError Memory)
getMemory env i = runExceptT $ do
  r <- liftIO (Store.getVerified (envStore env) i)
  case r of
    Left (NotFound _) -> missing env i
    Left e -> throwE (StoreFailed e)
    Right m -> pure m

-- | Replace the memory of a ref with a new memory, and return its 'Id'.
--
-- With @Just old@, the ref must still point to @old@
-- ('Akyuu.Supersede.supersedeFrom'). Use it when the memory was written from
-- a read of @old@. With 'Nothing', the function reads the ref first
-- ('Akyuu.Supersede.supersede').
supersedeMemory :: Env -> Name -> Maybe Id -> NewMemory -> IO (Either AkyuuError Id)
supersedeMemory env n old new = runExceptT $ do
  m <- buildNow new
  withExceptT fromSupersede . ExceptT $ case old of
    Just o -> supersedeFrom (envStore env) (envRefs env) n o m
    Nothing -> supersede (envStore env) (envRefs env) n m

-- | Change the memory of a ref by edits to its body ('Akyuu.Amend'), and
-- return the new 'Id'. The kind, the agent and the edges of the old memory
-- stay, except the edges of kind supersedes, and the new memory replaces the
-- old one. With an agent, the new memory has that agent.
--
-- With @Just old@, the ref must point to @old@ now. With 'Nothing', the
-- function reads the ref and checks that it has not moved when it writes.
amendMemory :: Env -> Name -> Maybe Id -> Maybe Text -> [Amend.Edit] -> IO (Either AkyuuError Id)
amendMemory env n expected agent es = runExceptT $ do
  cur <- maybe (current <$> ExceptT (readRef env n)) pure expected
  m <- ExceptT (getMemory env cur)
  body <- either (throwE . BadInput . Amend.describeAmend) pure (Amend.applyEdits es (memBody m))
  let new =
        NewMemory
          { newKind = memKind m,
            newAgent = fromMaybe (memAgent m) agent,
            newEdges = Set.filter (\(Edge t _) -> t /= Supersedes) (memEdges m),
            newBody = body
          }
  ExceptT (supersedeMemory env n (Just cur) new)

-- | Read a ref.
readRef :: Env -> Name -> IO (Either AkyuuError Ref)
readRef env n = runExceptT (refs (Refs.getRef (envRefs env) n))

-- | Move a ref to an 'Id', with the check of 'Expected'.
--
-- "Akyuu.Refs" does not look at the store. This function does: the 'Id' must
-- be in the store, so that no ref points at nothing.
setRefTo :: Env -> Name -> Expected -> Id -> IO (Either AkyuuError Ref)
setRefTo env n ex i = runExceptT $ do
  there <- store (Store.exists (envStore env) i)
  unless there (missing env i)
  refs (Refs.setRef (envRefs env) n ex i)

-- | The names of all the refs, sorted.
listRefNames :: Env -> IO (Either AkyuuError [Name])
listRefNames env = runExceptT (sortOn Refs.nameText <$> refs (Refs.listRefs (envRefs env)))

-- | All the refs with the 'Id' that each one points to now, sorted by name.
--
-- A ref that is not valid (a damaged file) is an error for the whole list,
-- like 'readRef'. The person then knows that something is wrong, and not
-- only that one line is missing.
listRefValues :: Env -> IO (Either AkyuuError [(Name, Id)])
listRefValues env = runExceptT $ do
  names <- ExceptT (listRefNames env)
  forM names $ \n -> (,) n . current <$> ExceptT (readRef env n)

-- | The first line of the body of each memory, cut to 80 characters. A memory
-- that cannot be read has no entry: this is for a list, which must not fail
-- for one bad memory.
firstLines :: Env -> [Id] -> IO (Map.Map Id Text)
firstLines env is = do
  rs <- forM (Set.toList (Set.fromList is)) $ \i -> do
    r <- getMemory env i
    pure (either (const []) (\m -> [(i, cut (memBody m))]) r)
  pure (Map.fromList (concat rs))
  where
    cut b = case filter (not . T.null) (map T.strip (T.lines b)) of
      (l : _) | T.length l > 80 -> T.take 79 l <> "…"
      (l : _) -> l
      [] -> ""

-- | Pin a memory, so that GC keeps it. Pinning twice is the same as once.
--
-- "Akyuu.GC" allows a pin for an object that is not in the store. This
-- function does not: the person gave an id, and an id that nothing has is
-- most likely a typo. It gives the same error as 'setRefTo'.
pinMemory :: Env -> Id -> IO (Either AkyuuError ())
pinMemory env i = runExceptT $ do
  there <- store (Store.exists (envStore env) i)
  unless there (missing env i)
  gc (GC.pin (envStore env) i)

-- | Remove a pin. An id that is not pinned is not an error. The memory does
-- not have to be in the store, so a person can remove the pin of a memory
-- that GC deleted.
unpinMemory :: Env -> Id -> IO (Either AkyuuError ())
unpinMemory env i = runExceptT (gc (GC.unpin (envStore env) i))

-- | All the pinned ids, sorted.
listPinned :: Env -> IO (Either AkyuuError [Id])
listPinned env = runExceptT (Set.toAscList <$> gc (GC.listPins (envStore env)))

-- Ids that a person typed --------------------------------------------------

-- | An 'Id' as a person gives it: the whole thing, or the start of one.
data IdSpec
  = -- | A whole, valid 'Id'. It needs no look at the store.
    Full Id
  | -- | The start of an 'Id' in the text form: @sha256-@ and some hex
    -- digits. 'resolveId' finds the one memory that it belongs to.
    Prefix Text
  deriving (Eq, Show)

-- | The shortest prefix that 'parseIdSpec' accepts, in hex digits. A shorter
-- prefix would match many memories, and a typo would too easily name the
-- wrong one.
minPrefix :: Int
minPrefix = 4

-- | Read the text of an 'Id' that a person typed. This function is pure.
--
-- A whole 'Id' (@sha256-@ and 64 hex digits) is 'Full'. Otherwise the text
-- is a prefix. The @sha256-@ at the start is optional, so @08d4@ and
-- @sha256-08d4@ are the same prefix. The prefix needs at least 'minPrefix'
-- hex digits. Upper case is read as lower case.
--
-- Anything else is 'BadIdSpec'.
parseIdSpec :: Text -> Either AkyuuError IdSpec
parseIdSpec t = case Id.parse t of
  Right i -> Right (Full i)
  Left _
    | T.length digits >= minPrefix && T.length digits < 64 && T.all isHexDigit digits ->
        Right (Prefix ("sha256-" <> digits))
    | otherwise -> Left (BadIdSpec t)
  where
    digits = T.toLower (fromMaybe t (T.stripPrefix "sha256-" t))

-- | Find the 'Id' that a person meant.
--
-- A 'Full' id is returned as it is: the store is not asked, so a memory that
-- GC deleted still gives its own error ('Pruned') at the next step. A
-- 'Prefix' is matched against the memories that are in the store now.
-- Returns 'NoSuchPrefix' if none matches, and 'AmbiguousPrefix' (with the
-- first five matches) if more than one does.
resolveId :: Env -> IdSpec -> IO (Either AkyuuError Id)
resolveId _ (Full i) = pure (Right i)
resolveId env (Prefix p) = runExceptT $ do
  ids <- store (Store.list (envStore env))
  case sort (filter (T.isPrefixOf p . Id.render) ids) of
    [] -> throwE (NoSuchPrefix p)
    [i] -> pure i
    is -> throwE (AmbiguousPrefix p (take 5 is))

-- | Read a length of time as a person types it: a whole number and a unit,
-- like @30m@, @1h@ or @7d@. The units are @s@, @m@, @h@ and @d@.
-- This function is pure.
--
-- The unit is not optional, so @30@ is an error and not a guess.
parseDuration :: Text -> Either AkyuuError NominalDiffTime
parseDuration t = case T.span isDigit t of
  (ds, u)
    | not (T.null ds),
      Just k <- lookup u units ->
        Right (fromInteger (read (T.unpack ds)) * k)
  _ -> Left (BadInput (quote t <> " is not a length of time. Use a number and a unit: s, m, h or d, for example 30m, 1h or 7d."))
  where
    units = [("s", 1), ("m", 60), ("h", 3600), ("d", 86400)]
    quote x = "'" <> x <> "'"

-- | Make the cache match the store.
synced :: Env -> ExceptT AkyuuError IO ()
synced env = () <$ cache (Cache.sync (envCache env) (envStore env))

-- | Search the memories ('Akyuu.Query.search'), after a sync of the cache.
searchMemories :: Env -> SearchOptions -> Text -> IO (Either AkyuuError SearchResult)
searchMemories env o q = runExceptT $ do
  synced env
  t <- liftIO (searchTuning env)
  cache (Query.searchWith (envCache env) t o q)

-- | How a search of this store forgives and ranks: fuzzy on, a memory that a
-- ref holds ranks higher, and a newer one ranks higher. If the refs cannot be
-- read, the ranking does not use them: a search must not fail for that.
searchTuning :: Env -> IO Query.Tuning
searchTuning env = do
  now <- getCurrentTime
  held <- either (const Set.empty) (Set.fromList . map snd) <$> listRefValues env
  pure Query.defaultTuning {Query.tuneBoost = Query.Boost {Query.boostNow = Just now, Query.boostHeld = held}}

-- | The edges of a memory ('Akyuu.Query.neighbourList'), after a sync of
-- the cache.
--
-- An 'Id' that is not a memory and that no edge points at gives an error
-- ('NotFound' or 'Pruned'), and not an empty list. A dangling target that
-- some memory points at gives its edges.
neighboursOf :: Env -> Id -> IO (Either AkyuuError [Neighbour])
neighboursOf env i = runExceptT $ do
  synced env
  g <- cache (Cache.loadGraph (envCache env))
  let ns = Query.neighbourList i g
  if null ns && not (i `Set.member` Graph.nodes g)
    then missing env i
    else pure ns

-- | The plan of a GC run now, with this policy. This writes nothing.
dryRunGC :: Env -> Policy -> IO (Either AkyuuError (Set Id))
dryRunGC env p = runExceptT (gc (GC.dryRun (envCache env) (envStore env) (envRefs env) p Set.empty))

-- | One whole GC run now, with this policy ('Akyuu.GC.collect').
runGC :: Env -> Policy -> IO (Either AkyuuError RunReport)
runGC env p = runExceptT $ do
  r <- gc (GC.collect (envCache env) (envStore env) (envRefs env) p Set.empty)
  -- A review of a memory that is gone has no use. A failure here is not a
  -- failure of the run: the files stay and the next run tries again.
  present <- liftIO (Store.list (envStore env))
  _ <- liftIO (either (const (pure (Right []))) (Review.prune (envStore env) . Set.fromList) present)
  pure r

-- | Throw the cache away and read the whole store again.
reindexCache :: Env -> IO (Either AkyuuError SyncReport)
reindexCache env = runExceptT (cache (Cache.reindex (envCache env) (envStore env)))

-- Verify ---------------------------------------------------------------

-- | What 'verifyStore' found. Each list is sorted.
data VerifyReport = VerifyReport
  { -- | How many objects the store has.
    checkedObjects :: Int,
    -- | Objects whose content does not hash to their name.
    corruptObjects :: [Id],
    -- | Objects that hash right but are not valid memories.
    unreadableObjects :: [(Id, MemoryParseError)],
    -- | Targets of edges that are not in the store and have no tombstone.
    -- This means damage.
    missingTargets :: [Id],
    -- | Targets of edges that GC deleted. This is normal: a newer memory
    -- keeps its edge to an old one after GC.
    prunedTargets :: [Id],
    -- | Refs that cannot be read.
    badRefs :: [(Name, RefError)],
    -- | Refs whose current value is not in the store.
    refsToMissing :: [(Name, Id)]
  }
  deriving (Eq, Show)

-- | Is the store sound? Pruned targets are normal, so they do not count.
verifyOk :: VerifyReport -> Bool
verifyOk r =
  null (corruptObjects r)
    && null (unreadableObjects r)
    && null (missingTargets r)
    && null (badRefs r)
    && null (refsToMissing r)

-- | Check the whole store: every object, every edge and every ref.
--
-- The function reads and hashes each object ('Akyuu.Store.getVerified'). It
-- builds the graph from the objects that it read, and not from the cache, so
-- a damaged cache cannot hide a problem. An object that GC moves away during
-- the check is skipped. The function is slow on a big store.
verifyStore :: Env -> IO (Either AkyuuError VerifyReport)
verifyStore env = runExceptT $ do
  let s = envStore env
  ids <- store (Store.list s)
  results <- liftIO (traverse (\i -> (,) i <$> Store.getVerified s i) ids)
  let (bad, good) = partitionEithers (map classify results)
      g = foldMap nodeGraph good :: Graph
      corrupt = [i | (i, Corrupt _) <- bad]
      unreadable = [(i, p) | (i, BadMemory _ p) <- bad]
      others = [e | (_, e) <- bad, not (isKnown e)]
  case others of
    (e : _) -> throwE (StoreFailed e)
    [] -> pure ()
  tombs <- traverse (\i -> (,) i <$> gc (GC.lookupTombstone s i)) (Set.toAscList (Graph.dangling g `Set.difference` Set.fromList ids))
  names <- refs (Refs.listRefs (envRefs env))
  refResults <- liftIO (traverse (\n -> (,) n <$> Refs.getRef (envRefs env) n) names)
  let badR = [(n, e) | (n, Left e) <- refResults]
  toMissing <-
    catMaybes
      <$> traverse
        ( \(n, r) -> do
            there <- store (Store.exists s (current r))
            pure (if there then Nothing else Just (n, current r))
        )
        [(n, r) | (n, Right r) <- refResults]
  pure
    VerifyReport
      { checkedObjects = length ids,
        corruptObjects = sort corrupt,
        unreadableObjects = sortOn fst unreadable,
        missingTargets = [i | (i, Nothing) <- tombs],
        prunedTargets = [i | (i, Just _) <- tombs],
        badRefs = sortOn (Refs.nameText . fst) badR,
        refsToMissing = sortOn (Refs.nameText . fst) toMissing
      }
  where
    -- A vanished object (GC moved it) is neither good nor bad.
    classify (i, Left e) = case e of
      NotFound _ -> Right Nothing
      _ -> Left (i, e)
    classify (i, Right m) = Right (Just (i, m))
    -- The node is the name of the file, as in Cache.sync. A damaged object is
    -- in the store but is not a node, so the dangling set leaves it out.
    nodeGraph Nothing = mempty
    nodeGraph (Just (i, m)) = Graph.singleton i (Set.toList (memEdges m))
    isKnown (Corrupt _) = True
    isKnown (BadMemory _ _) = True
    isKnown _ = False

-- Check ----------------------------------------------------------------

-- | The findings of 'Akyuu.Check.check' for this store.
--
-- It writes nothing, and it does not sync the cache: the graph comes from
-- 'Akyuu.GC.snapshot', which adds the objects that the cache lacks. The
-- bodies come from the store. An object that cannot be read is left out of
-- the bodies, so no text check sees it: 'verifyStore' reports it. The roots
-- are the refs and pins, with the default number of generations.
checkStore :: Env -> CheckOptions -> IO (Either AkyuuError [Finding])
checkStore env o = runExceptT $ do
  let s = envStore env
  (g, _) <- gc (GC.snapshot (envCache env) s)
  roots <- gc (GC.readRoots GC.defaultPolicy (envRefs env) s)
  judged <- either (const []) (map fst) <$> liftIO (Review.listReviews s)
  bodies <- liftIO (traverse (\i -> fmap ((,) i . memBody) . either (const Nothing) Just <$> Store.get s i) (Set.toAscList (Graph.nodes g)))
  pure (Check.check o (Check.Inputs g (Map.fromList (catMaybes bodies)) roots (Set.fromList judged)))

-- Compare --------------------------------------------------------------

-- | One memory in a comparison: the memory and the refs that point at it now.
data CompareSide = CompareSide
  { sideId :: Id,
    sideMemory :: Memory,
    sideRefs :: [Name]
  }
  deriving (Eq, Show)

-- | Two memories, and what each one says that the other one lacks.
data CompareReport = CompareReport
  { crFirst :: CompareSide,
    crSecond :: CompareSide,
    crResult :: Comparison
  }
  deriving (Eq, Show)

-- | Read two memories and compare their text ('Akyuu.Compare.compareText').
--
-- It reads and checks both memories ('getMemory'), so a memory that GC
-- deleted gives 'Pruned' with the memories that replace it. It writes
-- nothing and does not sync the cache. The refs are the current values.
compareMemories :: Env -> Id -> Id -> IO (Either AkyuuError CompareReport)
compareMemories env a b = runExceptT $ do
  ma <- ExceptT (getMemory env a)
  mb <- ExceptT (getMemory env b)
  named <- ExceptT (listRefValues env)
  let held i = sort [n | (n, x) <- named, x == i]
  pure
    CompareReport
      { crFirst = CompareSide a ma (held a),
        crSecond = CompareSide b mb (held b),
        crResult = Compare.compareText (memBody ma) (memBody mb)
      }

-- Reviews --------------------------------------------------------------

-- | Record that two memories are different, and that both are true
-- ('Akyuu.Review.review'). @check@ then leaves the pair out.
--
-- Both memories must be in the store, like a pin: an id that nothing has is
-- most likely a typo. The agent is the name of who judged. The note can be
-- empty.
reviewPair :: Env -> Id -> Id -> Text -> Text -> IO (Either AkyuuError ())
reviewPair env a b agent note = runExceptT $ do
  _ <- either throwE pure (checkField "agent" agent)
  unless (a /= b) (throwE (BadInput "A memory cannot be different from itself. Give two ids."))
  forM_ [a, b] $ \i -> do
    there <- store (Store.exists (envStore env) i)
    unless there (missing env i)
  now <- liftIO getCurrentTime
  r <- liftIO (Review.review (envStore env) a b (Review agent now (T.strip note)))
  withExceptT (StoreFailed . StoreIO) (except r)

-- | Remove the review of a pair. A pair that is not reviewed is not an error.
unreviewPair :: Env -> Id -> Id -> IO (Either AkyuuError ())
unreviewPair env a b = runExceptT $ do
  r <- liftIO (Review.unreview (envStore env) a b)
  withExceptT (StoreFailed . StoreIO) (except r)

-- | Every reviewed pair, sorted.
listReviewed :: Env -> IO (Either AkyuuError [(Review.Pair, Review)])
listReviewed env = runExceptT $ do
  r <- liftIO (Review.listReviews (envStore env))
  withExceptT (StoreFailed . StoreIO) (except r)

-- Context --------------------------------------------------------------

-- | One ref of a tier, as @context@ shows it.
data ContextEntry
  = -- | The ref, the memory that it points at now, and the memory.
    Present Name Id Memory
  | -- | The manifest names the ref, and the store has no such ref.
    Absent Name
  deriving (Eq, Show)

-- | What a session reads at the start: the memories of a tier and of the
-- refs that the caller asked for, and the names of the other refs.
data ContextReport = ContextReport
  { ctxTier :: Text,
    ctxEntries :: [ContextEntry],
    -- | The refs that are in no entry. They tell an agent what else it can read.
    ctxOthers :: [Name]
  }
  deriving (Eq, Show)

-- | The context of a tier ('Akyuu.Tier').
--
-- The manifest is the memory that the first ref points at. The tier is a name
-- in it. The extra refs come after the refs of the tier, and a ref that is in
-- both comes once. A ref that does not exist gives 'Absent': one stale name
-- must not hide the other memories. A manifest that is missing or invalid,
-- and a tier that it does not have, are errors, with a text that says what
-- to do. It writes nothing and does not sync the cache.
contextFor :: Env -> Name -> Text -> [Name] -> IO (Either AkyuuError ContextReport)
contextFor env manifestRef tier extra = runExceptT $ do
  mref <- ExceptT (readRef env manifestRef)
  m <- ExceptT (getMemory env (current mref))
  manifest <- either (throwE . BadInput . manifestError) pure (parseManifest (memBody m))
  names <- case tierRefs tier manifest of
    Just rs -> pure rs
    Nothing ->
      throwE . BadInput $
        "There is no tier " <> quoted tier <> " in the manifest. It has: " <> T.intercalate ", " (tierNames manifest) <> "."
  all' <- ExceptT (listRefValues env)
  let wanted = nubOrd (names <> extra)
      held = Map.fromList all'
  entries <- forM wanted $ \n -> case Map.lookup n held of
    Nothing -> pure (Absent n)
    Just i -> do
      mem <- ExceptT (getMemory env i)
      pure (Present n i mem)
  pure ContextReport {ctxTier = tier, ctxEntries = entries, ctxOthers = [n | (n, _) <- all', n `notElem` wanted, n /= manifestRef]}
  where
    quoted t = "'" <> t <> "'"
    nubOrd = go Set.empty
      where
        go _ [] = []
        go seen (x : xs)
          | x `Set.member` seen = go seen xs
          | otherwise = x : go (Set.insert x seen) xs
    manifestError e = case e of
      NoColon n l -> "The manifest has no ':' on line " <> T.pack (show n) <> ": " <> quoted l <> "."
      BadTierName n l -> "The manifest has a bad tier name on line " <> T.pack (show n) <> ": " <> quoted l <> "."
      BadTierRef n r _ -> "The manifest has a bad ref name on line " <> T.pack (show n) <> ": " <> quoted r <> "."

-- Episodes -------------------------------------------------------------

-- | Append an episode to the log that a ref names ('Akyuu.Episode.append').
-- A ref that does not exist starts a log. The new memory gets a
-- @derived_from@ edge to the newest episode, and the ref moves to it.
--
-- The memory must not have a @derived_from@ edge: that edge is the link of
-- the chain. Use @about@ or @refines@ to link an episode to something else.
appendEpisode :: Env -> Name -> NewMemory -> IO (Either AkyuuError Id)
appendEpisode env n nm = runExceptT $ do
  let linked = [() | Edge k _ <- Set.toList (newEdges nm), k == DerivedFrom]
  unless (null linked) (throwE (BadInput "An episode links to the one before it with derived_from, and append adds that edge. Use about or refines for other links."))
  m <- buildNow nm
  withExceptT fromSupersede (ExceptT (Episode.append (envStore env) (envRefs env) n m))

-- | Read a log, newest episode first, up to a limit of episodes
-- ('Akyuu.Episode.walk'). A ref that does not exist is an error.
readLog :: Env -> Name -> Int -> IO (Either AkyuuError Walk)
readLog env n limit = runExceptT $ do
  ref <- ExceptT (readRef env n)
  liftIO (Episode.walk (envStore env) limit (current ref))
