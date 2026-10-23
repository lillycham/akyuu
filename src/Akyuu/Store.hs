-- | The object store: immutable memories on disk, named by their 'Id'.
--
-- This is the first module that does I/O. Everything below it is pure.
--
-- Layout, under the root directory of the store:
--
-- > store/9f/sha256-9f3a….md     one object
-- > trash/sha256-9f3a….md        an object that GC has swept
--
-- The directory @9f@ holds the objects whose digest starts with @9f@. It
-- keeps each directory small. The file name is the full text form of the
-- 'Id' and the suffix @.md@, so 'list' can read an 'Id' straight from a name.
--
-- Rules of the store:
--
-- * An object never changes. 'add' of a memory that is already there does
--   not write it again. It only sets the file time (see 'add').
-- * A write is atomic. The function writes a temporary file in the same
--   directory as the object, then renames it. A reader sees the whole object
--   or no object, also after a crash.
-- * The store does not trust the disk. 'getVerified' and 'verify' hash an
--   object again and compare the result with its name.
--
-- Functions return @IO (Either StoreError a)@. Each function catches the
-- 'IOException' of its own work and returns it as a 'StoreError'. A caller
-- never has to catch an exception from this module.
module Akyuu.Store
  ( -- * The store
    Store,
    openStore,
    storeRoot,

    -- * Errors
    StoreError (..),

    -- * Objects
    add,
    addWith,
    get,
    getVerified,
    exists,
    list,

    -- * Integrity and GC
    verify,
    trash,
    trashWith,

    -- * Layout
    objectPath,
    trashPath,
  )
where

import Akyuu.Fs (atomicWrite, tryWith)
import Akyuu.Id (Id, hashBytes, hashFile, parse, render, toBytes)
import Akyuu.Memory (Memory, MemoryParseError, parseMemory, renderMemory)
import Akyuu.Mutation (Mutation, checkMutation, withMutation)
import Control.Exception (IOException, try, tryJust)
import Control.Monad (filterM, guard, unless)
import Data.Bifunctor (first)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.Maybe (mapMaybe)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import System.Directory (createDirectoryIfMissing, doesDirectoryExist, doesFileExist, listDirectory, renameFile)
import System.FilePath (takeDirectory, (</>))
import System.IO.Error (isDoesNotExistError)
import System.Posix.Files (touchFile)

-- | A store on disk. A value of this type holds only the path of the root
-- directory, so it is cheap to copy and to pass around.
newtype Store = Store FilePath

-- | Why a store function failed.
data StoreError
  = -- | The disk gave an error, for example a missing directory or no permission.
    StoreIO IOException
  | -- | Another mutation holds the store lock.
    StoreLocked
  | -- | The store has no object with this 'Id'.
    NotFound Id
  | -- | The content of the object does not hash to its name.
    -- The file changed after it was written, or the disk is damaged.
    Corrupt Id
  | -- | The file of this object is not a valid memory.
    BadMemory Id MemoryParseError
  deriving (Eq, Show)

-- | Run an action that can throw an 'IOException'. An exception becomes
-- 'StoreIO'. Other exceptions, for example a timeout, are not caught.
tryIO :: IO a -> IO (Either StoreError a)
tryIO = tryWith StoreIO

-- | Open the store in a directory. The function makes the directory and its
-- @store@ and @trash@ directories if they are not there.
--
-- It is safe to call this function on a store that already exists.
openStore :: FilePath -> IO (Either StoreError Store)
openStore root = tryIO $ do
  createDirectoryIfMissing True (root </> "store")
  createDirectoryIfMissing True (root </> "trash")
  pure (Store root)

-- | The root directory of the store.
storeRoot :: Store -> FilePath
storeRoot (Store root) = root

-- | The name of the shard directory of an 'Id': the first byte of the digest,
-- as two lower case hex digits.
shard :: Id -> FilePath
shard = T.unpack . TE.decodeUtf8 . B16.encode . BS.take 1 . toBytes

-- | The path of the file for an 'Id'.
--
-- This function is pure: it does not look at the disk. The object may not
-- exist.
objectPath :: Store -> Id -> FilePath
objectPath s i = storeRoot s </> "store" </> shard i </> fileName i

-- | Write a memory to the store and return its 'Id'.
--
-- The function renders the memory, hashes the bytes, and writes them to a
-- temporary file in the directory of the object. Then it renames the file to
-- its final name.
--
-- If the object is already in the store, the function does not write its
-- bytes. It sets the file time to now and returns the same 'Id'. GC reads
-- the file time as the time the object came into the store, so an agent that
-- adds an old object again gets the grace period of "Akyuu.GC". The content
-- does not change, so an object still never changes.
--
-- The mutation lock serialises additions with GC and other writers. If GC
-- moved an object first, adding its bytes publishes it again with a fresh
-- grace period.
add :: Store -> Memory -> IO (Either StoreError Id)
add s m = withMutation (storeRoot s) StoreLocked StoreIO $ \held -> addWith held s m

-- | Add under the mutation lock of a compound operation.
addWith :: Mutation -> Store -> Memory -> IO (Either StoreError Id)
addWith held s m = tryIO $ do
  checkMutation held (storeRoot s)
  createDirectoryIfMissing True (takeDirectory final)
  touched <- tryJust (guard . isDoesNotExistError) (touchFile final)
  either (const (atomicWrite final bytes)) pure touched
  pure i
  where
    i = hashBytes bytes
    bytes = renderMemory m
    final = objectPath s i

