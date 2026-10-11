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
    searchLinesWith,
    embedLines,
    evalLines,
    heldBy,
    refListLinesWith,
    shortIds,
    snippetText,
    neighbourLines,
    planLines,
    runLines,
    syncLines,
    findingLines,
    findingJSON,
    compareLines,
    compareJSON,
    reviewLines,
    tierLines,
    logLines,
    verifyLines,
    edgeName,
    dirName,
  )
where

import Akyuu.Cache (Correction (AddedByMeaning, MeaningUnavailable, PrefixOf, SpelledAs), SyncReport (added, removed), snippetClose, snippetOpen)
import Akyuu.Check (Finding (findingIds, findingKind, findingRelated, findingSeverity, findingWhy), kindName, severityName)
import Akyuu.Compare (Comparison (cmpOnlyA, cmpOnlyB, cmpShared), canDropA, canDropB)
import Akyuu.Episode (Walk (Walk))
import Akyuu.Error (describe, describeParse)
import Akyuu.Error qualified as Error
import Akyuu.GC (RunReport (swept), SweepReport (deleted, trashed))
import Akyuu.Graph (Dir (In, Out), EdgeType)
import Akyuu.Id (Id, render)
import Akyuu.Memory (Memory (memAgent, memBody, memCreated, memKind), edgeToHeader, renderMemory)
import Akyuu.Ops (CompareReport (CompareReport), CompareSide (CompareSide), ContextEntry (Absent, Present), ContextReport (ContextReport), EmbedReport (already, embedFailed, embedded), EvalRow (evalCase, evalFound), SearchMode (Fused, MeaningOnly, TextOnly), VerifyReport (badRefs, checkedObjects, corruptObjects, missingTargets, prunedTargets, refsToMissing, unreadableObjects), verifyOk)
import Akyuu.Query (Match (matchId, matchSnippet, matchSupersededBy), Neighbour (neighbourDir, neighbourId, neighbourKind), SearchResult (context, corrections, matches))
import Akyuu.Refs (Name, Ref (current, history), nameText)
import Akyuu.Review (Review (reviewAgent, reviewAt, reviewNote))
import Akyuu.SearchEval (Case (caseCategory, caseGuess, caseQuery), passes)
import Data.Aeson (Value, object, (.=))
import Data.List (sort)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (decodeUtf8)
import Data.Time (defaultTimeLocale, formatTime)

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
searchLines = searchLinesWith Map.empty

-- | Like 'searchLines', and a hit that a ref holds gets one more line,
-- @  held by NAME, NAME@. See 'heldBy'.
searchLinesWith :: Map Id [Name] -> SearchResult -> [Text]
searchLinesWith held r = concatMap matchLines (matches r) <> contextLines <> map correctionLine (corrections r)
  where
    correctionLine (PrefixOf w) = "note: no whole word " <> quoted w <> ", so it was searched as the start of a word."
    correctionLine (SpelledAs w ts) = "note: no word " <> quoted w <> ", so it was searched as " <> T.intercalate " or " (map quoted ts) <> "."
    correctionLine (AddedByMeaning n) = "note: " <> T.pack (show n) <> " of these were found by meaning, not by the words."
    correctionLine (MeaningUnavailable why) = "note: the search by meaning did not run, so this is a text search only. " <> why
    quoted t = "'" <> t <> "'"
    matchLines m =
      (render (matchId m) <> "  " <> oneLine (snippetText (matchSnippet m)))
        : ["  held by " <> T.intercalate ", " (map nameText ns) | Just ns <- [Map.lookup (matchId m) held]]
          <> ["  superseded by " <> render i | i <- Set.toAscList (matchSupersededBy m)]
    contextLines
      | Set.null (context r) = []
      | otherwise = "context:" : map render (Set.toAscList (context r))
    oneLine = T.unwords . T.words

-- | A snippet as text for a person: each match is in square brackets, for
-- example @Lilly prefers [Haskell] for the@.
--
-- A snippet from 'Akyuu.Cache.search' has the marks 'snippetOpen' and
-- 'snippetClose'. A bracket in the text of the body gets a backslash, so a
-- body with @[x]@ does not look like a match. The text has no other change.
-- This function is pure.
snippetText :: Text -> Text
snippetText = T.concatMap f
  where
    f c
      | c == snippetOpen = "["
      | c == snippetClose = "]"
      | c == '[' = "\\["
      | c == ']' = "\\]"
      | otherwise = T.singleton c

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

