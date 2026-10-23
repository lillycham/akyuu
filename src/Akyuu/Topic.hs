{-# LANGUAGE OverloadedStrings #-}

-- | Topics: the part of the store that an agent sees when it speaks in
-- topics and in plain text.
--
-- A topic is a ref and the current memory that it names. An agent that uses
-- topics never types an id. The one exception is the version of a topic, a
-- token that 'versionToken' makes from the id and that the agent copies back
-- to rewrite the whole text.
--
-- This module is pure. It says which refs are logs, which topics are close
-- to a text, which names are close to a typo, and how a topic is shown.
-- "Akyuu.Ops" reads the store and calls it.
module Akyuu.Topic
  ( -- * Logs
    isLogTopic,

    -- * Versions
    versionToken,
    tokenPrefix,

    -- * Near topics and names
    closeTopics,
    suggestNames,

    -- * Showing a topic
    Entry (..),
    cutText,
    renderEntry,
    renderTopic,
    noMatch,

    -- * Answers of the writers
    renderMade,
    renderAdded,
    renderRevised,
    renderReplaced,
    renderNoted,
    changedLines,
  )
where

import Akyuu.Amend (Edit (Replace))
import Akyuu.Check (jaccard, normalise, shingles)
import Akyuu.Fuzzy (editDistance)
import Akyuu.Graph (Edge (Edge), EdgeType (Follows))
import Akyuu.Id (Id)
import Akyuu.Id qualified as Id
import Akyuu.Memory (Memory (memAgent, memBody, memCreated, memEdges, memKind))
import Akyuu.Refs (Name, nameText)
import Data.Char (isDigit, isHexDigit, isSpace, toLower)
import Data.List (sortOn)
import Data.Ord (Down (Down))
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (defaultTimeLocale, formatTime)

-- Logs -----------------------------------------------------------------

-- | Is the ref a log? A log keeps its chain of episodes, so a topic verb must
-- not replace its newest memory. The first argument is the refs that the
-- @log@ lines of the manifest name.
--
-- A ref is a log if one of these holds:
--
-- * its memory has a @follows@ edge: every episode after the first has one;
-- * the manifest names it: this finds a log of one episode;
-- * its name ends in @.l@ and a number: the summary levels of a log
--   ("Akyuu.Levels").
--
-- An old log that links its episodes with one @derived_from@ edge is not
-- found: a fact with one evidence link looks the same. A log of one episode
-- that no @log@ line names is not found either.
isLogTopic :: [Name] -> Name -> Memory -> Bool
isLogTopic logs n m = followsEdge || n `elem` logs || levelName
  where
    followsEdge = any (\(Edge k _) -> k == Follows) (Set.toList (memEdges m))
    levelName = case T.breakOnEnd ".l" (nameText n) of
      (before, digits) -> T.length before > 2 && not (T.null digits) && T.all isDigit digits

-- Versions -------------------------------------------------------------

-- | The version of a topic, as an agent sees it: the first 12 hex digits of
-- the id, without the @sha256-@ prefix.
versionToken :: Id -> Text
versionToken = T.take 12 . T.drop (T.length "sha256-") . Id.render

-- | The start of an id that a version stands for. The version must have at
-- least 8 hex digits, as 'versionToken' makes it. White space around it and
-- the @sha256-@ prefix are accepted.
tokenPrefix :: Text -> Either Text Text
tokenPrefix raw
  | T.length t >= 8 && T.all isHexDigit t = Right ("sha256-" <> T.map toLower t)
  | otherwise = Left "The version must be 8 or more hex digits, as recall shows it. Call recall with the topic to get it."
  where
    s = T.strip raw
    t = maybe s id (T.stripPrefix "sha256-" s)

-- Near topics and names ------------------------------------------------

-- | The topics whose text is close to a new text, the closest first, at most
-- three. Close means that at least a fifth of the word triples are shared
-- ('Akyuu.Check.jaccard'). This is advice, not a test of duplicates: a
-- duplicate needs most of the text to be the same.
closeTopics :: Text -> [(Name, Text)] -> [Name]
closeTopics new topics =
  take 3 (map fst (sortOn (\(n, s) -> (Down s, n)) [(n, s) | (n, t) <- topics, let s = score t, s >= 0.2]))
  where
    mine = shingles (normalise new)
    score t = jaccard mine (shingles (normalise t))

-- | The names that are near a name that does not exist, the nearest first,
-- at most three. A name is near if it is a few edits away
-- ('Akyuu.Fuzzy.editDistance'): a typo, a swapped letter, a missing part.
suggestNames :: Name -> [Name] -> [Name]
suggestNames wanted names =
  take 3 (map snd (sortOn fst [(d, n) | n <- names, let d = editDistance (nameText wanted) (nameText n), d > 0, d <= limit]))
  where
    limit = max 2 (T.length (nameText wanted) `div` 4)

-- Showing a topic ------------------------------------------------------

-- | A memory that a search found, with the topic that holds it. A memory
-- that no ref holds, such as an episode of a log, has no topic.
data Entry = Entry
  { entryTopic :: Maybe Name,
    entryMemory :: Memory
  }
  deriving (Eq, Show)

-- | Cut a text to about this many characters, at a space if one is near the
-- end. The flag says whether anything was cut.
cutText :: Int -> Text -> (Text, Bool)
cutText n t
  | T.length t <= n = (t, False)
  | otherwise = (if T.length atSpace * 2 >= n then T.stripEnd atSpace else h, True)
  where
    h = T.take n t
    atSpace = T.dropWhileEnd (not . isSpace) h

-- | One hit of a query. The text is cut at the given length, and a line says
-- how to read the whole topic.
renderEntry :: Int -> Entry -> Text
renderEntry n (Entry topic m) =
  T.intercalate "\n" (header : text : [hint | cut, Just hint <- [more]])
  where
    header = case topic of
      Just t -> "topic " <> nameText t <> " (" <> facts m <> ")"
      Nothing -> "not held by a topic (" <> facts m <> ")"
    (text, cut) = cutText n (T.strip (memBody m))
    more = (\t -> "[cut: call recall with topic " <> nameText t <> " to read the whole text]") <$> topic

-- | A topic with its whole text, its version, and the topics that it is
-- about and that are about it.
renderTopic :: Name -> Id -> Memory -> [Name] -> [Name] -> Text
renderTopic n i m about mentions =
  T.intercalate
    "\n"
    ( ["topic " <> nameText n, "version: " <> versionToken i, facts m, "", T.stripEnd (memBody m)]
        <> ["" | not (null about && null mentions)]
        <> ["about: " <> names about | not (null about)]
        <> ["mentioned by: " <> names mentions | not (null mentions)]
    )
  where
    names = T.intercalate ", " . map nameText

-- | The answer of a query that finds nothing.
noMatch :: Text
noMatch = "No topic matches."

-- Answers of the writers -----------------------------------------------

-- | The answer of @remember@: the topic, its version, and the topics with
-- similar text, if there are any.
renderMade :: Name -> Id -> [Name] -> Text
renderMade n i close =
  T.intercalate "\n" $
    ["Made topic " <> nameText n <> ".", versionLine i]
      <> ["Topics with similar text, in case this repeats one: " <> T.intercalate ", " (map nameText close) <> "." | not (null close)]

-- | The answer of @add_to@.
renderAdded :: Name -> Id -> Text
renderAdded n i = T.intercalate "\n" ["Added to topic " <> nameText n <> ".", versionLine i]

-- | The answer of @revise@. The lines that the edits changed are shown, so
-- that the agent can see what the patch made of the text.
renderRevised :: Name -> Id -> [Text] -> Text
renderRevised n i ls
  | null ls = T.intercalate "\n" ["Revised topic " <> nameText n <> ".", versionLine i]
  | otherwise = T.intercalate "\n" (["Revised topic " <> nameText n <> ". The changed lines now read:"] <> ls <> [versionLine i])

-- | The answer of @replace@.
renderReplaced :: Name -> Id -> Text
renderReplaced n i = T.intercalate "\n" ["Replaced the text of topic " <> nameText n <> ".", versionLine i]

-- | The answer of @note@. It names the log and no memory.
renderNoted :: Name -> Text
renderNoted n = "Noted in " <> nameText n <> "."

-- | The lines of a text that hold the new text of a replacement, at most ten,
-- each once. A replacement that only deletes shows no line.
changedLines :: [Edit] -> Text -> [Text]
changedLines edits body =
  take 10 (nubOrdered [l | l <- T.lines body, any (`T.isInfixOf` l) tos])
  where
    tos = [t | Replace _ t <- edits, not (T.null (T.strip t))]
    nubOrdered = foldr (\x acc -> x : filter (/= x) acc) []

versionLine :: Id -> Text
versionLine i = "version: " <> versionToken i

-- The kind, the author and the time of a memory, on one line.
facts :: Memory -> Text
facts m = memKind m <> ", by " <> memAgent m <> ", " <> T.pack (formatTime defaultTimeLocale "%Y-%m-%d %H:%MZ" (memCreated m))
