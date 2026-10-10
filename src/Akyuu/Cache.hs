-- | The cache: a disposable SQLite index of the store.
--
-- The store holds the truth. The cache holds only facts that can be read
-- from the store again: which memories exist, which edges they have, and a
-- full-text index of their bodies. If the cache file is lost, damaged or out
-- of date, delete it and call 'sync'. Nothing is lost.
--
-- Objects never change, so the cache never updates a row. It adds the rows
-- of a new object ('index') and removes the rows of a swept object
-- ('forget'). 'sync' does both, to make the cache match the store.
--
-- The file is @cache.sqlite@ in the root directory of the store, next to
-- @store/@ and @refs/@ (see 'cachePath').
--
-- Tables (schema version 'schemaVersion'):
--
-- > memories (rowid INTEGER PRIMARY KEY, id TEXT UNIQUE NOT NULL,
-- >           kind TEXT NOT NULL, created TEXT NOT NULL, agent TEXT NOT NULL)
-- > edges    (src TEXT NOT NULL, kind TEXT NOT NULL, dst TEXT NOT NULL,
-- >           PRIMARY KEY (src, kind, dst)) WITHOUT ROWID
-- > bodies   USING fts5(body, tokenize = 'porter unicode61')
--
-- * @memories.id@ and @edges.src@ and @edges.dst@ hold the text form of an
--   'Id'. @edges.kind@ holds the header name of the kind, from
--   'Akyuu.Memory.edgeToHeader'.
-- * @edges.dst@ has no foreign key. An edge can point to an 'Id' that is not
--   in the store. The graph allows such a /dangling/ target.
-- * A memory without edges has a @memories@ row and no @edges@ rows. The
--   graph needs the row, to keep the memory as a node.
-- * @bodies.rowid@ is @memories.rowid@. The table holds a copy of the body.
--
-- The rules of the cache:
--
-- * A change is one transaction. A call that fails changes nothing.
-- * The cache does not trust itself. If the file is not a database, or its
--   @PRAGMA user_version@ is not 'schemaVersion', 'openCache' deletes the
--   file and starts again with an empty cache. There are no migrations.
-- * The cache does not touch the store. It only reads it.
--
-- Functions return @IO (Either CacheError a)@. A caller never has to catch
-- an exception from this module.
module Akyuu.Cache
  ( -- * The cache
    Cache,
    openCache,
    closeCache,
    cachePath,
    schemaVersion,

    -- * Errors
    CacheError (..),

    -- * Rows
    index,
    forget,
    cachedIds,

    -- * Keeping up with the store
    SyncReport (..),
    sync,
    reindex,

    -- * Queries
    loadGraph,
    Hit (..),
    search,
    ftsQuery,
  )
where

import Akyuu.Fs (ignoreIO, tryAs)
import Akyuu.Graph (Edge (..), EdgeType, Graph)
import Akyuu.Graph qualified as Graph
import Akyuu.Id (Id, parse, render)
import Akyuu.Memory (Memory (..), edgeToHeader)
import Akyuu.Store (Store, StoreError)
import Akyuu.Store qualified as Store
import Control.Exception (IOException, bracketOnError, onException, try)
import Control.Monad (forM_, when)
import Control.Monad.Trans.Except (ExceptT (ExceptT), runExceptT, withExceptT)
import Data.Bifunctor (first)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Database.SQLite.Simple
  ( Connection,
    Only (Only),
    Query (Query),
    SQLError,
    close,
    execute,
    execute_,
    fromOnly,
    lastInsertRowId,
    open,
    query,
    query_,
    withTransaction,
  )
import System.Directory (removeFile)
import System.FilePath ((</>))

-- | An open cache. The value holds the connection to the database, so
-- 'closeCache' it when you are done.
newtype Cache = Cache Connection

-- | Why a cache function failed.
data CacheError
  = -- | SQLite gave an error.
    CacheSQL SQLError
  | -- | The disk gave an error, for example when the file cannot be made or
    -- deleted.
    CacheIO IOException
  | -- | 'sync' could not read an object of the store. The cache did not change.
    CacheStore StoreError
  | -- | A row of the cache is not what the cache wrote, for example an @id@
    -- that is not an 'Id'. The text says which row. Delete the cache and call
    -- 'sync' again.
    CorruptCache Text
  deriving (Eq, Show)

-- | The version of the schema. It is stored as @PRAGMA user_version@. Change
-- this number whenever a table changes. The next 'openCache' then deletes
-- the old file and starts again.
schemaVersion :: Int
schemaVersion = 1

-- | The path of the cache file for a store: @\<root\>/cache.sqlite@.
-- The root is the directory that 'Akyuu.Store.openStore' gets.
--
-- This function is pure: it does not look at the disk.
cachePath :: FilePath -> FilePath
cachePath root = root </> "cache.sqlite"

