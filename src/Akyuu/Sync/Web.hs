{-# LANGUAGE TemplateHaskell #-}

-- | A read-only topic browser. Each response is one complete checkpoint bundle.
module Akyuu.Sync.Web (readView, page, staticPage, application, serve) where

import Akyuu.Id qualified as Id
import Akyuu.Sync.Checkpoint (CheckpointId (CheckpointId))
import Akyuu.Sync.Context (ContextOptions, configuredAt, reportJSON)
import Akyuu.Sync.Repository (snapshotId)
import Akyuu.Sync.Search (searchAt, searchJSON)
import Akyuu.Sync.Topics (LocalReplica, TopicError (InvalidInput), captureSnapshot, errorJSON, topicNames, topicViewAt, viewJSON)
import Akyuu.Web.Api (securityHeaders)
import Akyuu.Web.Page (dataPage, withFonts)
import Akyuu.Web.Server (hostAllowed, serveApplication)
import Control.Monad.Trans.Except (ExceptT (ExceptT), runExceptT)
import Data.Aeson (Value, object, (.=))
import Data.Aeson qualified as A
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as BL
import Data.FileEmbed (embedFile)
import Data.String (fromString)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Read qualified as TR
import Network.HTTP.Types (queryToQueryText)
import Network.Wai (Application, pathInfo, queryString, requestHeaderHost, requestMethod, responseLBS)

page :: ByteString
page = withFonts $(embedFile "web/replica.html")

readView :: LocalReplica -> ContextOptions -> Maybe Text -> Int -> IO (Either TopicError Value)
readView local options query limit = runExceptT $ do
  snapshot <- ExceptT (captureSnapshot local)
  topics <- traverse (ExceptT . topicViewAt snapshot) (topicNames snapshot)
  context <- ExceptT (configuredAt snapshot options)
  search <- traverse (\text -> ExceptT (searchAt snapshot text limit)) query
  let CheckpointId checkpoint = snapshotId snapshot
  pure (object ["checkpoint" .= Id.render checkpoint, "topics" .= map viewJSON topics, "context" .= reportJSON context, "search" .= fmap searchJSON search])

staticPage :: LocalReplica -> ContextOptions -> IO (Either TopicError ByteString)
staticPage local options = fmap (dataPage page) <$> readView local options Nothing 20

serve :: LocalReplica -> ContextOptions -> Int -> (Int -> IO ()) -> IO ()
serve local options port = serveApplication port (\actual -> application actual local options)

application :: Int -> LocalReplica -> ContextOptions -> Application
application port local options request respond
  | not (hostAllowed port (requestHeaderHost request)) = sendError 403 "The Host header must name this loopback server."
  | requestMethod request /= "GET" = sendError 405 "This browser is read only. Use GET."
  | null (pathInfo request) = send 200 "text/html; charset=utf-8" (BL.fromStrict page)
  | pathInfo request /= ["api", "view"] = sendError 404 "No such endpoint."
  | otherwise = case parameters of
      Left message -> sendError 400 message
      Right (query, limit) -> do
        result <- readView local options query limit
        case result of
          Right value -> send 200 "application/json; charset=utf-8" (A.encode value)
          Left err@(InvalidInput _) -> send 400 "application/json; charset=utf-8" (A.encode (errorJSON err))
          Left err -> send 500 "application/json; charset=utf-8" (A.encode (errorJSON err))
  where
    send code content body = respond (responseLBS (toEnum code) [(fromString (BC.unpack key), value) | (key, value) <- ("Content-Type", content) : (if code == 405 then [("Allow", "GET")] else []) <> securityHeaders] body)
    sendError code message = send code "application/json; charset=utf-8" (A.encode (object ["error" .= (message :: Text)]))
    pairs = queryToQueryText (queryString request)
    parameters
      | any (\(key, _) -> key `notElem` ["q", "limit"]) pairs = Left "Unknown query parameter."
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
          Right (query, limit)
    unique [] = []
    unique (key : rest) = key : unique (filter (/= key) rest)
