{-# LANGUAGE OverloadedStrings #-}

-- | Provenance: where a memory came from.
--
-- A pointer says which agent session a memory came from, and when. It is a
-- memory of kind @source@ with a body of @key: value@ lines, so the store
-- does not change: the ids, the edges and the file format stay as they are.
-- A note links to its pointer with a @derived-from@ edge.
--
-- > format: claude-code
-- > session: 0775d85c-5836-4715-a3a7-f306d261bf49
-- > at: 2026-11-01T19:00:58Z
-- > from: <id of a record>        (optional)
-- > to: <id of a record>          (optional)
-- > hint: projects/app/s1.jsonl   (optional, relative, not used to find a file)
--
-- The transcripts are not in the store. They are files that an agent keeps,
-- or an archive of them. A pointer is resolved against /roots/: folders that
-- the person lists in the config. A session can be on the machine, or not.
-- A session that is not here is a normal answer ("not available"), not an
-- error of the store.
--
-- This module reads, and never writes, a transcript. It does not parse a
-- format that it does not know: each format has a function that finds its
-- files by name ('classify') and one that reads their records
-- ('parseRecords'). Claude Code is the first. Codex and omp have the same
-- shape and are not here yet.
module Akyuu.Source
  ( -- * The pointer
    sourceKind,
    knownFormats,
    Pointer (..),
    mkPointer,
    renderPointer,
    parsePointer,

    -- * Finding a session
    Root (..),
    Where (..),
    Located (..),
    classify,
    locate,

    -- * Reading it
    Record (..),
    parseRecords,
    Window (..),
    defaultWindow,
    selectWindow,
    selectRange,
    renderRecord,
    Shown (..),
    showPointer,
  )
where

import Control.Exception (IOException, try)
import Data.Aeson (Value (Array, Object, String), decodeStrict)
import Data.Aeson.Key (fromText)
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.ByteString qualified as B
import Data.ByteString.Char8 qualified as BC
import Data.Char (isAlphaNum, isDigit)
import Data.Foldable (toList)
import Data.List (sortOn)
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Ord (Down (Down))
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (decodeUtf8Lenient)
import Data.Time (UTCTime, defaultTimeLocale, formatTime, parseTimeM)
import System.Directory (doesDirectoryExist, getFileSize, listDirectory, pathIsSymbolicLink)
import System.Exit (ExitCode (ExitSuccess))
import System.FilePath (isAbsolute, splitDirectories, takeFileName, (</>))
import System.IO (hClose)
import System.Process (CreateProcess (std_err, std_out), StdStream (CreatePipe), createProcess, proc, waitForProcess)

-- The pointer --------------------------------------------------------------

-- | The kind of the memory that holds a pointer.
sourceKind :: Text
sourceKind = "source"

-- | The transcript formats that a pointer can name.
knownFormats :: [Text]
knownFormats = ["claude-code"]

data Pointer = Pointer
  { -- | The transcript format. It is not the author of the memory.
    pointerFormat :: Text,
    -- | The session: the key that a file is found by.
    pointerSession :: Text,
    -- | The time that the memory is about, to the second.
    pointerAt :: UTCTime,
    -- | The id of the first record, if something knows it.
    pointerFrom :: Maybe Text,
    -- | The id of the last record, if something knows it.
    pointerTo :: Maybe Text,
    -- | A path below a root, for a person to read. It is never used to find
    -- a file, and never holds a home directory.
    pointerHint :: Maybe Text
  }
  deriving (Eq, Show)

-- | Make a pointer, with every field checked. A session or a record id has
-- letters, digits, @-@, @_@ and @.@ only, because it is matched against file
-- names. A hint is relative and does not climb out of its root.
mkPointer :: Text -> Text -> UTCTime -> Maybe Text -> Maybe Text -> Maybe Text -> Either Text Pointer
mkPointer format session time from to hint = do
  check (format `elem` knownFormats) ("the format " <> format <> " is not known. The formats are: " <> T.intercalate ", " knownFormats)
  idField "session" session
  mapM_ (idField "from") from
  mapM_ (idField "to") to
  mapM_ hintField hint
  pure (Pointer format session time from to hint)
  where
    check ok msg = if ok then Right () else Left msg
    idField name v =
      check
        (not (T.null v) && T.length v <= 200 && T.all idChar v && v /= "." && v /= "..")
        (name <> " must be letters, digits, - _ and . only, and not empty")
    idChar c = isAlphaNum c || c `elem` ("-_." :: String)
    hintField h =
      check
        ( not (T.null h)
            && T.length h <= 500
            && not (T.any (\c -> c == '\n' || c == '\r') h)
            && not (isAbsolute (T.unpack h))
            && ".." `notElem` splitDirectories (T.unpack h)
        )
        "hint must be a relative path that stays below its root"

timeFormat :: String
timeFormat = "%Y-%m-%dT%H:%M:%SZ"

-- | The body of the memory: @key: value@ lines in a fixed order.
renderPointer :: Pointer -> Text
renderPointer p =
  T.intercalate "\n" . concat $
    [ ["format: " <> pointerFormat p],
      ["session: " <> pointerSession p],
      ["at: " <> T.pack (formatTime defaultTimeLocale timeFormat (pointerAt p))],
      maybe [] (\v -> ["from: " <> v]) (pointerFrom p),
      maybe [] (\v -> ["to: " <> v]) (pointerTo p),
      maybe [] (\v -> ["hint: " <> v]) (pointerHint p)
    ]

-- | Read the body of a pointer. A field that this version does not know is
-- ignored, so that a later version can add one. A known field that is
-- repeated, or a missing one, is an error.
parsePointer :: Text -> Either Text Pointer
parsePointer body = do
  fields <- traverse split (filter (not . T.null . T.strip) (T.lines body))
  let get k = case [v | (k', v) <- fields, k' == k] of
        [] -> Right Nothing
        [v] -> Right (Just v)
        _ -> Left ("the field " <> k <> " is there more than once")
      need k = get k >>= maybe (Left ("the field " <> k <> " is missing")) Right
  format <- need "format"
  session <- need "session"
  atText <- need "at"
  time <- maybe (Left ("at is not a time like 2026-11-01T19:00:58Z: " <> atText)) Right (parseTimeM True defaultTimeLocale timeFormat (T.unpack atText))
  from <- get "from"
  to <- get "to"
  hint <- get "hint"
  mkPointer format session time from to hint
  where
    split l = case T.breakOn ": " l of
      (k, rest)
        | not (T.null rest) -> Right (T.strip k, T.strip (T.drop 2 rest))
        | otherwise -> Left ("not a key: value line: " <> l)

-- Finding a session ------------------------------------------------------------

-- | A folder to search, and the format of the transcripts in it.
data Root = Root
  { rootFormat :: Text,
    rootPath :: FilePath
  }
  deriving (Eq, Show)

-- | Where a file is: the agent's own folder, or an archive of it.
data Where
  = Live
  | -- | An archived copy, with its version (the first copy is 1).
    Archived Int
  deriving (Eq, Show)

data Located = Located
  { locatedPath :: FilePath,
    locatedWhere :: Where,
    locatedSize :: Integer
  }
  deriving (Eq, Show)

-- | Is a file name a copy of this session, and which kind? A live Claude Code
-- file is @<session>.jsonl@. An archive (made by engi) has @<session>.jsonl.zst@
-- and, for a session that grew, @<session>.N.jsonl.zst@. Nothing else matches.
classify :: Text -> Text -> FilePath -> Maybe Where
classify "claude-code" session name
  | name' == session <> ".jsonl" = Just Live
  | name' == session <> ".jsonl.zst" = Just (Archived 1)
  | Just rest <- T.stripPrefix (session <> ".") name',
    Just num <- T.stripSuffix ".jsonl.zst" rest,
    not (T.null num),
    T.all isDigit num,
    T.length num <= 6 =
      Just (Archived (read (T.unpack num)))
  | otherwise = Nothing
  where
    name' = T.pack name
classify _ _ _ = Nothing

-- | The files of a session below the roots of its format, best first: the
-- agent's own files before archived ones, the larger of two live copies first
-- (an agent that copies a session leaves a shorter one behind), and the newest
-- archived version first. Symbolic links are not followed. A root that is not
-- there has no files.
locate :: [Root] -> Pointer -> IO [Located]
locate roots p = do
  found <- concat <$> mapM scan [r | r <- roots, rootFormat r == pointerFormat p]
  pure (sortOn rank found)
  where
    scan r = do
      files <- walk (rootPath r)
      concat
        <$> mapM
          ( \f -> case classify (pointerFormat p) (pointerSession p) (takeFileName f) of
              Nothing -> pure []
              Just w -> do
                size <- getFileSize f
                pure [Located f w size]
          )
          files
    rank (Located _ Live size) = (0 :: Int, 0 :: Int, Down size)
    rank (Located _ (Archived v) size) = (1, negate v, Down size)

-- | Every file below a folder, without following links.
walk :: FilePath -> IO [FilePath]
walk root = do
  there <- doesDirectoryExist root
  if there then go root else pure []
  where
    go dir = do
      names <- listDirectory dir
      concat <$> mapM (visit dir) names
    visit dir n = do
      let p = dir </> n
      link <- pathIsSymbolicLink p
      if link
        then pure []
        else do
          isDir <- doesDirectoryExist p
          if isDir then go p else pure [p]

-- Reading it -------------------------------------------------------------------

-- | One turn of a conversation, the same for every format.
data Record = Record
  { recordTime :: UTCTime,
    -- | @user@, @assistant@ or @tool@ (a user record that only holds results).
    recordRole :: Text,
    recordText :: Text,
    -- | The id that the format gives the record, if it has one.
    recordId :: Maybe Text
  }
  deriving (Eq, Show)

-- | The longest text of one record, in characters. The rest is cut.
maxRecordChars :: Int
maxRecordChars = 800

-- | The records of a transcript, in file order. A line that is not JSON, a
-- record with no time, and a record that is not conversation (a queue
-- operation, an attachment, a system note) are left out. A format that is
-- not known has no records.
parseRecords :: Text -> ByteString -> [Record]
parseRecords "claude-code" = mapMaybe claudeRecord . BC.lines
parseRecords _ = const []

claudeRecord :: ByteString -> Maybe Record
claudeRecord l = do
  Object o <- decodeStrict l
  String typ <- KM.lookup "type" o
  String stamp <- KM.lookup "timestamp" o
  time <- parseTimeM True defaultTimeLocale "%Y-%m-%dT%H:%M:%S%QZ" (T.unpack stamp)
  Object msg <- KM.lookup "message" o
  content <- KM.lookup "content" msg
  let blocks = contentBlocks content
      onlyResults = not (null blocks) && all isResult blocks
  role <- case typ of
    "assistant" -> Just "assistant"
    "user" -> Just (if onlyResults then "tool" else "user")
    _ -> Nothing
  let text = T.intercalate "\n" (filter (not . T.null) (map blockText blocks))
      uuid = case KM.lookup "uuid" o of
        Just (String u) -> Just u
        _ -> Nothing
  pure (Record time role (cut text) uuid)
  where
    isResult b = typeOf b == Just "tool_result"

-- | The blocks of a message: a text is one block.
contentBlocks :: Value -> [Value]
contentBlocks (String t) = [Object (KM.fromList [("type", String "text"), ("text", String t)])]
contentBlocks (Array bs) = toList bs
contentBlocks _ = []

typeOf :: Value -> Maybe Text
typeOf (Object o) = case KM.lookup "type" o of
  Just (String t) -> Just t
  _ -> Nothing
typeOf _ = Nothing

stringField :: Text -> Value -> Maybe Text
stringField k (Object o) = case KM.lookup (fromText k) o of
  Just (String t) -> Just t
  _ -> Nothing
stringField _ _ = Nothing

-- | The text that a person reads for one block of a message.
blockText :: Value -> Text
blockText b = case typeOf b of
  Just "text" -> fromMaybe "" (stringField "text" b)
  Just "thinking" -> maybe "" ("[thinking] " <>) (stringField "thinking" b)
  Just "tool_use" -> "[tool_use " <> fromMaybe "?" (stringField "name" b) <> "] " <> inputText b
  Just "tool_result" -> "[tool_result] " <> resultText b
  Just "image" -> "[image]"
  _ -> ""
  where
    inputText (Object o) = maybe "" compact (KM.lookup "input" o)
    inputText _ = ""
    resultText (Object o) = case KM.lookup "content" o of
      Just (String t) -> t
      Just (Array bs) -> T.intercalate "\n" (filter (not . T.null) (map blockText (toList bs)))
      _ -> ""
    resultText _ = ""
    -- The fields of a tool call, as short text: the values, not the JSON.
    compact (Object o) = T.intercalate " " [v | String v <- KM.elems o]
    compact (String t) = t
    compact _ = ""

-- | Cut a text at 'maxRecordChars', and say so.
cut :: Text -> Text
cut t
  | T.length t <= maxRecordChars = t
  | otherwise = T.take maxRecordChars t <> "…"

-- | How many records to show before the time, and after it.
data Window = Window Int Int
  deriving (Eq, Show)

defaultWindow :: Window
defaultWindow = Window 6 2

-- | The last records at or before a time, then the first ones after it.
selectWindow :: Window -> UTCTime -> [Record] -> [Record]
selectWindow (Window b a) time rs = lastN b [r | r <- rs, recordTime r <= time] <> take a [r | r <- rs, recordTime r > time]
  where
    lastN n xs = drop (length xs - max 0 n) xs

-- | The records from one id to another, both included. Nothing if either id
-- is not there, or the second comes first.
selectRange :: Text -> Text -> [Record] -> Maybe [Record]
selectRange from to rs = do
  i <- index from
  j <- index to
  if i <= j then Just (take (j - i + 1) (drop i rs)) else Nothing
  where
    index k = lookup (Just k) (zip (map recordId rs) [0 :: Int ..])

-- | One record as text: the time, the speaker, then the text. More lines of
-- the text are indented, so that a record is easy to see.
renderRecord :: Record -> Text
renderRecord r = case T.lines (recordText r) of
  [] -> header
  (first : rest) -> T.intercalate "\n" ((header <> " " <> first) : map ("  " <>) rest)
  where
    header = "[" <> T.pack (formatTime defaultTimeLocale timeFormat (recordTime r)) <> "] " <> recordRole r <> ":"

-- | What a pointer shows.
data Shown = Shown
  { -- | The file that was read.
    shownLocated :: Located,
    shownRecords :: [Record]
  }
  deriving (Eq, Show)

-- | Resolve a pointer: find the best file of its session, read it (an
-- archived file through @zstd -d@), and pick the records. A pointer with both
-- @from@ and @to@ shows that range if the two ids are in the file, and the
-- records around @at@ if they are not. A session that is not found is
-- "not available", which is not a fault.
showPointer :: [Root] -> Window -> Pointer -> IO (Either Text Shown)
showPointer roots window p
  | not (any ((== pointerFormat p) . rootFormat) roots) =
      pure (Left ("the session " <> pointerSession p <> " is not available: no root is set for the format " <> pointerFormat p <> ". Add one to [source] in the config file."))
  | otherwise = do
      found <- locate roots p
      case found of
        [] -> pure (Left ("the session " <> pointerSession p <> " is not available on this machine: it is not under any root for " <> pointerFormat p))
        (best : _) -> do
          bytes <- loadBytes best
          pure $ do
            b <- bytes
            let rs = parseRecords (pointerFormat p) b
                chosen = case (pointerFrom p, pointerTo p) of
                  (Just f, Just t) | Just range <- selectRange f t rs -> range
                  _ -> selectWindow window (pointerAt p) rs
            if null rs
              then Left ("the file " <> T.pack (locatedPath best) <> " has no conversation in it")
              else Right (Shown best chosen)

-- | The bytes of a file. An archived file is decompressed with @zstd -d -c@,
-- so akyuu does not link a zstd library. If @zstd@ is not on the PATH, or the
-- file is damaged, the answer says so.
loadBytes :: Located -> IO (Either Text ByteString)
loadBytes (Located path Live _) = do
  r <- try (B.readFile path) :: IO (Either IOException ByteString)
  pure (either (\e -> Left ("cannot read " <> T.pack path <> ": " <> T.pack (show e))) Right r)
loadBytes (Located path (Archived _) _) = do
  r <- try run :: IO (Either IOException (ExitCode, ByteString, ByteString))
  pure $ case r of
    Left _ -> Left "zstd is not on the PATH, and it is needed to read an archived file"
    Right (ExitSuccess, out, _) -> Right out
    Right (_, _, err) -> Left ("cannot decompress " <> T.pack path <> ": " <> T.strip (decodeUtf8Lenient err))
  where
    run = do
      (_, Just out, Just err, ph) <- createProcess (proc "zstd" ["-d", "-c", "-q", "--", path]) {std_out = CreatePipe, std_err = CreatePipe}
      bytes <- B.hGetContents out
      msg <- B.hGetContents err
      hClose out
      hClose err
      code <- waitForProcess ph
      pure (code, bytes, msg)