-- | Make the tables of the cache, and set the options of the connection.
--
-- The tables are @memories@, @edges@ and @bodies@. The header of this module
-- shows their columns. Each @CREATE@ has @IF NOT EXISTS@, so it is safe to
-- call this function on a database that has them already.
--
-- The function also turns on WAL mode and a busy timeout of 5 seconds. The
-- timeout belongs to the connection and is not saved in the file, so each new
-- connection must set it.
--
-- The user version is the last step. After a crash in the middle, the version
-- is still 0, and the next 'openCache' throws the half-made file away.
createSchema :: Connection -> IO ()
createSchema c = do
  execute_ c "PRAGMA busy_timeout = 5000"
  execute_ c "CREATE TABLE IF NOT EXISTS edges (src TEXT NOT NULL, kind TEXT NOT NULL, dst TEXT NOT NULL, PRIMARY KEY (src, kind, dst)) WITHOUT ROWID"
  execute_ c "CREATE TABLE IF NOT EXISTS memories (rowid INTEGER PRIMARY KEY, id TEXT UNIQUE NOT NULL, kind TEXT NOT NULL, created TEXT NOT NULL, agent TEXT NOT NULL)"
  execute_ c "CREATE VIRTUAL TABLE IF NOT EXISTS bodies USING fts5(body, tokenize = 'porter unicode61')"
  execute_ c "PRAGMA journal_mode = WAL"
  execute_ c (Query $ T.pack ("PRAGMA user_version =" ++ show schemaVersion))

-- | Try to use the cache file that is already there.
--
-- Returns the open connection if the file is a database and its user version
-- is 'schemaVersion'. Returns 'Nothing' in every other case: the file does not
-- exist, it is not a database, or it has another version. At the moment any
-- 'SQLError' counts as "not usable".
--
-- The function closes the connection in each case that returns 'Nothing', and
-- also if an error ends it. The caller closes the connection of a 'Just'.
tryExisting :: FilePath -> IO (Maybe Connection)
tryExisting path =
  either (const Nothing) id
    <$> try @SQLError
      ( bracketOnError (open path) close $ \conn -> do
          [Only v] <- query_ conn "PRAGMA user_version" :: IO [Only Int]
          if v == schemaVersion
            then pure (Just conn)
            else close conn >> pure Nothing
      )

-- | Open the cache of a store. Make the file and the tables if they are not
-- there.
--
-- If the file exists but is not a usable cache, delete it and make a new one.
-- That is the case if the file is not a database, or if its user version is
-- not 'schemaVersion'. The result is then an empty cache, and 'sync' fills it.
--
-- The function also turns on the options for many agents at once: WAL mode
-- and a busy timeout. See the notes in @TODO.md@.
--
-- Returns 'CacheIO' or 'CacheSQL' if the file cannot be made, for example if
-- the directory does not exist.
openCache :: FilePath -> IO (Either CacheError Cache)
openCache root = tryAs CacheSQL $ do
  let path = cachePath root
  conn <- maybe (fresh path) pure =<< tryExisting path
  (createSchema conn) `onException` close conn
  pure (Cache conn)
  where
    fresh path = do
      mapM_ (ignoreIO . removeFile) [path, path ++ "-wal", path ++ "-shm"]
      open path

-- | Close the cache. Do not use the 'Cache' after this call.
closeCache :: Cache -> IO ()
closeCache (Cache conn) = close conn

-- | Add a memory to the cache: its row, its edges and its body.
--
-- The 'Id' is the name of the object in the store. 'sync' passes the name that
-- it read from the file, and not a new hash of the content.
--
-- If the 'Id' is already in the cache, the function does nothing. An object
-- never changes, so there is nothing to update. It is one transaction.
index :: Cache -> Id -> Memory -> IO (Either CacheError ())
index (Cache c) i m = tryAs CacheSQL $ withTransaction c $ insertMemory c i m

-- | Write the three kinds of rows of a memory: the @memories@ row, one
-- @edges@ row for each edge, and the @bodies@ row. If the 'Id' is already in
-- @memories@, write nothing.
--
-- This function does not start a transaction. 'index' and 'sync' put it in
-- one, so that several memories can share one transaction.
insertMemory :: Connection -> Id -> Memory -> IO ()
insertMemory c i m = do
  present <- query c "SELECT 1 FROM memories WHERE id = ?" (Only (render i)) :: IO [Only Int]
  when (null present) $ do
    execute
      c
      "INSERT INTO memories (id, kind, created, agent) VALUES (?,?,?,?)"
      (render i, memKind m, memCreated m, memAgent m)
    -- The body goes in the row with the same rowid as the @memories@ row.
    rowid <- lastInsertRowId c
    forM_ (Set.toList (memEdges m)) $ \e ->
      execute
        c
        "INSERT INTO edges (src, kind, dst) VALUES (?,?,?)"
        (render i, edgeToHeader (kind e), render (target e))
    execute c "INSERT INTO bodies (rowid, body) VALUES (?,?)" (rowid, memBody m)

