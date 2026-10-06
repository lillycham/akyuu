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

import Akyuu.Graph (Graph)
import Akyuu.Id (Id)
import Akyuu.Memory (Memory)
import Akyuu.Store (Store, StoreError)
import Control.Exception (IOException)
import Data.Set (Set)
import Data.Text (Text)
import Database.SQLite.Simple (Connection, SQLError)
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
openCache = error "Akyuu.Cache.openCache: not implemented"

-- | Close the cache. Do not use the 'Cache' after this call.
closeCache :: Cache -> IO ()
closeCache = error "Akyuu.Cache.closeCache: not implemented"

-- | Add a memory to the cache: its row, its edges and its body.
--
-- The 'Id' is the name of the object in the store. 'sync' passes the name that
-- it read from the file, and not a new hash of the content.
--
-- If the 'Id' is already in the cache, the function does nothing. An object
-- never changes, so there is nothing to update. It is one transaction.
index :: Cache -> Id -> Memory -> IO (Either CacheError ())
index = error "Akyuu.Cache.index: not implemented"

-- | Remove a memory from the cache: its row, the edges that start at it and
-- its body.
--
-- Edges of other memories that point /to/ this 'Id' stay. They are dangling
-- targets now, and the graph allows that. If the 'Id' is not in the cache,
-- the function does nothing. It is one transaction.
forget :: Cache -> Id -> IO (Either CacheError ())
forget = error "Akyuu.Cache.forget: not implemented"

-- | The 'Id' of every memory in the cache.
cachedIds :: Cache -> IO (Either CacheError (Set Id))
cachedIds = error "Akyuu.Cache.cachedIds: not implemented"

-- | What 'sync' changed. The order of each list is not defined.
data SyncReport = SyncReport
  { -- | The memories that the store had and the cache did not.
    added :: [Id],
    -- | The memories that the cache had and the store did not.
    removed :: [Id]
  }
  deriving (Eq, Show)

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
sync = error "Akyuu.Cache.sync: not implemented"

-- | Throw away everything in the cache, then 'sync'. Use it if the cache
-- might be wrong, for example after a change in the code that reads memories.
-- The report lists every memory of the store in 'added'.
reindex :: Cache -> Store -> IO (Either CacheError SyncReport)
reindex = error "Akyuu.Cache.reindex: not implemented"

-- | The graph of all the memories in the cache.
--
-- It must equal @foldMap memoryGraph@ over the same memories. Build it the
-- same way: one 'Akyuu.Graph.singleton' for each @memories@ row, with the
-- edges of that row, joined with '<>'. An empty cache gives 'mempty'.
loadGraph :: Cache -> IO (Either CacheError Graph)
loadGraph = error "Akyuu.Cache.loadGraph: not implemented"

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
search = error "Akyuu.Cache.search: not implemented"

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
ftsQuery = error "Akyuu.Cache.ftsQuery: not implemented"
