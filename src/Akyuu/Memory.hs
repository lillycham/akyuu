{-# LANGUAGE OverloadedStrings #-}

-- | A memory: one plaintext object of the store.
--
-- This module is pure. It turns a 'Memory' into bytes and bytes into a
-- 'Memory'. It does not read or write files.
--
-- The file format is a block of headers, one blank line, and the body:
--
-- > kind: fact
-- > created: 2026-10-05T12:00:00Z
-- > agent: claude
-- > supersedes: sha256-<64 hex digits>
-- > about: sha256-<64 hex digits>
-- >
-- > The body is free text.
--
-- Rules of the format:
--
-- * @kind@, @created@ and @agent@ are required. Each one appears once.
-- * @supersedes@, @about@, @derived-from@ and @refines@ are optional.
--   Each one can appear many times. Each line holds one 'Id'.
-- * A header line is the name, a colon, one space and the value.
-- * The body is everything after the first blank line. It is not changed.
-- * The text is UTF-8. Lines end with a line feed only.
--
-- 'renderMemory' writes one canonical form. The 'Id' of a memory is the hash
-- of that form. 'parseMemory' accepts only that form: a file with the headers
-- in another order, a repeated edge line, or any other change of the bytes is
-- 'NotCanonical'. So for every file that 'parseMemory' accepts,
--  m == bytes@, and the 'Id' of the memory is the hash of the file.
--
-- A 'Memory' is made with 'mkMemory', which checks the rules of its fields.
-- The constructor is not exported.
module Akyuu.Memory
  ( Memory (memKind, memCreated, memAgent, memEdges, memBody),
    MemoryError (..),
    mkMemory,
    validField,
    MemoryParseError (..),
    renderMemory,
    parseMemory,
    memoryId,
    memoryGraph,
    edgeToHeader,
    timeFormat,
  )
where

import Akyuu.Graph (Edge (Edge, kind, target), EdgeType (About, DerivedFrom, Refines, Supersedes), Graph)
import Akyuu.Graph qualified as Graph
import Akyuu.Id (Id, IdParseError, hashBytes)
import Akyuu.Id qualified as Id
import Data.Bifunctor (Bifunctor (first))
import Data.ByteString (ByteString)
import Data.Char (isSpace)
import Data.Foldable (traverse_)
import Data.Map (Map)
import Data.Map qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text, pack)
import Data.Text qualified as T
import Data.Text.Encoding (decodeUtf8', encodeUtf8)
import Data.Time (UTCTime, defaultTimeLocale, formatTime, parseTimeM)
import Data.Time.Clock.POSIX (posixSecondsToUTCTime, utcTimeToPOSIXSeconds)

-- | The format of the @created@ header, for example @2026-10-05T12:00:00Z@.
-- 'renderMemory' and 'parseTime' both use it, so they cannot disagree.
timeFormat :: String
timeFormat = "%Y-%m-%dT%H:%M:%SZ"

-- | A memory.
--
-- The field names start with @mem@ because "Akyuu.Graph" already exports
-- @kind@ and @target@.
--
-- The edges are a 'Set'. Two equal edges are one edge, and the order of the
-- edges does not matter. This makes the canonical form follow from the type.
data Memory = Memory
  { -- | The sort of memory, for example @fact@ or @preference@.
    -- The value is not empty, has one line, and has no space at either end.
    memKind :: Text,
    -- | The time of creation, in UTC. 'renderMemory' keeps whole seconds only.
    memCreated :: UTCTime,
    -- | The name of the agent that wrote the memory.
    -- The value is not empty, has one line, and has no space at either end.
    memAgent :: Text,
    -- | The edges to older memories.
    memEdges :: Set Edge,
    -- | The text of the memory. It can be empty and it can have many lines.
    memBody :: Text
  }
  deriving (Eq, Show)

-- | The reason that 'parseMemory' rejects a file.
data MemoryParseError
  = -- | The file is not valid UTF-8.
    BadEncoding
  | -- | The file has no blank line between the headers and the body.
    MissingBlankLine
  | -- | A required header is not in the file. The field is the header name.
    MissingHeader Text
  | -- | A header that must appear once appears more than once.
    DuplicateHeader Text
  | -- | The name of a header is not one of the known names.
    UnknownHeader Text
  | -- | A header line has no @: @ in it. The field is the whole line.
    MalformedHeader Text
  | -- | The value of a header is not valid. The fields are the name and the value.
    BadHeaderValue Text Text
  | -- | The value of an edge header is not a valid 'Id'.
    -- The fields are the header name and the reason.
    BadLink Text IdParseError
  | -- | The file is a valid memory, but it is not in the canonical form that
    -- 'renderMemory' writes: the headers are in another order, an edge line
    -- is repeated or not in order, or the bytes differ in another way.
    NotCanonical
  deriving (Eq, Show)

-- | The reason that 'mkMemory' rejects a field.
data MemoryError
  = -- | A field has a value that the format cannot hold: it is empty, it has
    -- more than one line, or it has a space at either end. The fields are the
    -- header name and the value.
    InvalidField Text Text
  deriving (Eq, Show)

-- | Does a value fit the @kind@ or @agent@ header? It must not be empty, must
-- have one line, and must have no white space at either end. A line feed in
-- a kind would write a second header line.
validField :: Text -> Bool
validField v =
  not (T.null v)
    && not (T.any (`elem` ['\n', '\r']) v)
    && not (isSpace (T.head v))
    && not (isSpace (T.last v))

-- | Make a memory. This is the only way to make one, apart from 'parseMemory'.
--
-- The kind and the agent must pass 'validField'. The time is cut to whole
-- seconds, because 'renderMemory' keeps whole seconds only, so the memory
-- that this function returns is equal to the one that the store reads back.
mkMemory :: Text -> UTCTime -> Text -> Set Edge -> Text -> Either MemoryError Memory
mkMemory k t a es b
  | not (validField k) = Left (InvalidField "kind" k)
  | not (validField a) = Left (InvalidField "agent" a)
  | otherwise =
      Right
        Memory
          { memKind = k,
            memCreated = posixSecondsToUTCTime (fromInteger (floor (utcTimeToPOSIXSeconds t))),
            memAgent = a,
            memEdges = es,
            memBody = b
          }

-- | The name of the header for a kind of edge.
-- 'renderMemory' writes this name, and 'parseEdges' reads it.
edgeToHeader :: Graph.EdgeType -> Text
edgeToHeader Supersedes = "supersedes"
edgeToHeader About = "about"
edgeToHeader DerivedFrom = "derived-from"
edgeToHeader Refines = "refines"

-- | Write a memory in its canonical form.
--
-- The order is: @kind@, @created@, @agent@, then the edge headers, then a
-- blank line, then the body. The edge headers go in the order of the
-- 'Edge' type: @supersedes@, @about@, @derived-from@, @refines@. Inside
-- one header name, the 'Id' values are in ascending order.
-- The time has the form @2026-10-05T12:00:00Z@.
--
-- The body is written as it is, with no line feed added. The function
-- needs 'memKind' and 'memAgent' to follow the rules in their comments.
renderMemory :: Memory -> ByteString
renderMemory m =
  encodeUtf8 (T.unlines headerLines <> "\n" <> memBody m)
  where
    fixedHeaders =
      [ "kind: "
          <> memKind m,
        "created: "
          <> ( pack $
                 formatTime defaultTimeLocale timeFormat $
                   memCreated m
             ),
        "agent: "
          <> (memAgent m)
      ]
    headerLines = fixedHeaders <> map edgeLine (Set.toAscList $ memEdges m)
    edgeHeader x = (edgeToHeader $ kind x, Id.render $ target x)
    edgeLine x =
      let (e, i) = edgeHeader x
       in e <> ": " <> i

-- | Split a file at its first blank line. The result is the block of
-- headers and the body.
--
-- Returns 'MissingBlankLine' if the text has no blank line. An empty body is
-- not an error.
splitBody :: Text -> Either MemoryParseError (Text, Text)
splitBody t =
  let (hdrs, rest) = T.breakOn "\n\n" t
   in if T.null rest
        then Left MissingBlankLine
        else Right (hdrs, T.drop 2 rest)

-- | Split one header line at its first @: @. The result is the name and the
-- value.
--
-- Returns 'MalformedHeader' with the whole line if the line has no @: @.
splitHeader :: Text -> Either MemoryParseError (Text, Text)
splitHeader t =
  let (hdrs, rest) = T.breakOn ": " t
   in if T.null rest
        then Left (MalformedHeader hdrs)
        else Right (hdrs, T.drop 2 rest)

-- | The names of all headers that the format allows. It holds the three
-- required names and one name for each kind of edge.
known :: Set Text
known = Set.fromList (["kind", "created", "agent"] ++ map edgeToHeader [minBound .. maxBound])

-- | Check that a header name is in 'known'.
-- Returns 'UnknownHeader' if it is not.
checkKnown :: Text -> Either MemoryParseError ()
checkKnown n
  | n `Set.member` known = Right ()
  | otherwise = Left (UnknownHeader n)

-- | Collect the values of each header name.
--
-- The values of one name stay in the order of the file. Returns
-- 'UnknownHeader' for the first name that is not in 'known'.
groupHeaders :: [(Text, Text)] -> Either MemoryParseError (Map Text [Text])
groupHeaders pairs = do
  traverse_ checkKnown (map fst pairs)
  pure (Map.fromListWith (flip (++)) [(k, [v]) | (k, v) <- pairs])

-- | The value of a header that must appear exactly once.
--
-- Returns 'MissingHeader' if the name is not in the map, and
-- 'DuplicateHeader' if the name has more than one value.
single :: Text -> Map Text [Text] -> Either MemoryParseError Text
single name m = case Map.lookup name m of
  Just [x] -> Right x
  Just (_ : _ : _) -> Left (DuplicateHeader name)
  _ -> Left (MissingHeader name)

-- | Read the value of the @created@ header.
--
-- The function accepts only text that 'renderMemory' can write. It formats
-- the result again and compares it with the input. This rejects a leading
-- space and a leap second such as @:60@, which 'parseTimeM' alone accepts.
-- Returns 'BadHeaderValue' for any other text.
parseTime :: Text -> Either MemoryParseError UTCTime
parseTime t = case parseTimeM False defaultTimeLocale timeFormat (T.unpack t) of
  Just u | formatTime defaultTimeLocale timeFormat u == T.unpack t -> Right u
  _ -> Left (BadHeaderValue "created" t)

-- | Read the edge headers of a memory.
--
-- Each value must be a valid 'Id'. Two equal lines are one edge. If more
-- than one header has a bad value, the error is for the first kind in the
-- order of 'EdgeType'. A bad value gives 'BadLink' with the name of the
-- header.
parseEdges :: Map Text [Text] -> Either MemoryParseError (Set Edge)
parseEdges m = Set.fromList . concat <$> traverse forKind [minBound .. maxBound]
  where
    forKind :: EdgeType -> Either MemoryParseError [Edge]
    forKind k = traverse (parseOne k) (Map.findWithDefault [] (edgeToHeader k) m)

    parseOne :: EdgeType -> Text -> Either MemoryParseError Edge
    parseOne k v = fmap (Edge k) $ first (BadLink (edgeToHeader k)) $ Id.parse v

-- | Read a memory from the bytes of a file.
--
-- The headers must be in the canonical order of 'renderMemory'. The function
-- reports the first problem that it finds, and each problem has its own
-- 'MemoryParseError'. A file that is valid but not canonical gives 'NotCanonical'.
--
-- For every memory @m@ that 'mkMemory' made,
-- @parseMemory (renderMemory m) == Right m@. For every file @bs@ with
-- @parseMemory bs == Right m@, @renderMemory m == bs@.
parseMemory :: ByteString -> Either MemoryParseError Memory
parseMemory bs = do
  text <- first (const BadEncoding) $ decodeUtf8' bs
  (hdrs, body) <- splitBody text
  pairs <- traverse splitHeader (T.splitOn "\n" hdrs)
  groups <- groupHeaders pairs
  kind' <- single "kind" groups
  createdText <- single "created" groups
  agent' <- single "agent" groups
  created' <- parseTime createdText
  edges' <- parseEdges groups
  m <- first (\(InvalidField n v) -> BadHeaderValue n v) (mkMemory kind' created' agent' edges' body)
  if renderMemory m == bs then Right m else Left NotCanonical

-- | The 'Id' of a memory: the hash of its canonical form.
memoryId :: Memory -> Id
memoryId = hashBytes . renderMemory

-- | The graph of one memory: the memory is a node, and each edge of the
-- memory is an edge of the graph. Join these graphs with '<>' to build the
-- graph of the store.
memoryGraph :: Memory -> Graph
memoryGraph m = Graph.singleton (memoryId m) (Set.toList (memEdges m))