-- | Delete the three kinds of rows of a memory: its body, the edges that start
-- at it, and its @memories@ row.
--
-- The order matters. The body is found through the @memories@ row, so that
-- row goes last. Edges of other memories that point to this 'Id' stay. If the
-- 'Id' is not in the cache, the function deletes nothing.
--
-- This function does not start a transaction. 'forget' and 'sync' put it in
-- one.
deleteMemory :: Connection -> Id -> IO ()
deleteMemory c i = do
  execute c "DELETE FROM bodies WHERE rowid = (SELECT rowid FROM memories WHERE id = ?)" (i')
  execute c "DELETE FROM edges WHERE src = ?" (i')
  execute c "DELETE FROM memories WHERE id = ?" (i')
  where
    i' = Only $ render i

-- | Remove a memory from the cache: its row, the edges that start at it and
-- its body.
--
-- Edges of other memories that point /to/ this 'Id' stay. They are dangling
-- targets now, and the graph allows that. If the 'Id' is not in the cache,
-- the function does nothing. It is one transaction.
forget :: Cache -> Id -> IO (Either CacheError ())
forget (Cache c) i = tryAs CacheSQL $ withTransaction c $ deleteMemory c i

-- | The 'Id' of every memory in the cache.
cachedIds :: Cache -> IO (Either CacheError (Set Id))
cachedIds (Cache c) = do
  rows <- tryAs CacheSQL (query_ c "SELECT id FROM memories" :: IO [Only Text])
  pure (rows >>= fmap Set.fromList . traverse (parseCached . fromOnly))

-- | What 'sync' changed. The order of each list is not defined.
data SyncReport = SyncReport
  { -- | The memories that the store had and the cache did not.
    added :: [Id],
    -- | The memories that the cache had and the store did not.
    removed :: [Id]
  }
  deriving (Eq, Show)

-- | Compare what the store has with what the cache has. This function is pure.
--
-- @diff want have@ puts in 'added' each 'Id' that is in @want@ and not in
-- @have@. It puts in 'removed' each 'Id' that is in @have@ and not in @want@.
-- No 'Id' is in both lists.
diff :: Set Id -> Set Id -> SyncReport
diff tgt cur =
  SyncReport
    { added = Set.toList x,
      removed = Set.toList y
    }
  where
    x = tgt `Set.difference` cur
    y = cur `Set.difference` tgt

-- | Make the cache match the store.
--
-- The function compares 'Akyuu.Store.list' with 'cachedIds'. It reads and
-- indexes each object that the cache does not have, and forgets each memory
-- that the store does not have. It does not open an object that the cache
-- already has, so a call on a cache that is up to date reads only file names.
--
-- All of this is one transaction. If the store cannot be read, or an object
-- is not a valid memory, the result is 'CacheStore' and the cache does not
-- change. Call it again after the problem is fixed.
sync :: Cache -> Store -> IO (Either CacheError SyncReport)
sync cache@(Cache c) st = runExceptT $ do
  ids <- withExceptT CacheStore (ExceptT (Store.list st))
  have <- ExceptT (cachedIds cache)
  let report = diff (Set.fromList ids) have
  new <- withExceptT CacheStore (traverse (\i -> (,) i <$> ExceptT (Store.get st i)) (added report))
  ExceptT $ tryAs CacheSQL $ withTransaction c $ do
    forM_ new $ \(i, m) -> insertMemory c i m
    forM_ (removed report) (deleteMemory c)
  pure report

-- | Delete every row of the three tables. The tables stay.
--
-- This function does not start a transaction. 'reindex' puts it in one.
clearAll :: Connection -> IO ()
clearAll c = do
  execute_ c "DELETE FROM bodies;"
  execute_ c "DELETE FROM edges;"
  execute_ c "DELETE FROM memories;"

-- | Throw away everything in the cache, then 'sync'. Use it if the cache
-- might be wrong, for example after a change in the code that reads memories.
-- The report lists every memory of the store in 'added'.
reindex :: Cache -> Store -> IO (Either CacheError SyncReport)
reindex cache@(Cache c) s = runExceptT $ do
  ExceptT $ tryAs CacheSQL (withTransaction c $ clearAll c)
  ExceptT $ sync cache s

-- | Read an 'Id' from the text of a row. Returns 'CorruptCache', with the text,
-- if the text is not an 'Id': the cache wrote something else.
parseCached :: Text -> Either CacheError Id
parseCached t = first (const (CorruptCache t)) (parse t)

-- | Read the @kind@ column of an @edges@ row. The names are the header names of
-- the file format, from 'edgeToHeader', so the writer and the reader cannot
-- differ. Returns 'CorruptCache' for a name that no kind has.
parseKind :: Text -> Either CacheError EdgeType
parseKind t =
  maybe (Left (CorruptCache t)) Right $
    lookup t [(edgeToHeader k, k) | k <- [minBound .. maxBound]]

-- | Read one @edges@ row: the @(src, kind, dst)@ texts become the 'Id' of the
-- source memory and an 'Edge'. Returns 'CorruptCache' for the first part that
-- does not parse.
parseEdge :: (Text, Text, Text) -> Either CacheError (Id, Edge)
parseEdge (s, k, d) = do
  src <- parseCached s
  ek <- parseKind k
  dst <- parseCached d
  pure (src, Edge ek dst)

-- | Make the graph from the rows of the two tables: the @id@ of each
-- @memories@ row, and the @(src, kind, dst)@ of each @edges@ row. This function
-- is pure.
--
-- Each memory is a node of the graph, also if it has no edges. Each edge row
-- is a graph of one edge, and '<>' joins them. A 'Graph' is a 'Monoid', so
-- the order of the rows does not matter. Returns 'CorruptCache' for the first
-- row that does not parse.
build :: ([Only Text], [(Text, Text, Text)]) -> Either CacheError Graph
build (ms, es) = do
  ids <- traverse (parseCached . fromOnly) ms
  edges <- traverse parseEdge es
  pure $
    foldMap (\i -> Graph.singleton i []) ids
      <> foldMap (\(s, e) -> Graph.singleton s [e]) edges

-- | The graph of all the memories in the cache.
--
-- It must equal @foldMap memoryGraph@ over the same memories. Build it the
-- same way: one 'Akyuu.Graph.singleton' for each @memories@ row, with the
-- edges of that row, joined with '<>'. An empty cache gives 'mempty'.
loadGraph :: Cache -> IO (Either CacheError Graph)
loadGraph (Cache c) = do
  rows <-
    tryAs CacheSQL $
      withTransaction c $
        (,)
          <$> query_ c "SELECT id FROM memories"
          <*> query_ c "SELECT src, kind, dst FROM edges"
  pure $ rows >>= build

-- | A memory that matched a search.
data Hit = Hit
  { -- | The memory.
    hitId :: Id,
    -- | A short piece of the body around the match. Each matching word is
    -- inside square brackets, for example @Lilly prefers [Haskell] for the@.
    hitSnippet :: Text
  }
  deriving (Eq, Show)

-- | Search the bodies of the memories.
--
-- The text is a list of words, not an FTS5 query: 'ftsQuery' makes the query
-- from it, so no input can be a syntax error. A memory matches if its body
-- has all the words. The match ignores case, and it matches word stems
-- ("derive" finds "derived"). The best match is first, by @bm25@.
--
-- The number is the most hits to return. A number of 0 or less gives no hits.
-- A text without words gives no hits.
search :: Cache -> Text -> Int -> IO (Either CacheError [Hit])
search (Cache c) q n
  | n <= 0 || T.null fq = pure (Right [])
  | otherwise = do
      rows <- tryAs CacheSQL (query c theQuery (fq, n) :: IO [(Text, Text)])
      pure (rows >>= traverse (\(t, s) -> (\i -> Hit i s) <$> parseCached t))
  where
    fq = ftsQuery q
    theQuery =
      "SELECT memories.id, snippet(bodies, 0, '[', ']', '...', 10) \
      \FROM bodies JOIN memories ON memories.rowid = bodies.rowid \
      \WHERE bodies MATCH ? \
      \ORDER BY bm25(bodies) \
      \LIMIT ?"

-- | Make an FTS5 query from the words of a text.
--
-- Split the text at white space. Put each word in double quotes, and double
-- each @"@ inside the word. Join the words with a space, which means AND in
-- FTS5. A text without words gives the empty text.
--
-- A NUL character (@\\0@) counts as white space. SQLite reads the query as a C
-- string, so a NUL would end it in the middle of a quoted word, and the
-- query would be an error.
--
-- FTS5 gives an error for a bare @foo-bar@, @AND@ or an open quote. A word in
-- quotes is always a plain phrase, so the query is always valid.
--
-- This function is pure.
ftsQuery :: Text -> Text
ftsQuery = T.unwords . map quote . T.words . T.map nulToSpace
  where
    quote w = "\"" <> T.replace "\"" "\"\"" w <> "\""
    nulToSpace '\0' = ' '
    nulToSpace c = c
