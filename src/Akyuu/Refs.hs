-- | Refs: the only mutable layer. A ref is a 'Name' that points to an 'Id'.
--
-- A store never changes, so something must say which memory is the current
-- one. A ref does that. It is like a Git branch or a Nix profile. To
-- "change" a memory, an agent adds a new object and moves the ref to it.
--
-- A ref keeps its older values too. Each value is a /generation/. GC uses the
-- generations to decide which old memories to keep (see 'retained').
--
-- Layout, under the root directory of the store:
--
-- > refs/me/notes          the ref named me/notes
-- > refs/.lock             the lock file (see below)
--
-- A ref file holds one 'Id' on each line, in the text form, newest first.
-- The first line is the current value. 'renderRef' and 'parseRef' read and
-- write this format.
--
-- A name can have several parts, separated by @/@. Each part is a directory,
-- except the last. For this reason a name cannot be the start of another
-- name: if @a@ is a ref, then @a/b@ cannot be one ('NameConflict').
--
-- Rules of the refs:
--
-- * A write is atomic ('Akyuu.Fs.atomicWrite'). A reader sees the whole old
--   file or the whole new file.
-- * A change takes the shared store mutation lock, then @refs/.lock@, and
--   checks the current value under both locks (compare and set).
-- * A read takes neither lock: it sees one atomically replaced ref file.
-- * Both locks use OS file locks (@flock@). The OS releases them when the
--   process ends, also after a crash. The lock files stay on disk.
-- * This module does not look at the store. A ref can point to an 'Id' that
--   is not in the store. 'Akyuu.Store' and this module are joined one layer
--   above, in @supersede@.
--
-- Functions return @IO (Either RefError a)@. A caller never has to catch an
-- exception from this module.
module Akyuu.Refs
  ( -- * Names
    Name,
    NameError (..),
    mkName,
    nameText,

    -- * Refs
    Ref (..),
    advance,
    retained,

    -- * File format
    RefParseError (..),
    renderRef,
    parseRef,

    -- * The refs directory
    Refs,
    openRefs,
    refsRoot,
    refPath,

    -- * Errors
    RefError (..),

    -- * Operations
    Expected (..),
    getRef,
    setRef,
    updateRef,
    listRefs,
  )
where

import Akyuu.Fs (atomicWrite, tryWith)
import Akyuu.Id (Id, IdParseError, parse, render)
import Akyuu.Mutation (Mutation, checkMutation, withMutation)
import Control.Concurrent (threadDelay)
import Control.Exception (IOException)
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Char (isAsciiLower, isDigit)
import Data.List (find)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import GHC.IO.Exception (IOErrorType (InappropriateType))
import System.Directory
  ( createDirectoryIfMissing,
    doesDirectoryExist,
    doesFileExist,
    listDirectory,
  )
import System.FileLock (SharedExclusive (Exclusive), withTryFileLock)
import System.FilePath (joinPath, takeDirectory, (</>))
import System.IO.Error
  ( ioeGetErrorType,
    isAlreadyExistsError,
    isDoesNotExistError,
  )

-- Names ----------------------------------------------------------------

-- | The name of a ref, for example @me/notes@.
--
-- A name becomes a path on disk, so the constructor is not exported. Make a
-- name with 'mkName'. Then no name can leave the @refs@ directory.
newtype Name = Name Text
  deriving (Eq, Ord, Show)

