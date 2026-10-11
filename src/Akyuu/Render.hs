-- | Text for a person, from the results of "Akyuu.Ops".
--
-- The CLI prints these lines, and the MCP server sends them as the text of a
-- tool result, so both front ends show the same thing. Each function returns
-- a list of lines with no line feeds. This module is pure.
--
-- An 'Id' always starts its line, or follows a fixed word, so a script can
-- cut it out.
module Akyuu.Render
  ( memoryText,
    refLines,
    refListLines,
    pinLines,
    unpinLines,
    pinListLines,
    searchLines,
    neighbourLines,
    planLines,
    runLines,
    syncLines,
    verifyLines,
    edgeName,
    dirName,
  )
where

import Akyuu.Cache (SyncReport (..))
import Akyuu.Error (describe, describeParse)
import Akyuu.Error qualified as Error
import Akyuu.GC (RunReport (..), SweepReport (..))
import Akyuu.Graph (Dir (..), EdgeType)
import Akyuu.Id (Id, render)
import Akyuu.Memory (Memory, edgeToHeader, renderMemory)
import Akyuu.Ops (VerifyReport (..), verifyOk)
import Akyuu.Query (Match (..), Neighbour (..), SearchResult (..))
import Akyuu.Refs (Name, Ref (..), nameText)
import Data.List (sort)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (decodeUtf8)

-- | A memory in the file format of the store, as text. The store holds
-- UTF-8, so the decode cannot fail.
memoryText :: Memory -> Text
memoryText = decodeUtf8 . renderMemory

-- | The name of a kind of edge, as in the file format: @supersedes@,
-- @about@, @derived-from@ or @refines@.
edgeName :: EdgeType -> Text
edgeName = edgeToHeader

-- | @out@ or @in@.
dirName :: Dir -> Text
dirName Out = "out"
dirName In = "in"

-- | A ref: the current 'Id', and with 'True' also the older values, newest
-- first, one on each line.
refLines :: Bool -> Ref -> [Text]
refLines withHistory r =
  render (current r) : (if withHistory then map render (history r) else [])

-- | A search result. One line for each hit: the 'Id', two spaces, and the
-- snippet on one line. A hit that a newer memory replaces gets one more line,
-- @  superseded by ID@, for each newer memory. Then the context, if there is
-- one: a line @context:@ and one 'Id' on each line.
--
-- An empty result gives no lines.
searchLines :: SearchResult -> [Text]
searchLines r = concatMap matchLines (matches r) <> contextLines
  where
    matchLines m =
      (render (matchId m) <> "  " <> oneLine (matchSnippet m))
        : ["  superseded by " <> render i | i <- Set.toAscList (matchSupersededBy m)]
    contextLines
      | Set.null (context r) = []
      | otherwise = "context:" : map render (Set.toAscList (context r))
    oneLine = T.unwords . T.words

-- | The edges of a memory, one on each line: the direction, the kind and
-- the other 'Id', for example @out about sha256-…@.
neighbourLines :: [Neighbour] -> [Text]
neighbourLines = map line
  where
    line n = T.unwords [dirName (neighbourDir n), edgeName (neighbourKind n), render (neighbourId n)]

-- | The plan of a dry run: the 'Id' values that a run would move to trash,
-- then a count.
planLines :: Set Id -> [Text]
planLines s =
  map render (Set.toAscList s)
    <> ["would collect " <> count (Set.size s) "object"]

-- | What a GC run did.
runLines :: RunReport -> [Text]
runLines r =
  ["trashed " <> render i | i <- sort (trashed (swept r))]
    <> ["deleted " <> render i | i <- sort (deleted (swept r))]
    <> [ "moved "
           <> count (length (trashed (swept r))) "object"
           <> " to trash, deleted "
           <> count (length (deleted (swept r))) "old trash file"
       ]

-- | What a sync or a reindex did.
syncLines :: SyncReport -> [Text]
syncLines r =
  ["indexed " <> count (length (added r)) "memory" <> ", removed " <> count (length (removed r)) "memory"]

-- | The report of a verify. The last line is @ok@ or the number of
-- problems.
verifyLines :: VerifyReport -> [Text]
verifyLines r =
  ["corrupt " <> render i | i <- corruptObjects r]
    <> ["unreadable " <> render i <> ": " <> describeParse p | (i, p) <- unreadableObjects r]
    <> ["missing " <> render i | i <- missingTargets r]
    <> ["bad ref " <> nameText n <> ": " <> describe (Error.RefFailed e) | (n, e) <- badRefs r]
    <> ["ref " <> nameText n <> " points to missing " <> render i | (n, i) <- refsToMissing r]
    <> ["pruned " <> count (length (prunedTargets r)) "target" <> " (GC deleted them, this is normal)" | not (null (prunedTargets r))]
    <> [summary]
  where
    summary
      | verifyOk r = "ok: checked " <> count (checkedObjects r) "object"
      | otherwise = "problems found: checked " <> count (checkedObjects r) "object"

-- | A number and a noun, with the plural for a number that is not 1.
count :: Int -> Text -> Text
count 1 noun = "1 " <> noun
count n noun = T.pack (show n) <> " " <> plural noun
  where
    plural w
      | "y" `T.isSuffixOf` w = T.dropEnd 1 w <> "ies"
      | otherwise = w <> "s"

-- | A list of refs: one line for each, the name, two spaces and the 'Id'
-- that the ref points to now. This is the one list that starts a line with
-- a name and not an 'Id'. A name has no space, so a script can split the
-- line at the first space. An empty list gives no lines.
refListLines :: [(Name, Id)] -> [Text]
refListLines = map (\(n, i) -> nameText n <> "  " <> render i)

-- | The answer of @pin@: the word @pinned@ and the 'Id'.
pinLines :: Id -> [Text]
pinLines i = ["pinned " <> render i]

-- | The answer of @unpin@: the word @unpinned@ and the 'Id'.
unpinLines :: Id -> [Text]
unpinLines i = ["unpinned " <> render i]

-- | The pins: one 'Id' on each line. An empty list gives no lines.
pinListLines :: [Id] -> [Text]
pinListLines = map render
