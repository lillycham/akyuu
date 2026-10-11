-- | One error type for the whole program, and the text that a person sees.
--
-- Each module of the library has its own error type, so that its functions
-- say exactly what can fail. A command of the CLI or a tool of the MCP server
-- uses many modules, so it needs one type that holds them all. That type is
-- 'AkyuuError'.
--
-- 'describe' gives the text for a person: one or two short sentences, with
-- the 'Id' or the name that the error is about. The CLI and the MCP server
-- both show this text, and never the 'Show' form.
module Akyuu.Error
  ( AkyuuError (..),
    fromSupersede,
    describe,
    describeParse,
  )
where

import Akyuu.Cache (CacheError (CacheIO, CacheLocked, CacheSQL, CacheStore, CorruptCache))
import Akyuu.GC (GCError (CorruptTombstone, GCCache, GCIO, GCLocked, GCRefs, GCStore), Tombstone (prunedAt), TombstoneParseError (BadTombstone, TombstoneNotUtf8))
import Akyuu.Id (Id, IdParseError (BadHex, BadLength, BadPrefix), render)
import Akyuu.Memory (MemoryParseError (BadEncoding, BadHeaderValue, BadLink, DuplicateHeader, MalformedHeader, MissingBlankLine, MissingHeader, NotCanonical, UnknownHeader))
import Akyuu.Refs (Name, NameError (BadSegment, EmptyName), RefError (CorruptRef, Locked, NameConflict, NoSuchRef, RefIO, Stale), RefParseError (BadRefLine, EmptyRef, NotUtf8), nameText)
import Akyuu.Store (StoreError (BadMemory, Corrupt, NotFound, StoreIO))
import Akyuu.Supersede (SupersedeError (SupersedeRef, SupersedeStore))
import Control.Exception (IOException, displayException)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (defaultTimeLocale, formatTime)
import Database.SQLite.Simple (SQLError (sqlErrorDetails))

-- | Why a command failed.
data AkyuuError
  = -- | A store function failed.
    StoreFailed StoreError
  | -- | A refs function failed.
    RefFailed RefError
  | -- | A cache function failed.
    CacheFailed CacheError
  | -- | A GC function failed.
    GCFailed GCError
  | -- | The text is not a valid ref name.
    BadName Text NameError
  | -- | The text is not a valid 'Id'.
    BadId Text IdParseError
  | -- | A header field of a new memory is not valid. The fields are the
    -- name of the header and the value. See 'Akyuu.Ops.checkField'.
    BadField Text Text
  | -- | The input of a command is not usable, for example a body that is not
    -- UTF-8. The text says why.
    BadInput Text
  | -- | No store root was given: no @--root@ and no @AKYUU_ROOT@.
    NoRoot
  | -- | The root directory of the store does not exist.
    RootMissing FilePath
  | -- | The memory is not in the store, and GC deleted it at this time.
    -- The set holds the memories that replace it now (see
    -- 'Akyuu.Query.resolve'). It is empty if nothing is known.
    Pruned Id Tombstone (Set Id)
  | -- | The text is neither a full 'Id' nor a usable prefix of one. See
    -- 'Akyuu.Ops.parseIdSpec'.
    BadIdSpec Text
  | -- | No memory in the store has an 'Id' that starts with this prefix.
    NoSuchPrefix Text
  | -- | More than one memory has an 'Id' that starts with this prefix. The
    -- list holds the first few of them, sorted.
    AmbiguousPrefix Text [Id]
  deriving (Eq, Show)

-- | Turn a 'SupersedeError' into an 'AkyuuError'. A supersede is a store
-- step and a ref step, so its error is one of those two.
fromSupersede :: SupersedeError -> AkyuuError
fromSupersede (SupersedeRef e) = RefFailed e
fromSupersede (SupersedeStore e) = StoreFailed e

-- | The text of an error, for a person. It has no line feed at the end.
describe :: AkyuuError -> Text
describe err = case err of
  StoreFailed e -> describeStore e
  RefFailed e -> describeRef e
  CacheFailed e -> describeCache e
  GCFailed e -> describeGC e
  BadName t e -> describeName t e
  BadId t e -> describeId t e
  BadField name v ->
    "The "
      <> name
      <> " "
      <> quote v
      <> " is not valid. It must be one line of text, not empty, with no space at either end."
  BadInput t -> t
  NoRoot -> "No store is given. Use --root DIR, or set AKYUU_ROOT."
  RootMissing p -> "The store directory " <> quote (T.pack p) <> " does not exist. Make it first."
  Pruned i t newer ->
    "The memory "
      <> render i
      <> " is gone: GC deleted it at "
      <> time t
      <> "."
      <> replaced (Set.toAscList newer)
  BadIdSpec t ->
    quote t
      <> " is not an id or the start of one. Give the whole id (sha256- and 64 hex digits),"
      <> " or the first 4 or more characters of it."
  NoSuchPrefix t -> "No memory has an id that starts with " <> quote t <> "."
  AmbiguousPrefix t is ->
    "More than one memory has an id that starts with "
      <> quote t
      <> ". Give more characters. They are: "
      <> T.intercalate ", " (map render is)
      <> "."
  where
    time = T.pack . formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" . prunedAt