-- | Why a text is not a valid name.
data NameError
  = -- | The text is empty.
    EmptyName
  | -- | One part of the name is not valid. The error holds that part. An empty
    -- part (from @a//b@, @/a@ or @a/@) is also an error.
    BadSegment Text
  deriving (Eq, Show)

-- | Check a text and make a 'Name' from it.
--
-- Split the text at @/@. Each part must:
--
-- * have 1 to 64 characters;
-- * have only the characters @a@ to @z@, @0@ to @9@, @-@, @_@ and @.@;
-- * not start with @.@.
--
-- A part cannot start with a dot, so @.@, @..@, the lock and the temporary
-- files cannot be names. The rule allows only lower case, because macOS file
-- systems do not tell @Notes@ from @notes@ by default.
--
-- The check comes before the file system sees the name. The parts are
-- checked from left to right, and the first bad part is in the error.
mkName :: Text -> Either NameError Name
mkName t
  | T.null t = Left EmptyName
  | otherwise =
      maybe
        (Right (Name t))
        (Left . BadSegment)
        (find (not . okPart) parts)
  where
    parts = T.splitOn "/" t

okPart :: Text -> Bool
okPart t =
  T.all okChar t
    && T.take 1 t /= "."
    && not (T.null t)
    && (T.length t <= 64)

okChar :: Char -> Bool
okChar c = isAsciiLower c || isDigit c || c `elem` ("-_." :: String)

-- | The text of a name. @mkName (nameText n) == Right n@.
nameText :: Name -> Text
nameText (Name t) = t

-- Refs -----------------------------------------------------------------

-- | The value of a ref: its current 'Id' and the older values.
--
-- The list is newest first and does not hold 'current'. There is always at
-- least one value, so a ref cannot be empty.
data Ref = Ref
  { -- | The 'Id' that the ref points to now.
    current :: Id,
    -- | The 'Id' values it pointed to before, newest first.
    history :: [Id]
  }
  deriving (Eq, Show)

-- | Move a ref to a new 'Id'. The old current value becomes the newest
-- generation of the history.
--
-- If the new 'Id' is the current value, the ref does not change. The history
-- does not get a duplicate. This function is pure. 'setRef' uses it.
advance :: Id -> Ref -> Ref
advance i r
  | i == current r = r
  | otherwise =
      Ref
        { current = i,
          history = current r : history r
        }

-- | The 'Id' values that GC must keep for this ref: the current value and the
-- @n@ newest older values. A negative @n@ is the same as 0.
--
-- This function is pure. GC uses it to find the roots of the graph.
retained :: Int -> Ref -> Set Id
retained n r = Set.fromList $ current r : (take n $ history r)

-- File format ----------------------------------------------------------

-- | Why the content of a ref file is not a valid ref.
data RefParseError
  = -- | The file has no lines.
    EmptyRef
  | -- | The file is not UTF-8 text.
    NotUtf8
  | -- | A line is not an 'Id'. The number is the line number, from 1.
    BadRefLine Int IdParseError
  deriving (Eq, Show)

-- | Write a ref as bytes: one line for each 'Id', the current value first.
-- Each line ends with a newline.
renderRef :: Ref -> ByteString
renderRef r = (TE.encodeUtf8 . T.unlines . map render) ids
  where
    ids = current r : history r

-- | Read a ref from bytes. This reverses 'renderRef'.
--
-- The last line can be without a newline. A blank line is an error
-- ('BadRefLine'). A file with no lines is 'EmptyRef'. The function does not
-- remove a repeated 'Id', so a file that someone edited by hand is read as it
-- is.
parseRef :: ByteString -> Either RefParseError Ref
parseRef bs = do
  t <- first (const NotUtf8) (TE.decodeUtf8' bs)
  ids <- traverse (\(n, l) -> first (BadRefLine n) (parse l)) (zip [1 ..] (T.lines t))
  case ids of
    [] -> Left EmptyRef
    (x : xs) -> Right (Ref x xs)

-- The refs directory ---------------------------------------------------

-- | The refs of a store on disk. A value of this type holds only the path of
-- the root directory, so it is cheap to copy and to pass around.
newtype Refs = Refs FilePath

-- | Why a refs function failed.
data RefError
  = -- | The disk gave an error, for example no permission.
    RefIO IOException
  | -- | There is no ref with this name. This includes the case in which a
    -- part of the name is a ref, or the name is a directory of other refs.
    NoSuchRef Name
  | -- | The file of this ref is not a valid ref.
    CorruptRef Name RefParseError
  | -- | 'setRef' got an 'Expected' value that is not true. The error holds the
    -- value that the ref has now, or 'Nothing' if the ref does not exist.
    Stale Name (Maybe Id)
  | -- | Another process or thread holds the lock, and it did not release it
    -- in time. A crash cannot cause this: the OS releases the lock when a
    -- process ends.
    Locked
  | -- | The name is the start of another name, or another name is the start
    -- of it. For example @a@ and @a/b@.
    NameConflict Name
  deriving (Eq, Show)

-- | Run an action that can throw an 'IOException'. An exception becomes
-- 'RefIO'. Other exceptions, for example a timeout, are not caught.
tryIO :: IO a -> IO (Either RefError a)
tryIO = tryWith RefIO

-- | Open the refs of a store. The function makes the @refs@ directory under
-- the root if it is not there. The root is the same directory that
-- 'Akyuu.Store.openStore' gets.
--
-- It is safe to call this function on refs that already exist.
openRefs :: FilePath -> IO (Either RefError Refs)
openRefs root = tryIO $ do
  createDirectoryIfMissing True (root </> "refs")
  pure (Refs root)

-- | The root directory that 'openRefs' got.
refsRoot :: Refs -> FilePath
refsRoot (Refs root) = root

-- | The path of the file for a name: @\<root\>/refs/\<part\>/\<part\>@.
--
-- This function is pure: it does not look at the disk. The ref may not exist.
refPath :: Refs -> Name -> FilePath
refPath r n = (refsRoot r) </> "refs" </> (T.unpack $ nameText n)

-- Operations -----------------------------------------------------------

-- | What 'setRef' must find before it changes a ref. The check and the change
-- happen under one lock, so nothing can change the ref between them.
data Expected
  = -- | No check. Use this for a person who sets a ref by hand.
    Unchecked
  | -- | The ref must not exist yet. This makes a new ref.
    MustBeAbsent
  | -- | The current value must be this 'Id'. An agent that read a ref, made
    -- a new memory, and now moves the ref uses this. If another agent moved
    -- the ref first, the call returns 'Stale', and the agent can read again.
    MustBe Id
  deriving (Eq, Show)

-- | Does this error from a /read/ mean that the ref is not there?
--
-- A missing file is 'isDoesNotExistError'. Two more cases have the same
-- meaning for a ref. If a part of the name is a ref (a file), the disk says
-- "not a directory". If the name is a directory of other refs, the disk says
-- "is a directory". GHC gives both of them the type 'InappropriateType'.
-- 'isConflict' uses the same type for a /write/.
isMissing :: IOException -> Bool
isMissing e = isDoesNotExistError e || ioeGetErrorType e == InappropriateType

-- | Run a read. An error for which 'isMissing' is true becomes 'NoSuchRef'.
-- Any other 'IOException' becomes 'RefIO'.
orNoSuchRef :: Name -> IO a -> IO (Either RefError a)
orNoSuchRef n = tryWith (\e -> if isMissing e then NoSuchRef n else RefIO e)

-- | Read the bytes of a ref file. 'getRef' parses them.
readRef :: Refs -> Name -> IO (Either RefError BS.ByteString)
readRef r n = orNoSuchRef n (BS.readFile (refPath r n))

-- | Read a ref. This function does not take the lock.
--
-- Returns 'NoSuchRef' if the ref is not there, and 'CorruptRef' if the file
-- is not a valid ref.
getRef :: Refs -> Name -> IO (Either RefError Ref)
getRef r n = do
  bytes <- readRef r n
  pure (bytes >>= first (CorruptRef n) . parseRef)

-- | Run an action with the lock of the refs.
--
-- The lock is an exclusive @flock@ on the file @refs/.lock@ (the package
-- @filelock@ makes the file if it is not there). Only one holder at a time
-- can have it, in this process or in another one. The OS releases the lock
-- when the holder ends, so a crash cannot leave the lock held.
--
-- The function does not wait inside the lock call. A blocked call would
-- also block the other Haskell threads of the program, and the holder could
-- never release the lock. Instead, it tries the lock without waiting. If the
-- lock is taken, it waits 10 ms with 'threadDelay' and tries again, up to 100
-- times (about one second), and then returns 'Locked'.
--
-- The function releases the lock when the action ends, also if the action
-- returns 'Left' or throws. An 'IOException' from the lock, or from the
-- action, becomes 'RefIO'.
withLock :: Refs -> (RefError -> e) -> IO (Either e a) -> IO (Either e a)
withLock r wrap act = go (100 :: Int)
  where
    lock = refsRoot r </> "refs" </> ".lock"
    go 0 = pure (Left (wrap Locked))
    go k = do
      got <- tryWith (wrap . RefIO) (withTryFileLock lock Exclusive (const act))
      case got of
        Left e -> pure (Left e)
        Right Nothing -> threadDelay 10000 >> go (k - 1)
        Right (Just v) -> pure v

-- | Compare the current value of a ref with what the caller 'Expected'.
-- This function is pure.
--
-- Every failure is 'Stale', and it holds the real current value (or
-- 'Nothing' if the ref does not exist). In particular, 'MustBeAbsent' fails
-- if the ref exists, and 'MustBe' fails if the ref does not exist.
checkExpected :: Name -> Expected -> Maybe Ref -> Either RefError ()
checkExpected n ex mr =
  case (ex, mr) of
    (Unchecked, _) -> Right ()
    (MustBeAbsent, Nothing) -> Right ()
    (MustBe x, Just ref) | current ref == x -> Right ()
    _ -> Left $ Stale n (current <$> mr)

-- | Change the result of 'getRef' for 'setRef'. For 'setRef', a missing ref is
-- not an error. It means that there is no current value ('Nothing').
-- Other errors stay errors: a corrupt ref must not be replaced without notice.
absentIsNothing :: Either RefError Ref -> Either RefError (Maybe Ref)
absentIsNothing r = case r of
  Left (NoSuchRef _) -> Right Nothing
  Left e -> Left e -- CorruptRef, RefIO: still errors
  Right ref -> Right (Just ref)

-- | Does this error from a /write/ mean that the name clashes with another ref?
--
-- If a part of the name is a ref, 'createDirectory' fails with "already
-- exists". If the name is a directory of other refs, 'renameFile' fails with
-- "inappropriate type". See also 'isMissing', for a read.
isConflict :: IOException -> Bool
isConflict e = isAlreadyExistsError e || ioeGetErrorType e == InappropriateType

-- | Move a ref to an 'Id', and return the new value of the ref.
--
-- The steps, with the lock held:
--
-- 1. Read the ref, if there is one.
-- 2. Compare it with the 'Expected' value. If they differ, return 'Stale'.
-- 3. Compute the new value with 'advance'. A new ref is @Ref i []@.
-- 4. Write it with 'Akyuu.Fs.atomicWrite'.
--
-- Then release the lock. The function releases the lock also if a step fails,
-- so a failure does not block the next call.
--
-- The function makes the directories of a name with several parts.
-- Returns 'Locked' if it cannot get the lock in about one second, and
-- 'NameConflict' if the name clashes with another ref.
setRef :: Refs -> Name -> Expected -> Id -> IO (Either RefError Ref)
setRef rs n ex i =
  withMutation (refsRoot rs) Locked RefIO $ \held ->
    updateRef held rs n ex id (pure (Right i))

-- | Validate and publish a reference update under a store mutation lock.
-- The producer runs only after the expectation and destination checks pass,
-- while both the mutation and refs locks remain held. It must not acquire
-- either lock again. This prevents rejected proposals entering the store.
updateRef :: Mutation -> Refs -> Name -> Expected -> (RefError -> e) -> IO (Either e Id) -> IO (Either e Ref)
updateRef held rs n ex wrap produce = withLock rs wrap $ do
  checkMutation held (refsRoot rs)
  cur <- getRef rs n
  case absentIsNothing cur >>= \mr -> checkExpected n ex mr >> Right mr of
    Left err -> pure (Left (wrap err))
    Right mr -> do
      ready <- tryWith writeError $ do
        directory <- doesDirectoryExist path
        if directory then pure True else parentConflict (takeDirectory path)
      case ready of
        Left err -> pure (Left err)
        Right True -> pure (Left (wrap (NameConflict n)))
        Right False -> do
          made <- produce
          case made of
            Left err -> pure (Left err)
            Right i -> do
              let new = maybe (Ref i []) (advance i) mr
              (new <$) <$> tryWith writeError (createDirectoryIfMissing True (takeDirectory path) >> atomicWrite path (renderRef new))
  where
    writeError e = wrap (if isConflict e then NameConflict n else RefIO e)
    path = refPath rs n
    -- Check namespace conflicts without reserving empty directories for a
    -- producer that may fail. Only publication creates parent directories.
    parentConflict dir = do
      file <- doesFileExist dir
      if file || dir == refsRoot rs </> "refs"
        then pure file
        else parentConflict (takeDirectory dir)

-- | The names of all the refs.
--
-- The function walks the @refs@ directory. It skips each entry that is not a
-- valid name, for example the lock or a temporary file that has not been
-- renamed yet. It does not open the files, so it does not find a corrupt ref.
-- The order of the result is not defined.
listRefs :: Refs -> IO (Either RefError [Name])
listRefs r = tryIO (walk [])
  where
    base = refsRoot r </> "refs"

    walk :: [FilePath] -> IO [Name]
    walk parts = do
      entries <- listDirectory (joinPath (base : parts))
      concat <$> traverse (visit parts) entries

    visit :: [FilePath] -> FilePath -> IO [Name]
    visit parts e = case mkName (asText parts') of
      Left _ -> pure [] -- .lock, .tmp…, Bad Name: skip
      Right n -> do
        isDir <- doesDirectoryExist (joinPath (base : parts'))
        if isDir then walk parts' else pure [n]
      where
        parts' = parts ++ [e]

    asText = T.intercalate "/" . map T.pack
