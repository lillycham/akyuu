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
-- ('parseRecords'). The formats are @claude-code@, @codex@ (the rollouts of
-- the Codex CLI) and @omp@ (the sessions of oh-my-pi, and of pi, which has the
-- same shape).
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

    -- * The hash of a span
    withSha256,
    Stripper,
    engiStrip,
    spanBytes,
    hashSpan,
    hashPointer,
    Verdict (..),
    checkHash,

    -- * Capture
    sessionHook,
  )
where

import Control.Applicative ((<|>))
import Control.Concurrent (forkIO)
import Control.Exception (IOException, try)
import Control.Monad (guard)
import Crypto.Hash.SHA256 qualified as SHA256
import Data.Aeson (Value (Array, Number, Object, String), decodeStrict)
import Data.Aeson.Key (fromText)
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.ByteString qualified as B
import Data.ByteString.Base16 qualified as Base16
import Data.ByteString.Char8 qualified as BC
import Data.Char (isAlphaNum, isDigit)
import Data.Foldable (toList)
import Data.List (elemIndex, sortOn)
import Data.Maybe (fromMaybe, mapMaybe, maybeToList)
import Data.Ord (Down (Down))
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (decodeUtf8, decodeUtf8Lenient)
import Data.Time (UTCTime, defaultTimeLocale, formatTime, parseTimeM)
import Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import System.Directory (doesDirectoryExist, getFileSize, listDirectory, pathIsSymbolicLink)
import System.Exit (ExitCode (ExitSuccess))
import System.FilePath (isAbsolute, splitDirectories, takeFileName, (</>))
import System.IO (hClose)
import System.Process (CreateProcess (std_err, std_in, std_out), StdStream (CreatePipe), createProcess, proc, waitForProcess)

-- The pointer --------------------------------------------------------------

-- | The kind of the memory that holds a pointer.
sourceKind :: Text
sourceKind = "source"

-- | The transcript formats that a pointer can name.
knownFormats :: [Text]
knownFormats = ["claude-code", "codex", "omp"]

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
    pointerHint :: Maybe Text,
    -- | The SHA-256 of the span from 'pointerFrom' to 'pointerTo' as the
    -- archive tool stores it: the raw lines, with the strip rule of engi
    -- applied ('hashSpan'), in lower case hex. With it, @source verify@ can
    -- tell a span that was not changed from one that was ('checkHash').
    pointerSha256 :: Maybe Text
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
  pure (Pointer format session time from to hint Nothing)
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

-- | Add the hash of the span to a pointer. It is 64 digits of lower case hex.
withSha256 :: Text -> Pointer -> Either Text Pointer
withSha256 h p
  | T.length h == 64 && T.all (`elem` ("0123456789abcdef" :: String)) h = Right p {pointerSha256 = Just h}
  | otherwise = Left "sha256 must be 64 digits of lower case hex"

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
      maybe [] (\v -> ["hint: " <> v]) (pointerHint p),
      maybe [] (\v -> ["sha256: " <> v]) (pointerSha256 p)
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
  digest <- get "sha256"
  mkPointer format session time from to hint >>= maybe Right withSha256 digest
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

-- | Is a file name a copy of this session, and which kind? The agent's own
-- file is @<stem>.jsonl@. An archive (made by engi) has @<stem>.jsonl.zst@
-- and, for a session that grew, @<stem>.N.jsonl.zst@. Nothing else matches.
-- Whether a stem belongs to the session depends on the format ('stemMatches').
classify :: Text -> Text -> FilePath -> Maybe Where
classify format session name = do
  (stem, w) <- splitName (T.pack name)
  if stemMatches format session stem then Just w else Nothing

-- | Take a file name apart: the stem, and whether it is the agent's own file
-- or an archived version. A name with another ending is not a transcript.
splitName :: Text -> Maybe (Text, Where)
splitName name
  | Just stem <- T.stripSuffix ".jsonl" name = Just (stem, Live)
  | Just rest <- T.stripSuffix ".jsonl.zst" name = Just (archived rest)
  | otherwise = Nothing
  where
    archived rest =
      let (dotted, num) = T.breakOnEnd "." rest
          stem = T.dropEnd 1 dotted
       in if not (T.null stem) && not (T.null num) && T.all isDigit num && T.length num <= 6
            then (stem, Archived (read (T.unpack num)))
            else (rest, Archived 1)