describeStore :: StoreError -> Text
describeStore e = case e of
  StoreIO x -> "The store could not be read or written: " <> io x
  NotFound i -> "There is no memory " <> render i <> " in the store."
  Corrupt i -> "The memory " <> render i <> " is damaged: its content does not match its id."
  BadMemory i p -> "The file of " <> render i <> " is not a valid memory: " <> describeParse p

describeRef :: RefError -> Text
describeRef e = case e of
  RefIO x -> "The refs could not be read or written: " <> io x
  NoSuchRef n -> "There is no ref " <> refName n <> "."
  CorruptRef n p -> "The ref " <> refName n <> " is damaged: " <> refParse p
  Stale n (Just i) -> "The ref " <> refName n <> " is not at the expected value. It points to " <> render i <> " now. Read it again."
  Stale n Nothing -> "The ref " <> refName n <> " is not at the expected value. It does not exist."
  Locked -> "The refs are locked by another process. Try again."
  NameConflict n -> "The ref " <> refName n <> " clashes with another ref. One name cannot be the start of another, as in a and a/b."
  where
    refParse EmptyRef = "the file is empty."
    refParse NotUtf8 = "the file is not UTF-8 text."
    refParse (BadRefLine k p) = "line " <> T.pack (show k) <> " is not an id (" <> idReason p <> ")."

describeCache :: CacheError -> Text
describeCache e = case e of
  CacheSQL x -> "The cache database failed: " <> sqlErrorDetails x
  CacheIO x -> "The cache could not be opened: " <> io x
  CacheLocked -> "The cache is locked by another process. Try again."
  CacheStore s -> describeStore s
  CorruptCache t -> "The cache is damaged (bad row " <> quote t <> "). Run reindex to make it again."

describeGC :: GCError -> Text
describeGC e = case e of
  GCIO x -> "GC could not read or write a file: " <> io x
  GCStore s -> describeStore s
  GCRefs r -> describeRef r
  GCCache c -> describeCache c
  CorruptTombstone i p -> "The tombstone of " <> render i <> " is damaged: " <> tomb p
  GCLocked -> "Another GC run holds the lock. Try again later."
  where
    tomb TombstoneNotUtf8 = "it is not UTF-8 text."
    tomb (BadTombstone t) = "it holds " <> quote t <> "."

describeName :: Text -> NameError -> Text
describeName _ EmptyName = "A ref name cannot be empty."
describeName t (BadSegment s) =
  quote t
    <> " is not a valid ref name. The part "
    <> quote s
    <> " must have 1 to 64 of the characters a-z, 0-9, '-', '_' and '.', and must not start with '.'."

describeId :: Text -> IdParseError -> Text
describeId t p = quote t <> " is not a valid id: " <> idReason p <> "."

-- | The reason of an 'IdParseError', with no full stop.
idReason :: IdParseError -> Text
idReason (BadPrefix _) = "it must start with sha256-"
idReason (BadHex _) = "the part after sha256- must be hex digits"
idReason (BadLength n) = "it has " <> T.pack (show n) <> " bytes, and an id has 32"

-- | The text of a 'MemoryParseError'. It ends with a full stop.
describeParse :: MemoryParseError -> Text
describeParse p = case p of
  BadEncoding -> "it is not UTF-8 text."
  MissingBlankLine -> "it has no blank line after the headers."
  MissingHeader h -> "it has no " <> h <> " header."
  DuplicateHeader h -> "it has more than one " <> h <> " header."
  UnknownHeader h -> quote h <> " is not a known header."
  MalformedHeader l -> "the header line " <> quote l <> " has no ': '."
  BadHeaderValue h v -> "the " <> h <> " header has the bad value " <> quote v <> "."
  BadLink h r -> "the " <> h <> " header is not an id (" <> idReason r <> ")."
  NotCanonical -> "it is not in the canonical form: the headers must be kind, created, agent, then each edge on its own line, sorted, with no repeated line."

refName :: Name -> Text
refName = quote . nameText

quote :: Text -> Text
quote t = "'" <> t <> "'"

io :: IOException -> Text
io = T.pack . displayException

-- | The end of the text of 'Pruned': which memories replace the deleted one.
replaced :: [Id] -> Text
replaced [] = ""
replaced [i] = " A newer memory replaces it: " <> render i <> "."
replaced is = " Newer memories replace it: " <> T.intercalate ", " (map render is) <> "."
