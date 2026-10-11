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
module Akyuu.Tier
  ( Manifest,
    TierError (..),
    parseManifest,
    tierNames,
    tierRefs,
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
newtype Manifest = Manifest (Map Text [Name])
  deriving (Eq, Show)

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
parseManifest t = Manifest . Map.map nub . Map.fromListWith (flip (<>)) . concat <$> traverse line (zip [1 ..] (T.lines t))
  where
    line (n, raw)
      | T.null s || "#" `T.isPrefixOf` s = Right []
      | otherwise = case T.breakOn ":" s of
          (_, rest) | T.null rest -> Left (NoColon n s)
          (name, rest)
            | T.null (T.strip name) || T.any isSpace (T.strip name) -> Left (BadTierName n name)
            | otherwise -> do
                refs <- traverse (\r -> first (BadTierRef n r) (mkName r)) (words' (T.drop 1 rest))
                Right [(T.strip name, refs)]
      where
        s = T.strip raw
    words' = filter (not . T.null) . T.split (\c -> isSpace c || c == ',')

-- | The names of the tiers, sorted.
tierNames :: Manifest -> [Text]
tierNames (Manifest m) = Map.keys m

-- | The refs of a tier, in order. 'Nothing' if the manifest has no such tier.
tierRefs :: Text -> Manifest -> Maybe [Name]
tierRefs n (Manifest m) = Map.lookup n m
