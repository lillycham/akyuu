-- | Pairs of memories that a person or an agent judged: "both are true and
-- they are different". @check@ does not flag such a pair again.
--
-- A review is a small file in @reviewed/@ under the root of the store, like a
-- pin. The name is the two 'Id' values, the lower one first, joined by @_@.
-- The pair is not ordered, so @review a b@ and @review b a@ are the same.
--
-- A memory never changes, and its 'Id' is the hash of its text. So a review
-- ends by itself: if either memory is replaced, the new text has a new 'Id',
-- and the new pair is flagged again. 'prune' removes the files of pairs that
-- name a memory that is no longer in the store.
module Akyuu.Review
  ( Review (..),
    Pair,
    pair,
    reviewPath,
    review,
    unreview,
    listReviews,
    prune,
  )
where

import Akyuu.Fs (atomicWrite, tryWith)
import Akyuu.Id (Id)
import Akyuu.Id qualified as Id
import Akyuu.Store (Store, storeRoot)
import Control.Exception (IOException, tryJust)
import Control.Monad (forM, guard)
import Data.ByteString qualified as BS
import Data.Map.Strict qualified as Map
import Data.Maybe (catMaybes)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (decodeUtf8', encodeUtf8)
import Data.Time (UTCTime, defaultTimeLocale, formatTime, parseTimeM)
import System.Directory (createDirectoryIfMissing, listDirectory, removeFile)
import System.FilePath ((</>))
import System.IO.Error (isDoesNotExistError)

-- | An unordered pair of memories, as the lower 'Id' and then the higher one.
type Pair = (Id, Id)

-- | Put two 'Id' values in order.
pair :: Id -> Id -> Pair
pair a b = (min a b, max a b)

-- | Who judged the pair, when, and why.
data Review = Review
  { reviewAgent :: Text,
    reviewAt :: UTCTime,
    -- | A short reason. It can be empty.
    reviewNote :: Text
  }
  deriving (Eq, Show)

reviewedDir :: Store -> FilePath
reviewedDir s = storeRoot s </> "reviewed"

-- | The file of a pair. This function is pure.
reviewPath :: Store -> Id -> Id -> FilePath
reviewPath s a b = reviewedDir s </> T.unpack (Id.render lo <> "_" <> Id.render hi)
  where
    (lo, hi) = pair a b

-- | Record that a pair is judged. Doing it twice replaces the first review.
review :: Store -> Id -> Id -> Review -> IO (Either IOException ())
review s a b r = tryWith id $ do
  createDirectoryIfMissing True (reviewedDir s)
  atomicWrite (reviewPath s a b) (encodeUtf8 (render r))

-- | Remove the review of a pair. If there is none, the function does nothing.
unreview :: Store -> Id -> Id -> IO (Either IOException ())
unreview s a b = tryWith id (ifMissing () (removeFile (reviewPath s a b)))

-- | Every review, sorted by pair. A file with a name that is not a pair is
-- skipped, and so is a file that cannot be read as text. A review with
-- lines that are missing reads with empty values, so one bad file does not
-- hide the other pairs.
listReviews :: Store -> IO (Either IOException [(Pair, Review)])
listReviews s = tryWith id $ do
  names <- ifMissing [] (listDirectory (reviewedDir s))
  rs <- forM names $ \n -> case parseName n of
    Nothing -> pure Nothing
    Just p -> do
      bytes <- ifMissing BS.empty (BS.readFile (reviewedDir s </> n))
      pure (Just (p, either (const emptyReview) parse (decodeUtf8' bytes)))
  pure (Map.toAscList (Map.fromList (catMaybes rs)))

-- | Remove the review of each pair that names a memory that is not in the set.
-- It returns the pairs that it removed.
prune :: Store -> Set Id -> IO (Either IOException [Pair])
prune s present = tryWith id $ do
  names <- ifMissing [] (listDirectory (reviewedDir s))
  gone <- forM names $ \n -> case parseName n of
    Just (a, b) | a `Set.notMember` present || b `Set.notMember` present -> do
      ifMissing () (removeFile (reviewedDir s </> n))
      pure (Just (a, b))
    _ -> pure Nothing
  pure (catMaybes gone)

-- Run an action. A file or directory that is not there gives the default.
ifMissing :: a -> IO a -> IO a
ifMissing d act = either (const d) id <$> tryJust (guard . isDoesNotExistError) act

-- The file format ------------------------------------------------------

parseName :: FilePath -> Maybe Pair
parseName n = case T.splitOn "_" (T.pack n) of
  [x, y] -> do
    a <- either (const Nothing) Just (Id.parse x)
    b <- either (const Nothing) Just (Id.parse y)
    if a <= b then Just (a, b) else Nothing
  _ -> Nothing

emptyReview :: Review
emptyReview = Review "" (read "1970-01-01 00:00:00 UTC") ""

render :: Review -> Text
render r =
  T.unlines
    [ "agent: " <> reviewAgent r,
      "reviewed: " <> T.pack (formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" (reviewAt r)),
      "verdict: distinct",
      "",
      reviewNote r
    ]

parse :: Text -> Review
parse t =
  Review
    { reviewAgent = field "agent: ",
      reviewAt = maybe (reviewAt emptyReview) id (parseTimeM True defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" (T.unpack (field "reviewed: "))),
      reviewNote = T.strip (T.unlines (drop 1 (dropWhile (not . T.null) ls)))
    }
  where
    ls = T.lines t
    field p = case [T.drop (T.length p) l | l <- ls, p `T.isPrefixOf` l] of
      (x : _) -> x
      [] -> ""