-- | What @embed@ did: the counts, and the memories that failed.
embedLines :: Text -> EmbedReport -> [Text]
embedLines model r =
  ["failed " <> render i <> ": " <> why | (i, why) <- embedFailed r]
    <> [ "embedded "
           <> count (embedded r) "memory"
           <> " with "
           <> model
           <> ", "
           <> T.pack (show (already r))
           <> " had one already"
           <> (if null (embedFailed r) then "" else ", " <> T.pack (show (length (embedFailed r))) <> " failed")
       ]

-- | The result of a set of searches: one line for each case with the mark
-- of each mode (@ found, @ not), then the number of passes of each mode
-- for each category.
evalLines :: Int -> [EvalRow] -> [Text]
evalLines k rows = concatMap one rows <> [""] <> concatMap summary cats
  where
    modes = [minBound .. maxBound] :: [SearchMode]
    modeName TextOnly = "text"
    modeName Fused = "fused"
    modeName MeaningOnly = "meaning"
    verdict r m = maybe False (passes (evalCase r) . take k) (lookup m (evalFound r))
    one r =
      T.unwords [mark (verdict r m) <> modeName m | m <- modes] <> "  " <> caseCategory (evalCase r) <> " | " <> caseQuery (evalCase r) <> (if caseGuess (evalCase r) then " (?)" else "")
        : ["    " <> modeName m <> ": " <> (if null fs then "(no hits)" else T.intercalate ", " (take k fs)) | (m, fs) <- evalFound r, not (verdict r m)]
    mark True = "+"
    mark False = "-"
    cats = dedupe (map (caseCategory . evalCase) rows)
    dedupe = foldr (\x acc -> x : filter (/= x) acc) []
    summary c =
      let rs = [r | r <- rows, caseCategory (evalCase r) == c]
       in [c <> " (" <> T.pack (show (length rs)) <> "): " <> T.intercalate ", " [modeName m <> " " <> T.pack (show (length (filter (`verdict` m) rs))) | m <- modes]]

-- | The refs that hold each memory now, from the list of refs.
heldBy :: [(Name, Id)] -> Map Id [Name]
heldBy rs = Map.fromListWith (flip (<>)) [(i, [n]) | (n, i) <- rs]

-- | Like 'refListLines', with the first line of each memory at the end of
-- its line. A memory that is not in the map has no such part.
refListLinesWith :: Map Id Text -> [(Name, Id)] -> [Text]
refListLinesWith firsts = map line
  where
    line (n, i) = T.intercalate "  " ([nameText n, render i] <> maybe [] pure (Map.lookup i firsts))

