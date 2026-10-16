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
    idLine,
    refLines,
    refListLines,
    pinLines,
    unpinLines,
    pinListLines,
    searchLines,
    searchLinesWith,
    embedLines,
    statusLines,
    configLines,
    evalLines,
    heldBy,
    refListLinesWith,
    shortIds,
    snippetText,
    neighbourLines,
    refLinkLines,
    planLines,
    runLines,
    syncLines,
    findingLines,
    findingJSON,
    compareLines,
    compareJSON,
    reviewLines,
    tierLines,
    tierLinesWithin,
    tierPage,
    logLines,
    verifyLines,
    edgeName,
    dirName,
  )
where

import Akyuu.Cache (Correction (AddedByMeaning, MeaningUnavailable, PrefixOf, SpelledAs), SyncReport (added, removed), snippetClose, snippetOpen)
import Akyuu.Check (Finding (findingIds, findingKind, findingRelated, findingSeverity, findingWhy), kindName, severityName)
import Akyuu.Compare (Comparison (cmpOnlyA, cmpOnlyB, cmpShared), canDropA, canDropB)
import Akyuu.Config (Config (cfgAgent, cfgEmbed, cfgFile, cfgNotes, cfgPolicyRef, cfgRoot, cfgTiersRef), EmbedSettings (esArgs, esCommand, esDocumentPrefix, esKey, esMaxChars, esMin, esProfile, esQueryPrefix, esSource, esTimeout), Source (Default), Sourced (sSource, sValue), sourceText)
import Akyuu.Episode (Walk (Walk))
import Akyuu.Error (describe, describeParse)
import Akyuu.Error qualified as Error
import Akyuu.GC (RunReport (swept), SweepReport (deleted, trashed))
import Akyuu.Graph (Dir (In, Out), EdgeType)
import Akyuu.Id (Id, render)
import Akyuu.Memory (Memory (memAgent, memBody, memCreated, memKind), edgeToHeader, renderMemory)
import Akyuu.Ops (CompareReport (CompareReport), CompareSide (CompareSide), ContextEntry (Absent, NoManifest, Present), ContextReport (ContextReport), EmbedReport (already, embedChanged, embedFailed, embedded), EmbedStatus (ebChanged, ebKey, ebProfile, ebVectors), EvalRow (evalCase, evalFound), SearchMode (Fused, MeaningOnly, TextOnly), StatusReport (stConfig, stEmbed, stGit, stManifest, stMemories, stPins, stPolicy, stRefs, stRoot), VerifyReport (badRefs, checkedObjects, corruptObjects, missingTargets, prunedTargets, refsToMissing, unreadableObjects), verifyOk)
import Akyuu.Query (Match (matchId, matchSnippet, matchSupersededBy), Neighbour (neighbourDir, neighbourId, neighbourKind), RefLink (linkDir, linkId, linkRef), SearchResult (context, corrections, matches))
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

-- | The line that names the memory that @get@ read: the value to pass as
-- @expected@ to supersede or amend. It is not part of the stored file.
idLine :: Id -> Text
idLine i = "id: " <> render i

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
-- example @water the [tomatoes] every@.
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

-- | The about-ref links of a memory, one line each: @out about-ref NAME ID@
-- (the memory that the ref names now, or @(no such ref)@), or
-- @in about-ref NAME ID@ (the memory with the link).
refLinkLines :: [RefLink] -> [Text]
refLinkLines = map line
  where
    line l = T.unwords [dirName (linkDir l), "about-ref", nameText (linkRef l), maybe "(no such ref)" render (linkId l)]

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
    <> [changedWarning model | embedChanged r]

-- | The warning for vectors of one key from two embedders.
changedWarning :: Text -> Text
changedWarning key =
  "warning: the vectors of "
    <> key
    <> " were made by another command, other arguments or other prefixes. If the model changed, give the profile a new key, then run akyuu embed."

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

-- | The report of @status@: one line for each part, and a hint where
-- something needs doing.
statusLines :: StatusReport -> [Text]
statusLines r =
  [ "root: " <> T.pack (stRoot r),
    "memories: " <> T.pack (show (stMemories r)) <> ", refs: " <> T.pack (show (stRefs r)) <> ", pins: " <> T.pack (show (stPins r)),
    case stManifest r of
      (n, Right (tiers, (ats, logs))) -> "manifest " <> nameText n <> ": tiers " <> (if null tiers then "(none)" else T.intercalate ", " tiers) <> "; " <> T.pack (show ats) <> " at lines, " <> T.pack (show logs) <> " log lines"
      (n, Left why) -> "manifest " <> nameText n <> ": " <> why,
    case stPolicy r of
      (n, True) -> "policy " <> nameText n <> ": present"
      (n, False) -> "policy " <> nameText n <> ": missing (the MCP server tells agents to read it)",
    case stEmbed r of
      Nothing -> "search by meaning: off (no embedding profile is set)"
      Just e -> case ebVectors e of
        Right k -> "search by meaning: profile " <> ebProfile e <> ", key " <> ebKey e <> ", vectors for " <> T.pack (show k) <> " of " <> T.pack (show (stMemories r)) <> " memories" <> (if k < stMemories r then " (run akyuu embed)" else "")
        Left why -> "search by meaning: profile " <> ebProfile e <> ", key " <> ebKey e <> ", the vectors cannot be read: " <> why,
    "versioning: " <> if stGit r then "the root is a git repository" else "the root is not a git repository (akyuu-version makes one)",
    case stConfig r of
      (Nothing, 0) -> "config: no file (see akyuu config)"
      (Nothing, n) -> "config: no file; " <> count n "note" <> " (run akyuu config)"
      (Just p, 0) -> "config: " <> T.pack p
      (Just p, n) -> "config: " <> T.pack p <> "; " <> count n "note" <> " (run akyuu config)"
  ]
    <> [changedWarning (ebKey e) | Just e <- [stEmbed r], ebChanged e]