-- | Read the bytes of an object. Returns 'NotFound' if the file is not there.
-- 'get' and 'getVerified' both start with this function.
readObject :: Store -> Id -> IO (Either StoreError BS.ByteString)
readObject s i = orNotFound i (BS.readFile (objectPath s i))

-- | Read an object and parse it.
--
-- This function does not hash the file again. Use 'getVerified' if you
-- need to be sure that the file did not change.
-- Returns 'NotFound' if the object is not there, and 'BadMemory' if the file
-- is not a valid memory.
get :: Store -> Id -> IO (Either StoreError Memory)
get s i = do
  r <- readObject s i
  pure (r >>= first (BadMemory i) . parseMemory)

-- | Read an object, check its hash, and parse it.
--
-- This is 'get' with one more step: the function hashes the bytes and
-- compares the result with the 'Id'. Returns 'Corrupt' if they differ.
-- The check comes before the parse, so a damaged file gives 'Corrupt'
-- and not 'BadMemory'.
getVerified :: Store -> Id -> IO (Either StoreError Memory)
getVerified s i = do
  r <- readObject s i
  pure $ do
    bytes <- r
    unless (hashBytes bytes == i) (Left (Corrupt i))
    first (BadMemory i) (parseMemory bytes)

-- | Check if the store has an object with this 'Id'. This function does not
-- read the file.
exists :: Store -> Id -> IO (Either StoreError Bool)
exists s i = tryIO $ doesFileExist $ objectPath s i

-- | Read an 'Id' from the name of a file. This reverses 'fileName'.
-- Returns 'Nothing' if the name does not end in @.md@ or the rest is not an
-- 'Id'. 'list' uses this to skip files that are not objects.
toId :: FilePath -> Maybe Id
toId n = do
  stem <- T.stripSuffix ".md" (T.pack n)
  either (const Nothing) Just (parse stem)

-- | All the 'Id' values in the store.
--
-- The function reads the names of the files. It does not open them. It
-- skips a name that is not an 'Id', for example a temporary file that
-- 'add' has not renamed yet. The order of the result is not defined.
--
-- It also skips each entry of @store@ that is not a shard directory: a name
-- that is not two hex digits, or one that is not a directory. A file manager
-- can put such files there, for example @.DS_Store@ on macOS. A shard that
-- vanishes during the read counts as empty.
list :: Store -> IO (Either StoreError [Id])
list s = tryIO $ do
  entries <- listDirectory base
  shards <- filterM (doesDirectoryExist . (base </>)) (filter isShardName entries)
  names <- concat <$> mapM (\d -> ifMissing [] (listDirectory (base </> d))) shards
  pure $ mapMaybe toId names
  where
    base = storeRoot s </> "store"
    ifMissing d act = either (const d) id <$> tryJust (guard . isDoesNotExistError) act

-- | Is this the name of a shard directory: two hex digits, lower case? This
-- is the form that 'shard' makes.
isShardName :: FilePath -> Bool
isShardName n = length n == 2 && all (`elem` ("0123456789abcdef" :: String)) n

-- | Check that the file of an object hashes to its own name. The function
-- reads the file in chunks, so it uses the same memory for any file size.
-- It throws an 'IOException' if the file cannot be read.
intact :: Store -> Id -> IO Bool
intact s i = (== i) <$> hashFile (objectPath s i)

-- | Hash every object again and return the 'Id' values of the objects that
-- do not match their names.
--
-- An empty result means that the store is sound. The function reads every
-- file, so it is slow on a big store.
verify :: Store -> IO (Either StoreError [Id])
verify s = do
  r <- list s
  case r of
    Left e -> pure (Left e)
    Right ids -> tryIO $ filterM (fmap not . intact s) ids

-- | Run an action on the file of an 'Id'. A missing file becomes
-- 'NotFound'. Any other 'IOException' becomes 'StoreIO'.
--
-- The check is part of the action, so there is no gap between the check and
-- the use. Do not use it for an action in which a missing /directory/ could
-- give the same error as a missing file.
orNotFound :: Id -> IO a -> IO (Either StoreError a)
orNotFound i act = do
  r <- try act
  pure $ case r of
    Left e
      | isDoesNotExistError e -> Left (NotFound i)
      | otherwise -> Left (StoreIO e)
    Right a -> Right a

-- | The name of the file of an object: the text form of the 'Id' and @.md@.
-- 'toId' reverses it.
fileName :: Id -> FilePath
fileName i = T.unpack (render i) <> ".md"

-- | The path of an object in the @trash@ directory: @trash/sha256-….md@.
--
-- This function is pure: it does not look at the disk. "Akyuu.GC" uses it to
-- find and delete old files in @trash@.
trashPath :: Store -> Id -> FilePath
trashPath s i = storeRoot s </> "trash" </> fileName i

-- | Move an object to the @trash@ directory. GC uses this function to sweep.
--
-- The object leaves @store@ but it is not deleted, so a mistake can be
-- undone. Returns 'NotFound' if the object is not in the store.
-- The deletion of old files in @trash@ is not part of this function.
trash :: Store -> Id -> IO (Either StoreError ())
trash s i = withMutation (storeRoot s) StoreLocked StoreIO $ \held -> trashWith held s i

-- | Move an object under the mutation lock held by GC.
trashWith :: Mutation -> Store -> Id -> IO (Either StoreError ())
trashWith held s i = do
  made <- tryIO $ do
    checkMutation held (storeRoot s)
    createDirectoryIfMissing True (takeDirectory to)
  case made of
    Left e -> pure (Left e)
    Right () -> orNotFound i $ renameFile from to
  where
    from = objectPath s i
    to = trashPath s i
