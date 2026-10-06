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
-- > refs/claude/notes      the ref named claude/notes
-- > refs/.lock/            exists while a process changes a ref
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
-- * A change takes a lock, and 'setRef' can check the current value under that
--   lock (compare and set). Two agents that move the same ref cannot lose
--   each other's update.
-- * A read does not take the lock. It does not need to.
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
    listRefs,
  )
where

import Akyuu.Id (Id, IdParseError)
import Control.Exception (IOException)
import Data.ByteString (ByteString)
import Data.Set (Set)
import Data.Text (Text)

-- Names ----------------------------------------------------------------

-- | The name of a ref, for example @claude/notes@.
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
mkName = error "Akyuu.Refs.mkName: not implemented"

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
advance = error "Akyuu.Refs.advance: not implemented"

-- | The 'Id' values that GC must keep for this ref: the current value and the
-- @n@ newest older values. A negative @n@ is the same as 0.
--
-- This function is pure. GC uses it to find the roots of the graph.
retained :: Int -> Ref -> Set Id
retained = error "Akyuu.Refs.retained: not implemented"

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
renderRef = error "Akyuu.Refs.renderRef: not implemented"

-- | Read a ref from bytes. This reverses 'renderRef'.
--
-- The last line can be without a newline. A blank line is an error
-- ('BadRefLine'). A file with no lines is 'EmptyRef'. The function does not
-- remove a repeated 'Id', so a file that someone edited by hand is read as it
-- is.
parseRef :: ByteString -> Either RefParseError Ref
parseRef = error "Akyuu.Refs.parseRef: not implemented"

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
  | -- | Another process holds the lock, and it did not release it in time.
    -- If no process runs, a crash left the lock. Remove the @refs/.lock@
    -- directory by hand.
    Locked
  | -- | The name is the start of another name, or another name is the start
    -- of it. For example @a@ and @a/b@.
    NameConflict Name
  deriving (Eq, Show)

-- | Open the refs of a store. The function makes the @refs@ directory under
-- the root if it is not there. The root is the same directory that
-- 'Akyuu.Store.openStore' gets.
--
-- It is safe to call this function on refs that already exist.
openRefs :: FilePath -> IO (Either RefError Refs)
openRefs = error "Akyuu.Refs.openRefs: not implemented"

-- | The root directory that 'openRefs' got.
refsRoot :: Refs -> FilePath
refsRoot (Refs root) = root

-- | The path of the file for a name: @\<root\>/refs/\<part\>/\<part\>@.
--
-- This function is pure: it does not look at the disk. The ref may not exist.
refPath :: Refs -> Name -> FilePath
refPath = error "Akyuu.Refs.refPath: not implemented"

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

-- | Read a ref. This function does not take the lock.
--
-- Returns 'NoSuchRef' if the ref is not there, and 'CorruptRef' if the file
-- is not a valid ref.
getRef :: Refs -> Name -> IO (Either RefError Ref)
getRef = error "Akyuu.Refs.getRef: not implemented"

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
setRef = error "Akyuu.Refs.setRef: not implemented"

-- | The names of all the refs.
--
-- The function walks the @refs@ directory. It skips each entry that is not a
-- valid name, for example the lock or a temporary file that has not been
-- renamed yet. It does not open the files, so it does not find a corrupt ref.
-- The order of the result is not defined.
listRefs :: Refs -> IO (Either RefError [Name])
listRefs = error "Akyuu.Refs.listRefs: not implemented"
