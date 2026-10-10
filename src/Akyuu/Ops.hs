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
    supersedeMemory,
    readRef,
    setRefTo,
    listRefNames,
    listRefValues,
    IdSpec (..),
    parseIdSpec,
    resolveId,
    searchMemories,
    neighboursOf,
    dryRunGC,
    runGC,
    reindexCache,

    -- * Verify
    VerifyReport (..),
    verifyOk,
    verifyStore,
  )
where

import Akyuu.Cache (Cache, SyncReport, closeCache, openCache)
import Akyuu.Cache qualified as Cache
import Akyuu.Error (AkyuuError (..), fromSupersede)
import Akyuu.GC (RunReport, defaultPolicy)
import Akyuu.GC qualified as GC
import Akyuu.Graph (Edge, Graph)
import Akyuu.Graph qualified as Graph
import Akyuu.Id (Id)
import Akyuu.Id qualified as Id
import Akyuu.Memory (Memory (..), MemoryParseError)
import Akyuu.Query (Neighbour, SearchOptions, SearchResult)
import Akyuu.Query qualified as Query
import Akyuu.Refs (Expected, Name, Ref (..), RefError, Refs, openRefs)
import Akyuu.Refs qualified as Refs
import Akyuu.Store (Store, StoreError (..), openStore)
import Akyuu.Store qualified as Store
import Akyuu.Supersede (supersede, supersedeFrom)
import Control.Exception (finally)
import Control.Monad (forM, unless)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Trans.Except (ExceptT (ExceptT), except, runExceptT, throwE, withExceptT)
import Data.Char (isHexDigit, isSpace)
import Data.Either (partitionEithers)
import Data.List (sort, sortOn)
import Data.Maybe (catMaybes, fromMaybe)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime, getCurrentTime)
import Data.Time.Clock.POSIX (posixSecondsToUTCTime, utcTimeToPOSIXSeconds)
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
  | T.null v = bad
  | T.any (`elem` ['\n', '\r']) v = bad
  | isSpace (T.head v) || isSpace (T.last v) = bad
  | otherwise = Right v
  where
    bad = Left (BadField header v)

-- | Make a memory, created at this time. This function is pure.
--
-- The time is cut to whole seconds, because 'Akyuu.Memory.renderMemory'
-- keeps whole seconds only. The memory then equals what the store reads
-- back.
buildMemory :: UTCTime -> NewMemory -> Either AkyuuError Memory
buildMemory t n = do
  k <- checkField "kind" (newKind n)
  a <- checkField "agent" (newAgent n)
  pure
    Memory
      { memKind = k,
        memCreated = wholeSeconds t,
        memAgent = a,
        memEdges = newEdges n,
        memBody = newBody n
      }
  where
    wholeSeconds = posixSecondsToUTCTime . fromInteger . floor . utcTimeToPOSIXSeconds

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
missing :: Env -> Id -> ExceptT AkyuuError IO a
missing env i = do
  t <- gc (GC.lookupTombstone (envStore env) i)
  throwE (maybe (StoreFailed (NotFound i)) (Pruned i) t)

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

-- | Make the cache match the store.
synced :: Env -> ExceptT AkyuuError IO ()
synced env = () <$ cache (Cache.sync (envCache env) (envStore env))

-- | Search the memories ('Akyuu.Query.search'), after a sync of the cache.
searchMemories :: Env -> SearchOptions -> Text -> IO (Either AkyuuError SearchResult)
searchMemories env o q = runExceptT $ do
  synced env
  cache (Query.search (envCache env) o q)

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

-- | The plan of a GC run now, with 'defaultPolicy'. This writes nothing.
dryRunGC :: Env -> IO (Either AkyuuError (Set Id))
dryRunGC env = runExceptT (gc (GC.dryRun (envCache env) (envStore env) (envRefs env) defaultPolicy Set.empty))

-- | One whole GC run now, with 'defaultPolicy' ('Akyuu.GC.collect').
runGC :: Env -> IO (Either AkyuuError RunReport)
runGC env = runExceptT (gc (GC.collect (envCache env) (envStore env) (envRefs env) defaultPolicy Set.empty))

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