-- | Does the stem of a file name belong to a session? Claude Code names the
-- file for the session. A Codex file is @rollout-<time>-<session>@ and an omp
-- or pi file is @<time>_<session>@, so the session is the end of the stem
-- after a separator. That match needs a whole id (at least 32 characters): the
-- last group of an id is not the id. An omp session that has a name, not an
-- id, is found by its name.
stemMatches :: Text -> Text -> Text -> Bool
stemMatches "claude-code" session stem = stem == session
stemMatches "codex" session stem = stem == session || endsWithId "-" session stem
stemMatches "omp" session stem = stem == session || endsWithId "_" session stem
stemMatches _ _ _ = False

endsWithId :: Text -> Text -> Text -> Bool
endsWithId sep session stem = T.length session >= 32 && (sep <> session) `T.isSuffixOf` stem

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
parseRecords "codex" = mapMaybe codexRecord . BC.lines
parseRecords "omp" = mapMaybe ompRecord . BC.lines
parseRecords _ = const []

-- | The time of a record: the @timestamp@ field, like @2026-11-01T19:00:58.250Z@.
timeOf :: KM.KeyMap Value -> Maybe UTCTime
timeOf o = do
  String stamp <- KM.lookup "timestamp" o
  parseTimeM True defaultTimeLocale "%Y-%m-%dT%H:%M:%S%QZ" (T.unpack stamp)

-- | A text field of an object.
textField :: Text -> KM.KeyMap Value -> Maybe Text
textField k o = case KM.lookup (fromText k) o of
  Just (String t) -> Just t
  _ -> Nothing

-- | A Codex rollout. The conversation is the records of type @response_item@:
-- messages (not the developer's, which are the instructions that the host
-- adds), reasoning that has a summary, tool calls and their outputs, and
-- messages between agents. The id of a record is its @ordinal@.
codexRecord :: ByteString -> Maybe Record
codexRecord l = do
  Object o <- decodeStrict l
  String "response_item" <- KM.lookup "type" o
  time <- timeOf o
  Object p <- KM.lookup "payload" o
  kind <- textField "type" p
  (role, text) <- codexItem kind p
  guard (not (T.null (T.strip text)))
  pure (Record time role (cut text) (ordinal o))
  where
    ordinal o = case KM.lookup "ordinal" o of
      Just (Number n) -> Just (T.pack (show (truncate n :: Int)))
      _ -> Nothing

-- | The speaker and the text of the payload of a Codex response item.
codexItem :: Text -> KM.KeyMap Value -> Maybe (Text, Text)
codexItem "message" p = do
  role <- textField "role" p
  guard (role `elem` ["user", "assistant"])
  pure (role, blocksText (KM.lookup "content" p))
codexItem "reasoning" p = do
  let summaries = [t | Array ss <- maybeToList (KM.lookup "summary" p), Object s <- toList ss, Just t <- [textField "text" s]]
  guard (not (null summaries))
  pure ("assistant", "[thinking] " <> T.intercalate "\n" summaries)
codexItem "function_call" p = pure ("assistant", "[tool_use " <> fromMaybe "?" (textField "name" p) <> "] " <> fromMaybe "" (textField "arguments" p))
codexItem "custom_tool_call" p = pure ("assistant", "[tool_use " <> fromMaybe "?" (textField "name" p) <> "] " <> fromMaybe "" (textField "input" p))
codexItem "function_call_output" p = pure ("tool", "[tool_result] " <> blocksText (KM.lookup "output" p))
codexItem "custom_tool_call_output" p = pure ("tool", "[tool_result] " <> blocksText (KM.lookup "output" p))
codexItem "agent_message" p =
  pure
    ( "agent",
      "[" <> fromMaybe "?" (textField "author" p) <> " -> " <> fromMaybe "?" (textField "recipient" p) <> "] " <> blocksText (KM.lookup "content" p)
    )
codexItem _ _ = Nothing

-- | The text of a value that is a string or a list of blocks.
blocksText :: Maybe Value -> Text
blocksText Nothing = ""
blocksText (Just v) = T.intercalate "\n" (filter (not . T.null) (map blockText (contentBlocks v)))