-- | The settings in effect (@akyuu config@): each one, and where it came from.
configLines :: Config -> [Text]
configLines c =
  ["file: " <> maybe "none (akyuu looks for $AKYUU_CONFIG, then ~/.config/akyuu/config.toml)" T.pack (cfgFile c)]
    <> [ setting "root" (maybe ("(not set)", Default) (\s -> (T.pack (sValue s), sSource s)) (cfgRoot c)),
         sourced "policy-ref" (cfgPolicyRef c),
         sourced "tiers-ref" (cfgTiersRef c),
         sourced "agent" (cfgAgent c)
       ]
    <> case cfgEmbed c of
      Nothing -> ["embed: off (no profile)"]
      Just e ->
        setting "embed.profile" (esProfile e, esSource e)
          : map
            (("  " <>) . pair)
            ( [ ("command", esCommand e),
                ("key", esKey e),
                ("query-prefix", quoted (esQueryPrefix e)),
                ("document-prefix", quoted (esDocumentPrefix e)),
                ("min", maybe "(none)" (T.pack . show) (esMin e)),
                ("timeout", T.pack (show (esTimeout e))),
                ("max-chars", T.pack (show (esMaxChars e)))
              ]
                <> [("args." <> k, v) | (k, v) <- esArgs e]
            )
    <> ["note: " <> n | n <- cfgNotes c]
  where
    sourced name s = setting name (sValue s, sSource s)
    setting name (v, src) = name <> " = " <> v <> "  (" <> sourceText src <> ")"
    pair (k, v) = k <> " = " <> v
    quoted t = "\"" <> t <> "\""

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
tierLines = tierLines'

-- | 'tierLines' that fits in a number of characters, for a client that cuts
-- a long text: a hook of Claude Code keeps only about 10,000 characters. It
-- is page 1 of 'tierPage'.
tierLinesWithin :: Maybe Int -> ContextReport -> [Text]
tierLinesWithin Nothing r = tierLines' r
tierLinesWithin (Just b) r = tierPage b 1 r

-- | One page of the context, for a budget of characters per page. Pages count
-- from 1. The memories are packed in their order: a page takes memories until
-- the next one does not fit, and that one starts the next page. A memory that
-- does not fit on an empty page is shown as its first line and a pointer. Page
-- 1 starts with the tier. A page that is not the last ends with a line that
-- names the next page and its refs; the last page ends with the other refs. A
-- page after the last is empty, so a second hook with page 2 prints nothing
-- when one page is enough.
tierPage :: Int -> Int -> ContextReport -> [Text]
tierPage budget k (ContextReport tier es others)
  | k < 1 || k > length pages = []
  | otherwise =
      ["tier: " <> tier | k == 1]
        <> concatMap snd (pages !! (k - 1))
        <> if k == length pages
          then footer
          else ["(more on page " <> T.pack (show (k + 1)) <> ": " <> T.intercalate ", " (map fst (concat (drop k pages))) <> ". Run context with page " <> T.pack (show (k + 1)) <> ", or read them with get.)"]
  where
    footer = ["other refs: " <> if null others then "none" else T.intercalate ", " (map nameText others)]
    room = max 200 (budget - 400)
    shown e = let full = contextEntry e in if size full <= room then full else contextBrief e
    items = [(entryName e, shown e) | e <- es]
    pages = case pack items of
      [] -> [[]]
      ps -> ps
    pack [] = []
    pack xs = let (p, rest) = takePage 0 xs in p : pack rest
    takePage _ [] = ([], [])
    takePage used (x : xs)
      | used > 0 && used + size (snd x) > room = ([], x : xs)
      | otherwise = let (p, rest) = takePage (used + size (snd x)) xs in (x : p, rest)
    size ls = sum (map ((+ 1) . T.length) ls)
    entryName (Present n _ _) = nameText n
    entryName (Absent n) = nameText n
    entryName (NoManifest n) = nameText n

tierLines' :: ContextReport -> [Text]
tierLines' (ContextReport tier es others) =
  ("tier: " <> tier) : concatMap contextEntry es <> ["other refs: " <> if null others then "none" else T.intercalate ", " (map nameText others)]

contextEntry :: ContextEntry -> [Text]
contextEntry (Present n i m) = ["== " <> nameText n <> " (" <> render i <> ")"] <> T.lines (memBody m) <> [""]
contextEntry (Absent n) = ["== " <> nameText n <> ": the manifest names it, and there is no such ref.", ""]
contextEntry (NoManifest n) = ["== no manifest: the ref " <> nameText n <> " does not exist, so no tier is read. Run akyuu init to make a policy and a manifest, or add a memory with a line such as 'always: me/profile' under that ref.", ""]

contextBrief :: ContextEntry -> [Text]
contextBrief (Present n i m) =
  [ "== " <> nameText n <> " (" <> render i <> ")",
    case filter (not . T.null) (map T.strip (T.lines (memBody m))) of
      (l : _) | T.length l > 120 -> T.take 119 l <> "…"
      (l : _) -> l
      [] -> "",
    "(" <> T.pack (show (T.length (memBody m))) <> " characters, too long for one page. Read it with get, ref " <> nameText n <> ".)",
    ""
  ]
contextBrief a = contextEntry a

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