-- | Cut each whole id in a text to its first 12 hex digits. The result is
-- for an agent that reads a list: a prefix of 8 digits or more names the
-- memory again (see the tool descriptions). Text that is not a whole id
-- stays as it is.
shortIds :: Text -> Text
shortIds t = case T.breakOn "sha256-" t of
  (before, rest)
    | T.null rest -> before
    | otherwise ->
        let (pre, afterPre) = T.splitAt 7 rest
            (digits, tail') = T.span isHex afterPre
         in before <> pre <> (if T.length digits == 64 then T.take 12 digits else digits) <> shortIds tail'
  where
    isHex c = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')

-- | The answer of @pin@: the word @pinned@ and the 'Id'.
pinLines :: Id -> [Text]
pinLines i = ["pinned " <> render i]

-- | The answer of @unpin@: the word @unpinned@ and the 'Id'.
unpinLines :: Id -> [Text]
unpinLines i = ["unpinned " <> render i]

-- | The pins: one 'Id' on each line. An empty list gives no lines.
pinListLines :: [Id] -> [Text]
pinListLines = map render

-- Check ----------------------------------------------------------------

-- | The findings of @check@. Each one is a line with the severity, the kind
-- and the reason, then one line for each memory. A memory that a ref names
-- shows the ref in brackets. An empty list gives one line that says so.
findingLines :: [(Name, Id)] -> [Finding] -> [Text]
findingLines _ [] = ["No findings."]
findingLines refs fs = concatMap one fs
  where
    names :: Map Id [Text]
    names = Map.fromListWith (flip (<>)) [(i, [nameText n]) | (n, i) <- refs]
    label i = render i <> maybe "" (\ns -> " (" <> T.intercalate ", " ns <> ")") (Map.lookup i names)
    one f =
      ("[" <> severityName (findingSeverity f) <> "] " <> kindName (findingKind f) <> ": " <> findingWhy f)
        : ["  " <> label i | i <- findingIds f]
          <> ["  read: " <> label i | i <- findingRelated f]

-- | One finding as JSON, for scripts and for the web page.
findingJSON :: Finding -> Value
findingJSON f =
  object
    [ "kind" .= kindName (findingKind f),
      "severity" .= severityName (findingSeverity f),
      "ids" .= map render (findingIds f),
      "related" .= map render (findingRelated f),
      "why" .= findingWhy f
    ]

-- Compare --------------------------------------------------------------

-- | The text of @compare@: who the two memories are, how much they share,
-- the sentences that only one of them has, and whether either can be dropped
-- in favour of the other.
compareLines :: CompareReport -> [Text]
compareLines (CompareReport a b c) =
  [side "A" a, side "B" b, "shared: " <> T.pack (show (round (100 * cmpShared c) :: Int)) <> "% of word triples"]
    <> only "A" (cmpOnlyA c)
    <> only "B" (cmpOnlyB c)
    <> [drop' "A" "B" (canDropA c), drop' "B" "A" (canDropB c)]
  where
    side tag (CompareSide i m rs) =
      tag
        <> " "
        <> render i
        <> (if null rs then "" else " (" <> T.intercalate ", " (map nameText rs) <> ")")
        <> "  kind: "
        <> memKind m
        <> "  agent: "
        <> memAgent m
        <> "  created: "
        <> T.pack (formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" (memCreated m))
    only tag xs =
      ("only in " <> tag <> " (" <> T.pack (show (length xs)) <> "):") : ["  - " <> x | x <- xs]
    drop' from to ok
      | ok = from <> " can be dropped in favour of " <> to <> ": all its text is in " <> to <> "."
      | otherwise = from <> " cannot be dropped in favour of " <> to <> ": it has text that " <> to <> " lacks."

-- | The same facts as JSON.
compareJSON :: CompareReport -> Value
compareJSON (CompareReport a b c) =
  object
    [ "a" .= side a,
      "b" .= side b,
      "shared" .= cmpShared c,
      "onlyA" .= cmpOnlyA c,
      "onlyB" .= cmpOnlyB c,
      "canDropA" .= canDropA c,
      "canDropB" .= canDropB c
    ]
  where
    side (CompareSide i m rs) =
      object
        [ "id" .= render i,
          "refs" .= map nameText rs,
          "kind" .= memKind m,
          "agent" .= memAgent m,
          "created" .= formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" (memCreated m)
        ]

-- Reviews --------------------------------------------------------------

-- | The reviewed pairs. Each one is a line with the two ids, then who judged
-- it and when, and the note if there is one.
reviewLines :: [((Id, Id), Review)] -> [Text]
reviewLines = concatMap one
  where
    one ((a, b), r) =
      (render a <> " " <> render b)
        : ("  by " <> reviewAgent r <> " at " <> T.pack (formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" (reviewAt r)))
        : ["  " <> reviewNote r | not (T.null (reviewNote r))]

-- Context --------------------------------------------------------------

-- | The text of @context@. Each memory has a line @== REF (ID)@, then its
-- body, then a blank line. A ref that the manifest names and the store lacks
-- has one line. The last line lists the other refs.
tierLines :: ContextReport -> [Text]
tierLines (ContextReport tier es others) =
  ("tier: " <> tier) : concatMap entry es <> ["other refs: " <> if null others then "none" else T.intercalate ", " (map nameText others)]
  where
    entry (Present n i m) = ["== " <> nameText n <> " (" <> render i <> ")"] <> T.lines (memBody m) <> [""]
    entry (Absent n) = ["== " <> nameText n <> ": the manifest names it, and there is no such ref.", ""]

-- Episodes -------------------------------------------------------------

-- | The episodes of a log, newest first. Each one is a line with the id, the
-- time, the agent, the kind and the first line of the body. With @full@, the
-- body follows, indented. A last line @more: ID@ says that the log goes on
-- from that episode.
logLines :: Bool -> Walk -> [Text]
logLines full (Walk es more) = concatMap one es <> maybe [] (\i -> ["more: " <> render i]) more
  where
    one (i, m) =
      T.intercalate "  " [render i, T.pack (formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" (memCreated m)), memAgent m, memKind m, firstLine (memBody m)]
        : ["  " <> l | full, l <- T.lines (memBody m)]
    firstLine b = case filter (not . T.null) (map T.strip (T.lines b)) of
      (l : _) | T.length l > 100 -> T.take 99 l <> "…"
      (l : _) -> l
      [] -> ""