-- | An omp or pi session. The conversation is the entries of type @message@,
-- with the role @user@, @assistant@ or @toolResult@ (a @system@ message is the
-- prompt of the host, and is left out). The id of a record is the id of its
-- entry.
ompRecord :: ByteString -> Maybe Record
ompRecord l = do
  Object o <- decodeStrict l
  String "message" <- KM.lookup "type" o
  time <- timeOf o
  Object m <- KM.lookup "message" o
  role <- textField "role" m
  speaker <- case role of
    "user" -> Just "user"
    "assistant" -> Just "assistant"
    "toolResult" -> Just "tool"
    _ -> Nothing
  let body = blocksText (KM.lookup "content" m)
  guard (not (T.null (T.strip body)))
  pure (Record time speaker (cut (if speaker == "tool" then "[tool_result] " <> body else body)) (textField "id" o))

claudeRecord :: ByteString -> Maybe Record
claudeRecord l = do
  Object o <- decodeStrict l
  String typ <- KM.lookup "type" o
  time <- timeOf o
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
  Just "input_text" -> fromMaybe "" (stringField "text" b)
  Just "output_text" -> fromMaybe "" (stringField "text" b)
  Just "thinking" -> maybe "" ("[thinking] " <>) (stringField "thinking" b)
  Just "tool_use" -> "[tool_use " <> fromMaybe "?" (stringField "name" b) <> "] " <> inputText b
  Just "toolCall" -> "[tool_use " <> fromMaybe "?" (stringField "name" b) <> "] " <> inputText b
  Just "tool_result" -> "[tool_result] " <> resultText b
  Just "image" -> "[image]"
  _ -> ""
  where
    inputText (Object o) = maybe "" compact (KM.lookup "input" o <|> KM.lookup "arguments" o)
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
showPointer roots window p = do
  found <- locate roots p
  case found of
    [] -> pure (Left (notFound roots p))
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

-- | Why the session of a pointer was not found, for a person. It says whether
-- the config has a root for the format at all.
notFound :: [Root] -> Pointer -> Text
notFound roots p
  | not (any ((== pointerFormat p) . rootFormat) roots) =
      "the session " <> pointerSession p <> " is not available: no root is set for the format " <> pointerFormat p <> ". Add one to [source] in the config file."
  | otherwise = "the session " <> pointerSession p <> " is not available on this machine: it is not under any root for " <> pointerFormat p

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

-- Hash of a span ---------------------------------------------------------------

-- | A function that applies the strip rule to bytes: the data of an image, and
-- opaque signatures, become a placeholder that holds their length and hash. The
-- rule is written down and implemented by the archive tool engi. akyuu does not
-- implement it a second time: it asks @engi strip@ ('engiStrip'), so that a live
-- file and its archived copy give the same hash from one definition. A test can
-- pass another function.
type Stripper = ByteString -> IO (Either Text ByteString)

-- | The strip rule, by running @engi strip@. If @engi@ is not on the PATH, the
-- answer says so.
engiStrip :: Stripper
engiStrip bytes = do
  r <- try run :: IO (Either IOException (ExitCode, ByteString, ByteString))
  pure $ case r of
    Left _ -> Left "engi is not on the PATH, and it is needed to apply the strip rule"
    Right (ExitSuccess, out, _) -> Right out
    Right (_, _, err) -> Left ("engi strip failed: " <> T.strip (decodeUtf8Lenient err))
  where
    run = do
      (Just hin, Just out, Just err, ph) <-
        createProcess (proc "engi" ["strip"]) {std_in = CreatePipe, std_out = CreatePipe, std_err = CreatePipe}
      -- The input goes in from another thread: a span can be longer than a pipe
      -- holds, and the output must be read at the same time.
      _ <- forkIO (ignoring (B.hPut hin bytes) >> ignoring (hClose hin))
      o <- B.hGetContents out
      e <- B.hGetContents err
      code <- waitForProcess ph
      pure (code, o, e)
    ignoring act = () <$ (try act :: IO (Either IOException ()))

-- | The id of the record on a line: the @uuid@ of Claude Code, the @ordinal@ of
-- Codex, the @id@ of an omp entry. It is the id that 'recordId' gives, for any
-- line, not only for conversation.
lineId :: Text -> ByteString -> Maybe Text
lineId format l = do
  Object o <- decodeStrict l
  case format of
    "codex" -> case KM.lookup "ordinal" o of
      Just (Number n) -> Just (T.pack (show (truncate n :: Int)))
      _ -> Nothing
    "omp" -> textField "id" o
    _ -> textField "uuid" o

