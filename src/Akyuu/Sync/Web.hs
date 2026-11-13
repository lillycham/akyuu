{-# LANGUAGE TemplateHaskell #-}

-- | A read-only topic browser. Each response is one complete checkpoint bundle.
module Akyuu.Sync.Web (readView, page, staticPage, application, serve) where

import Akyuu.Id qualified as Id
import Akyuu.Levels qualified as Levels
import Akyuu.Memory (Memory (memBody, memCreated))
import Akyuu.Refs (nameText)
import Akyuu.Sync.Checkpoint (CheckpointId (CheckpointId))
import Akyuu.Sync.Context (ContextOptions (logOptions), configuredWith, reportJSON)
import Akyuu.Sync.Logs (LogPageOptions (LogPageOptions, pageNumber, pageSize, recentWhole), pageJSON, pageUnchecked)
import Akyuu.Sync.Repository (readMemory, snapshotId)
import Akyuu.Sync.Search (searchAt, searchJSON)
import Akyuu.Sync.Topics (LocalReplica, TopicError (ConfigurationChanged, InvalidInput, StorageError), TopicStatus (LogTopic), TopicView (viewName, viewStatus), captureSnapshot, errorJSON, topicNames, topicViewAt, viewJSON)
import Akyuu.Web.Api (securityHeaders)
import Akyuu.Web.Page (dataPage, withFonts)
import Akyuu.Web.Server (hostAllowed, serveApplication)
import Control.Monad (when)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Trans.Except (ExceptT (ExceptT), runExceptT, throwE)
import Data.Aeson (Value, object, (.=))
import Data.Aeson qualified as A
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as BL
import Data.FileEmbed (embedFile)
import Data.Map.Strict qualified as Map
import Data.String (fromString)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Read qualified as TR
import Network.HTTP.Types (queryToQueryText)
import Network.Wai (Application, pathInfo, queryString, requestHeaderHost, requestMethod, responseLBS)

page :: ByteString
page = withFonts $(embedFile "web/replica.html")

readView :: LocalReplica -> ContextOptions -> Maybe Text -> Int -> IO (Either TopicError Value)
readView local options = readViewChecked local options Nothing

readViewChecked :: LocalReplica -> ContextOptions -> Maybe Text -> Maybe Text -> Int -> IO (Either TopicError Value)
readViewChecked local options expected query limit = runExceptT $ do
  snapshot <- ExceptT (captureSnapshot local)
  let CheckpointId checkpoint = snapshotId snapshot
  case expected of
    Just previous | previous /= Id.render checkpoint -> throwE ConfigurationChanged
    _ -> pure ()
  -- The browser binds every page to one checkpoint (above), which is stricter
  -- than the log version rule, so it reads pages without that rule.
  topics <- traverse (ExceptT . topicViewAt snapshot) (topicNames snapshot)
  -- Page each log once. The configured context takes its pages from here.
  paged <- liftIO (traverse (\topic -> (viewName topic,) <$> pageUnchecked snapshot (viewName topic) (logOptions options)) (filter ((== LogTopic) . viewStatus) topics))
  let logs = [either (\err -> object ["ref" .= nameText name, "error" .= errorJSON err]) pageJSON result | (name, result) <- paged]
      pages = Map.fromList paged
      pageOf name = maybe (pageUnchecked snapshot name (logOptions options)) pure (Map.lookup name pages)
  context <- ExceptT (configuredWith pageOf snapshot options)
  search <- traverse (\text -> ExceptT (searchAt snapshot text limit)) query
  pure (object ["checkpoint" .= Id.render checkpoint, "topics" .= map viewJSON topics, "logs" .= logs, "context" .= reportJSON context, "search" .= fmap searchJSON search])

staticPage :: LocalReplica -> ContextOptions -> IO (Either TopicError ByteString)
staticPage local options = fmap (dataPage page) <$> readView local options Nothing 20

serve :: LocalReplica -> ContextOptions -> Int -> (Int -> IO ()) -> IO ()
serve local options port = serveApplication port (\actual -> application actual local options)

application :: Int -> LocalReplica -> ContextOptions -> Application
application port local options request respond
  | not (hostAllowed port (requestHeaderHost request)) = sendError 403 "The Host header must name this loopback server."
  | requestMethod request /= "GET" = sendError 405 "This browser is read only. Use GET."
  | null (pathInfo request) = send 200 "text/html; charset=utf-8" (BL.fromStrict page)
  | pathInfo request == ["api", "source"] = case sourceParameters of
      Left message -> sendError 400 message
      Right (expected, digest) -> do
        result <- runExceptT $ do
          snapshot <- ExceptT (captureSnapshot local)
          let CheckpointId checkpoint = snapshotId snapshot
          if checkpoint /= expected then throwE ConfigurationChanged else pure ()
          memory <- ExceptT (first StorageError <$> readMemory snapshot digest)
          pure (object ["checkpoint" .= Id.render checkpoint, "memory" .= Id.render digest, "body" .= memBody memory, "created" .= memCreated memory, "sources" .= map Id.render (Levels.sources memory)])
        case result of
          Right value -> send 200 "application/json; charset=utf-8" (A.encode value)
          Left err@ConfigurationChanged -> send 409 "application/json; charset=utf-8" (A.encode (errorJSON err))
          Left err -> send 400 "application/json; charset=utf-8" (A.encode (errorJSON err))
  | pathInfo request /= ["api", "view"] = sendError 404 "No such endpoint."
  | otherwise = case parameters of
      Left message -> sendError 400 message
      Right (query, limit, pages, expected) -> do
        result <- readViewChecked local options {logOptions = pages} expected query limit
        case result of
          Right value -> send 200 "application/json; charset=utf-8" (A.encode value)
          Left err@(InvalidInput _) -> send 400 "application/json; charset=utf-8" (A.encode (errorJSON err))
          Left err@ConfigurationChanged -> send 409 "application/json; charset=utf-8" (A.encode (errorJSON err))
          Left err -> send 500 "application/json; charset=utf-8" (A.encode (errorJSON err))
  where
    send code content body = respond (responseLBS (toEnum code) [(fromString (BC.unpack key), value) | (key, value) <- ("Content-Type", content) : (if code == 405 then [("Allow", "GET")] else []) <> securityHeaders] body)
    sendError code message = send code "application/json; charset=utf-8" (A.encode (object ["error" .= (message :: Text)]))
    pairs = queryToQueryText (queryString request)
    sourceParameters
      | length pairs /= 2 || map fst pairs `notSameKeys` ["checkpoint", "memory"] = Left "Give one checkpoint and one source memory ID."
      | otherwise = (,) <$> identifier "checkpoint" <*> identifier "memory"
    notSameKeys a b = any (`notElem` b) a || length (unique a) /= length b
    identifier key = case lookup key pairs of
      Just (Just text) -> first (const (key <> " needs a complete ID.")) (Id.parse text)
      _ -> Left (key <> " needs a value.")
    parameters
      | any (\(key, _) -> key `notElem` ["q", "limit", "log_page", "log_limit", "log_keep", "checkpoint"]) pairs = Left "Unknown query parameter."
      | length pairs /= length (unique (map fst pairs)) = Left "Duplicate query parameter."
      | otherwise = do
          limit <- case lookup "limit" pairs of
            Nothing -> Right 20
            Just (Just text) -> case TR.decimal text of
              Right (number, "") | number >= 1 && number <= 100 -> Right number
              _ -> Left "limit must be from 1 to 100."
            _ -> Left "limit needs a value."
          query <- case lookup "q" pairs of
            Nothing -> Right Nothing
            Just (Just text) | not (T.null (T.strip text)) -> Right (Just text)
            _ -> Left "q needs a search word."
          number <- numeric "log_page" (pageNumber (logOptions options)) 1 4096
          size <- numeric "log_limit" (pageSize (logOptions options)) 1 100
          keep <- numeric "log_keep" (recentWhole (logOptions options)) 0 4096
          expected <- case lookup "checkpoint" pairs of
            Nothing -> Right Nothing
            Just (Just text) | either (const False) (const True) (Id.parse text) -> Right (Just text)
            _ -> Left "checkpoint needs a complete checkpoint ID."
          when (number > 1 && expected == Nothing) (Left "Further log pages require the checkpoint from the first response.")
          Right (query, limit, LogPageOptions number size keep (expected >>= either (const Nothing) Just . Id.parse), expected)
    numeric key fallback lower upper = case lookup key pairs of
      Nothing -> Right fallback
      Just (Just text) -> case TR.decimal text of
        Right (number, "") | number >= lower && number <= upper -> Right number
        _ -> Left (key <> " is outside the supported range.")
      _ -> Left (key <> " needs a value.")
    unique [] = []
    unique (key : rest) = key : unique (filter (/= key) rest)
