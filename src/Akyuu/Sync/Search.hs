-- | Text search over current causal topic heads. The temporary FTS index
-- belongs to one captured checkpoint and cannot contain prepared objects.
module Akyuu.Sync.Search
  ( SearchReport (..),
    SearchHit (..),
    searchTopics,
    searchAt,
    searchJSON,
    renderSearch,
  )
where

import Akyuu.Cache (ftsQuery)
import Akyuu.Fs (tryAs)
import Akyuu.Id qualified as Id
import Akyuu.Memory (Memory (memBody))
import Akyuu.Refs (Name, nameText)
import Akyuu.Sync.Checkpoint (CheckpointId (CheckpointId))
import Akyuu.Sync.Repository (Snapshot, snapshotId, snapshotState)
import Akyuu.Sync.State (ResourceState (LogHeads), interpret)
import Akyuu.Sync.Topics (LocalReplica, TopicError (InvalidInput), TopicHead (headEvent, headMemory), TopicStatus (LogTopic), TopicView (viewHeads, viewName, viewStatus), captureSnapshot, renderView, topicNames, topicViewAt, viewJSON)
import Akyuu.Sync.Topics qualified as Topics
import Akyuu.Sync.Types (EventId (EventId), Resource (RefResource))
import Control.Exception (bracket, displayException)
import Control.Monad (when)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Trans.Except (ExceptT (ExceptT), runExceptT, throwE)
import Data.Aeson (Value, object, (.=))
import Data.List (sortOn)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Database.SQLite.Simple (Only (Only), SQLError, close, executeMany, execute_, open, query)

data SearchHit = SearchHit
  { hitTopic :: TopicView,
    matchedHeads :: Set EventId
  }
  deriving (Eq, Show)

-- | The last field names the topics whose current heads could not be read.
-- The search covers every other topic, so one damaged payload does not hide
-- all results. The report says which topics it left out.
data SearchReport = SearchReport CheckpointId Text [SearchHit] [(Name, TopicError)] deriving (Eq, Show)

searchTopics :: LocalReplica -> Text -> Int -> IO (Either TopicError SearchReport)
searchTopics local text limit = runExceptT $ do
  snapshot <- ExceptT (captureSnapshot local)
  ExceptT (searchAt snapshot text limit)

searchAt :: Snapshot -> Text -> Int -> IO (Either TopicError SearchReport)
searchAt snapshot text limit = runExceptT $ do
  when (T.null (T.strip text) || T.null (ftsQuery text)) (throwE (InvalidInput "Give at least one search word."))
  when (limit < 1 || limit > 100) (throwE (InvalidInput "The search limit must be from 1 to 100."))
  -- Log refs never match, so leave them out before any payload read.
  let candidates = [name | name <- topicNames snapshot, not (isLog (interpret (snapshotState snapshot) (RefResource name)))]
      isLog state = case state of LogHeads _ -> True; _ -> False
  read' <- liftIO (traverse (\name -> (name,) <$> topicViewAt snapshot name) candidates)
  let views = [view | (_, Right view) <- read']
      unreadable = [(name, err) | (name, Left err) <- read']
      topics = filter ((/= LogTopic) . viewStatus) views
      byName = Map.fromList [(nameText (viewName view), view) | view <- topics]
      rows = [(nameText (viewName view), eventText (headEvent entry), memBody (headMemory entry)) | view <- topics, entry <- viewHeads view]
      byEvent = Map.fromList [(eventText (headEvent entry), headEvent entry) | view <- topics, entry <- viewHeads view]
  result <- liftIO $
    tryAs (\(err :: SQLError) -> Topics.TextIndexFailed (T.pack (displayException err))) $
      bracket (open ":memory:") close $ \db -> do
        execute_ db "CREATE VIRTUAL TABLE heads USING fts5(topic UNINDEXED,event UNINDEXED,body,tokenize='porter unicode61')"
        executeMany db "INSERT INTO heads(topic,event,body) VALUES (?,?,?)" rows
        query db "SELECT topic,event,bm25(heads) FROM heads WHERE heads MATCH ? ORDER BY bm25(heads),topic,event" (Only (ftsQuery text))
  hits <- either throwE pure (result :: Either TopicError [(Text, Text, Double)])
  let grouped = Map.fromListWith combine [(name, (rank, Set.singleton key)) | (name, event, rank) <- hits, Just key <- [Map.lookup event byEvent]]
      combine (rank, heads) (other, more) = (min rank other, heads <> more)
      ordered = take limit (sortOn (\(name, (rank, _)) -> (rank, name)) (Map.toAscList grouped))
  pure (SearchReport (snapshotId snapshot) text [SearchHit view matching | (name, (_, matching)) <- ordered, Just view <- [Map.lookup name byName]] unreadable)

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