-- | The raw lines of a file from the record with one id to the record with
-- another, both included, with every line between them (also those that are
-- not conversation), each ending in a line feed. Nothing if an id is not in
-- the file, or the second comes first.
spanBytes :: Text -> ByteString -> Text -> Text -> Maybe ByteString
spanBytes format raw from to = do
  let ls = BC.lines raw
      ids = map (lineId format) ls
  i <- elemIndex (Just from) ids
  j <- elemIndex (Just to) (drop i ids)
  pure (BC.unlines (take (j + 1) (drop i ls)))

-- | The hash of a span of a file: the SHA-256, in lower case hex, of the span
-- after the strip rule. The same hash for a live file and for its archived
-- copy, because both are stripped first. The error says what failed.
hashSpan :: Stripper -> Text -> ByteString -> Text -> Text -> IO (Either Text Text)
hashSpan strip format raw from to = case spanBytes format raw from to of
  Nothing -> pure (Left ("the records " <> from <> " to " <> to <> " are not in the file, or are in the wrong order"))
  Just s -> fmap (decodeUtf8 . Base16.encode . SHA256.hash) <$> strip s

-- | The hash of the span of a pointer, worked out from the file of its session
-- now. The pointer needs both @from@ and @to@.
hashPointer :: Stripper -> [Root] -> Pointer -> IO (Either Text Text)
hashPointer strip roots p = case (pointerFrom p, pointerTo p) of
  (Just from, Just to) -> do
    found <- locate roots p
    case found of
      [] -> pure (Left (notFound roots p))
      (best : _) -> do
        bytes <- loadBytes best
        either (pure . Left) (\b -> hashSpan strip (pointerFormat p) b from to) bytes
  _ -> pure (Left "a hash needs both from and to: the ids of the first and the last record")

-- | What a check of a hash found.
data Verdict
  = -- | The span has the hash that the pointer holds.
    Intact
  | -- | The span has another hash.
    Changed
  | -- | The check could not be made (the strip rule could not be applied). The
    -- text says why.
    CannotCheck Text
  deriving (Eq, Show)

-- | Compare the span of a pointer, as it is in the file now, with the hash that
-- the pointer holds. A @Left@ is a problem before the comparison: the pointer
-- has no hash or no range, the session is not available, or the ids are not in
-- the file. The file that was read comes with the verdict.
checkHash :: Stripper -> [Root] -> Pointer -> IO (Either Text (Located, Verdict))
checkHash strip roots p = case (pointerSha256 p, pointerFrom p, pointerTo p) of
  (Nothing, _, _) -> pure (Left "the pointer has no hash")
  (Just expected, Just from, Just to) -> do
    found <- locate roots p
    case found of
      [] -> pure (Left (notFound roots p))
      (best : _) -> do
        bytes <- loadBytes best
        case bytes of
          Left e -> pure (Left e)
          Right b -> case spanBytes (pointerFormat p) b from to of
            Nothing -> pure (Left ("the records " <> from <> " to " <> to <> " are not in the file, or are in the wrong order"))
            Just s -> do
              stripped <- strip s
              pure . Right . (,) best $ case stripped of
                Left why -> CannotCheck why
                Right out
                  | decodeUtf8 (Base16.encode (SHA256.hash out)) == expected -> Intact
                  | otherwise -> Changed
  (Just _, _, _) -> pure (Left "a hash needs both from and to: the ids of the first and the last record")

-- Capture ------------------------------------------------------------------------

-- | The text that tells an agent which session it is in, from the JSON that
-- the start hook of the agent gets on its standard input. Claude Code sends
-- @session_id@ there, and the id is the name of the transcript file. The
-- agent can then make a pointer to its own session when it writes a memory.
-- Nothing if the payload is not JSON, has no usable @session_id@, or the format
-- is not known: a hook that has nothing to say prints nothing.
sessionHook :: Text -> ByteString -> Maybe Text
sessionHook format payload = do
  Object o <- decodeStrict payload
  sid <- textField "session_id" o
  _ <- either (const Nothing) Just (mkPointer format sid (posixSecondsToUTCTime 0) Nothing Nothing Nothing)
  pure . T.unlines $
    [ "This is a " <> format <> " session, id " <> sid <> ".",
      "When you write a memory that comes from this conversation, make a pointer to it and link the memory to the pointer, so that a later session can read what was said:",
      "  akyuu source add --format " <> format <> " --session " <> sid,
      "It prints the id of the pointer. Give that id as derived_from when you write the memory. The pointer holds the time (now), so make it when you write the memory."
    ]
