{-# LANGUAGE OverloadedStrings #-}

-- | Tiers: named sets of refs that a session reads at the start.
--
-- A tier says "these memories are always wanted". The profile of the person
-- and the policy of the store are in one, so no memory needs a link to them,
-- and a session can get all of them in one call (@context@).
--
-- The tiers are written in a manifest. The manifest is a memory in the store,
-- under a ref, so that an agent can read it and change it with the normal
-- tools, and so that it has a history like any memory. This module is pure:
-- it reads the text of a manifest.
--
-- The format of the manifest is one line for each group of refs:
--
-- > # A comment.
-- > always: claude/profile claude/preferences claude/memory-policy
-- > background: claude/values, claude/thinking
--
-- A line is a tier name, a colon, and ref names that white space or commas
-- separate. A tier can have more than one line. A ref that appears twice in a
-- tier counts once, at its first place. Blank lines and lines that start
-- with @#@ are skipped.
--
-- Two more kinds of line say where a session is. The part before the colon
-- is the word @at@ or @log@ and a directory. A directory may start with
-- @~@, and it matches itself and the directories below it.
--
-- > at ~/devel/akyuu: claude/projects/akyuu
-- > log ~/devel/akyuu: claude/log/akyuu
-- > log *: claude/log/general
--
-- An @at@ line adds refs to the context of a session that works in that
-- directory. A @log@ line names the log that a note goes to. The most
-- specific @log@ line wins, and @*@ matches every directory.
module Akyuu.Tier
  ( Manifest,
    TierError (..),
    Place (..),
    parseManifest,
    tierNames,
    tierRefs,
    placeRefs,
    placeLog,
    placeLines,
  )
where

import Akyuu.Refs (Name, NameError, mkName)
import Data.Bifunctor (first)
import Data.Char (isSpace)
import Data.List (nub)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T

-- | The tiers of a store, with the refs of each one in order.
data Manifest = Manifest
  { manTiers :: Map Text [Name],
    -- | The directory of each @at@ line, as written, with its refs.
    manAt :: [(Text, [Name])],
    -- | The directory of each @log@ line, as written, with its ref.
    manLog :: [(Text, Name)]
  }
  deriving (Eq, Show)

-- | Where a session works: the home directory of the person, to read @~@,
-- and the current directory.
data Place = Place
  { placeHome :: Text,
    placeDir :: Text
  }
  deriving (Eq, Show)

-- | One line of a manifest.
data Line
  = Tier Text [Name]
  | At Text [Name]
  | Log Text Name

-- | Why 'parseManifest' refuses a manifest. Each case has the number of the
-- line, counted from 1.
data TierError
  = -- | A line has no colon.
    NoColon Int Text
  | -- | The tier name before the colon is empty, or has white space.
    BadTierName Int Text
  | -- | A ref name is not valid.
    BadTierRef Int Text NameError
  deriving (Eq, Show)

-- | Read a manifest. The first problem is the result.
parseManifest :: Text -> Either TierError Manifest
parseManifest t = build . concat <$> traverse line (zip [1 ..] (T.lines t))
  where
    build ls =
      Manifest
        { manTiers = Map.map nub (Map.fromListWith (flip (<>)) [(n, rs) | Tier n rs <- ls]),
          manAt = [(d, rs) | At d rs <- ls],
          manLog = [(d, r) | Log d r <- ls]
        }
    line (n, raw)
      | T.null s || "#" `T.isPrefixOf` s = Right []
      | otherwise = case T.breakOn ":" s of
          (_, rest) | T.null rest -> Left (NoColon n s)
          (name, rest)
            | T.null (T.strip name) -> Left (BadTierName n name)
            | Just d <- directive "at" name -> do
                refs <- traverse (\r -> first (BadTierRef n r) (mkName r)) (words' (T.drop 1 rest))
                Right [At d refs]
            | Just d <- directive "log" name -> do
                refs <- traverse (\r -> first (BadTierRef n r) (mkName r)) (words' (T.drop 1 rest))
                case refs of
                  [r] -> Right [Log d r]
                  _ -> Left (BadTierName n name)
            | T.any isSpace (T.strip name) -> Left (BadTierName n name)
            | otherwise -> do
                refs <- traverse (\r -> first (BadTierRef n r) (mkName r)) (words' (T.drop 1 rest))
                Right [Tier (T.strip name) refs]
      where
        s = T.strip raw
    -- "at DIR": the keyword, white space, then a directory.
    directive kw name = case T.words (T.strip name) of
      (w : _) | w == kw, let d = T.strip (T.drop (T.length kw) (T.strip name)), not (T.null d) -> Just d
      _ -> Nothing
    words' = filter (not . T.null) . T.split (\c -> isSpace c || c == ',')

-- | The names of the tiers, sorted.
tierNames :: Manifest -> [Text]
tierNames = Map.keys . manTiers

-- | How many @at@ lines and @log@ lines the manifest has.
placeLines :: Manifest -> (Int, Int)
placeLines m = (length (manAt m), length (manLog m))

-- | The refs of a tier, in order. 'Nothing' if the manifest has no such tier.
tierRefs :: Text -> Manifest -> Maybe [Name]
tierRefs n = Map.lookup n . manTiers

-- | Does a directory that a line names contain the place? The directory
-- and the place are the same, or the place is below it. @*@ contains all.
contains :: Place -> Text -> Bool
contains p d
  | d == "*" = True
  | otherwise = here == dir || (dir <> "/") `T.isPrefixOf` here
  where
    dir = T.dropWhileEnd (== '/') (expand d)
    here = T.dropWhileEnd (== '/') (placeDir p)
    expand x = case T.stripPrefix "~" x of
      Just rest | T.null rest || "/" `T.isPrefixOf` rest -> placeHome p <> rest
      _ -> x

-- | The refs of the @at@ lines that contain the place, in the order of the
-- manifest, with a ref once.
placeRefs :: Place -> Manifest -> [Name]
placeRefs p m = nub (concat [rs | (d, rs) <- manAt m, contains p d])

-- | The ref of the @log@ line that contains the place and names the longest
-- directory. 'Nothing' if no line contains it.
placeLog :: Place -> Manifest -> Maybe Name
placeLog p m = case [(specific d, r) | (d, r) <- manLog m, contains p d] of
  [] -> Nothing
  xs -> Just (snd (foldl1 (\a b -> if fst b >= fst a then b else a) xs))
  where
    specific d = if d == "*" then 0 else T.length d + 1 :: Int
