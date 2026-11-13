-- | Text search over current causal topic heads. The FTS index updates
-- incrementally to match the heads of one captured checkpoint and cannot
-- contain prepared objects.
module Akyuu.Sync.Search
  ( SearchReport (..),
    SearchHit (..),
    searchTopics,
    searchAt,
    searchViews,
    searchJSON,
    renderSearch,
  )
where

import Akyuu.Cache (ftsQuery)
import Akyuu.Fs (ignoreIO, tryAs)
import Akyuu.Id qualified as Id
import Akyuu.Memory (Memory (memBody))
import Akyuu.Refs (Name, nameText)
import Akyuu.Sync.Checkpoint (CheckpointId (CheckpointId))
import Akyuu.Sync.Repository (Snapshot, snapshotId, snapshotState)
import Akyuu.Sync.State (ResourceState (LogHeads), interpret)
import Akyuu.Sync.Topics (LocalReplica, TopicError (InvalidInput), TopicHead (headEvent, headMemory), TopicStatus (LogTopic), TopicView (viewHeads, viewName, viewStatus), captureSnapshot, renderView, topicNames, topicViewAt, viewJSON)
import Akyuu.Sync.Topics qualified as Topics
import Akyuu.Sync.Types (EventId (EventId), Resource (RefResource))
import Control.Concurrent.MVar (MVar, modifyMVar, newMVar)
import Control.Exception (displayException)
import Control.Monad (unless, when)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Trans.Except (ExceptT (ExceptT), runExceptT, throwE)
import Data.Aeson (Value, object, (.=))
import Data.Int (Int64)
import Data.List (sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Database.SQLite.Simple (Connection, Only (Only), SQLError, close, executeMany, execute_, open, query, withTransaction)
import System.IO.Unsafe (unsafePerformIO)

data SearchHit = SearchHit
  { hitTopic :: TopicView,
    matchedHeads :: Set EventId
  }
  deriving (Eq, Show)

-- | The last field names the topics whose current heads could not be read.
-- The search covers every other topic, so one damaged payload does not hide
-- all results. The report says which topics it left out.
data SearchReport = SearchReport CheckpointId Text [SearchHit] [(Name, TopicError)] deriving (Eq, Show)

data IndexState = IndexState
  { indexConnection :: Connection,
    indexNextRow :: !Int64,
    indexRows :: !(Map (Text, Text) Int64)
  }

sharedIndex :: MVar (Maybe IndexState)
sharedIndex = unsafePerformIO (newMVar Nothing)
{-# NOINLINE sharedIndex #-}

searchTopics :: LocalReplica -> Text -> Int -> IO (Either TopicError SearchReport)
searchTopics local text limit = runExceptT $ do
  snapshot <- ExceptT (captureSnapshot local)
  ExceptT (searchAt snapshot text limit)

searchAt :: Snapshot -> Text -> Int -> IO (Either TopicError SearchReport)
searchAt snapshot text limit = runExceptT $ do
  checkQuery text limit
  -- Log refs never match, so leave them out before any payload read.
  let candidates = [name | name <- topicNames snapshot, not (isLog (interpret (snapshotState snapshot) (RefResource name)))]
      isLog state = case state of LogHeads _ -> True; _ -> False
  read' <- liftIO (traverse (\name -> (name,) <$> topicViewAt snapshot name) candidates)
  let views = [view | (_, Right view) <- read']
      unreadable = [(name, err) | (name, Left err) <- read']
  ExceptT (searchViews (snapshotId snapshot) views unreadable text limit)

-- | Search a list of topic views that the caller already loaded from one
-- checkpoint.
searchViews :: CheckpointId -> [TopicView] -> [(Name, TopicError)] -> Text -> Int -> IO (Either TopicError SearchReport)
searchViews checkpoint views unreadable text limit = runExceptT $ do
  checkQuery text limit
  let topics = filter ((/= LogTopic) . viewStatus) views
      byName = Map.fromList [(nameText (viewName view), view) | view <- topics]
      rows = Map.fromList [((nameText (viewName view), eventText (headEvent entry)), memBody (headMemory entry)) | view <- topics, entry <- viewHeads view]
      byEvent = Map.fromList [(eventText (headEvent entry), headEvent entry) | view <- topics, entry <- viewHeads view]
  result <- liftIO (queryIndex rows (ftsQuery text))
  hits <- either throwE pure result
  let grouped = Map.fromListWith combine [(name, (rank, Set.singleton key)) | (name, event, rank) <- hits, Just key <- [Map.lookup event byEvent]]
      combine (rank, heads) (other, more) = (min rank other, heads <> more)
      ordered = take limit (sortOn (\(name, (rank, _)) -> (rank, name)) (Map.toAscList grouped))
  pure (SearchReport checkpoint text [SearchHit view matching | (name, (_, matching)) <- ordered, Just view <- [Map.lookup name byName]] unreadable)

checkQuery :: Text -> Int -> ExceptT TopicError IO ()
checkQuery text limit = do
  when (T.null (T.strip text) || T.null (ftsQuery text)) (throwE (InvalidInput "Give at least one search word."))
  when (limit < 1 || limit > 100) (throwE (InvalidInput "The search limit must be from 1 to 100."))

queryIndex :: Map (Text, Text) Text -> Text -> IO (Either TopicError [(Text, Text, Double)])
queryIndex rows fts = modifyMVar sharedIndex $ \current -> do
  outcome <- tryAs (\(err :: SQLError) -> Topics.TextIndexFailed (T.pack (displayException err))) $ do
    state <- case current of
      Just existing -> pure existing
      Nothing -> do
        db <- open ":memory:"
        execute_ db "CREATE VIRTUAL TABLE heads USING fts5(topic UNINDEXED,event UNINDEXED,body,tokenize='porter unicode61')"
        pure (IndexState db 1 Map.empty)
    let db = indexConnection state
        indexed = indexRows state
        kept = Map.restrictKeys indexed (Map.keysSet rows)
        gone = Map.elems (Map.withoutKeys indexed (Map.keysSet rows))
        missing = Map.toAscList (Map.withoutKeys rows (Map.keysSet indexed))
        numbered = zip [indexNextRow state ..] missing
        nextRow = indexNextRow state + fromIntegral (length missing)
        updated = kept <> Map.fromList [(key, rowId) | (rowId, (key, _)) <- numbered]
    unless (null gone && null numbered) $
      withTransaction db $ do
        executeMany db "DELETE FROM heads WHERE rowid = ?" (map Only gone)
        executeMany db "INSERT INTO heads(rowid,topic,event,body) VALUES (?,?,?,?)" [(rowId, topic, event, body) | (rowId, ((topic, event), body)) <- numbered]
    hits <- query db "SELECT topic,event,bm25(heads) FROM heads WHERE heads MATCH ? ORDER BY bm25(heads),topic,event" (Only fts)
    pure (IndexState db nextRow updated, hits)
  case outcome of
    Right (next, hits) -> pure (Just next, Right hits)
    Left err -> do
      maybe (pure ()) (ignoreIO . close . indexConnection) current
      pure (Nothing, Left err)

eventText :: EventId -> Text
eventText (EventId digest) = Id.render digest

searchJSON :: SearchReport -> Value
searchJSON (SearchReport (CheckpointId checkpoint) text hits unreadable) =
  object
    [ "checkpoint" .= Id.render checkpoint,
      "query" .= text,
      "hits" .= [object ["topic" .= viewJSON (hitTopic hit), "matched_heads" .= map eventText (Set.toAscList (matchedHeads hit))] | hit <- hits],
      "unreadable" .= [object ["topic" .= nameText name, "message" .= Topics.describeError err] | (name, err) <- unreadable]
    ]

renderSearch :: SearchReport -> Text
renderSearch (SearchReport _ _ hits unreadable) =
  T.concat (map (renderView . hitTopic) hits)
    <> T.concat ["Not searched: " <> nameText name <> ": " <> Topics.describeError err <> "\n" | (name, err) <- unreadable]
