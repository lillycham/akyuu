-- | Experimental sync v1 encoding. This is not yet a deployed store format.
--
-- Events are a domain header followed by a canonical JSON array and a newline.
-- Arrays fix field order; re-encoding rejects alternate JSON representations.
module Akyuu.Sync.Event
  ( Event,
    eventStore,
    eventReplica,
    eventNonce,
    eventParents,
    eventAction,
    eventTime,
    eventId,
    mkEvent,
    renderEvent,
    parseEvent,
    EventError (..),
    maxEventBytes,
    maxEventParents,
  )
where

import Akyuu.Id qualified as Id
import Akyuu.Memory (timeFormat)
import Akyuu.Refs qualified as Refs
import Akyuu.Sync.Types (Action (AppendLog, ClearPin, ClearReview, RegisterReplica, ResolveLog, ResolveTopic, SetPin, SetReview, SetTopic), EventId (EventId), Nonce (Nonce), ReplicaId (ReplicaId), ReviewValue (ReviewValue), StoreId (StoreId), normaliseAction, parseIdentifier, renderIdentifier)
import Control.Monad (unless, when)
import Data.Aeson (Value, eitherDecodeStrict')
import Data.Aeson.Types (Parser, parseEither, parseJSON)
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Char (intToDigit, ord)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (encodeUtf8)
import Data.Time (UTCTime (utctDay, utctDayTime), defaultTimeLocale, formatTime, parseTimeM, toGregorian)

data Event = Event
  { eventStore :: StoreId,
    eventReplica :: ReplicaId,
    eventNonce :: Nonce,
    eventParents :: Set EventId,
    eventAction :: Action,
    eventTime :: UTCTime
  }
  deriving (Eq, Show)

data EventError
  = EventTooLarge
  | TooManyParents
  | BadEvent Text
  | NonCanonicalEvent
  deriving (Eq, Show)

maxEventBytes, maxEventParents :: Int
maxEventBytes = 65536
maxEventParents = 256

header :: ByteString
header = "akyuu-sync-event-v1\n"

-- | Validation rejects sub-second and leap-second times rather than losing data.
mkEvent :: StoreId -> ReplicaId -> Nonce -> Set EventId -> Action -> UTCTime -> Either EventError Event
mkEvent store replica nonce parents action time = do
  when (Set.size parents > maxEventParents) (Left TooManyParents)
  let event = Event store replica nonce parents (normaliseAction action) time
      timeText = formatTime defaultTimeLocale timeFormat time
      (year, _, _) = toGregorian (utctDay time)
  unless (year >= 1 && year <= 9999 && utctDayTime time < 86400 && (parseTimeM True defaultTimeLocale timeFormat timeText :: Maybe UTCTime) == Just time) $
    Left (BadEvent "Event time must round-trip at whole-second precision.")
  case action of
    RegisterReplica _ label -> unless (validAuthor label) (Left (BadEvent "Replica label must be nonempty, trimmed, and one line."))
    SetReview _ _ (ReviewValue author _) -> unless (validAuthor author) (Left (BadEvent "Review author must be nonempty, trimmed, and one line."))
    _ -> Right ()
  when (BS.length (renderEvent event) > maxEventBytes) (Left EventTooLarge)
  pure event
  where
    validAuthor text = not (T.null text) && T.strip text == text && not (T.any (`elem` ['\n', '\r', '\NUL']) text)

eventId :: Event -> EventId
eventId = EventId . Id.hashBytes . renderEvent

renderEvent :: Event -> ByteString
renderEvent event = header <> array fields <> "\n"
  where
    StoreId store = eventStore event
    ReplicaId replica = eventReplica event
    Nonce nonce = eventNonce event
    fields =
      [ string (renderIdentifier store),
        string (renderIdentifier replica),
        string (renderIdentifier nonce),
        array [string (Id.render digest) | EventId digest <- Set.toAscList (eventParents event)],
        array (map string (actionFields (eventAction event))),
        string (T.pack (formatTime defaultTimeLocale timeFormat (eventTime event)))
      ]

-- The wire encoding is explicit rather than dependent on an Aeson version.
array :: [ByteString] -> ByteString
array fields = "[" <> BS.intercalate "," fields <> "]"

string :: Text -> ByteString
string text = "\"" <> encodeUtf8 (T.concatMap escape text) <> "\""
  where
    escape '\"' = "\\\""
    escape '\\' = "\\\\"
    escape '\b' = "\\b"
    escape '\f' = "\\f"
    escape '\n' = "\\n"
    escape '\r' = "\\r"
    escape '\t' = "\\t"
    escape char
      | ord char < 32 = T.pack ['\\', 'u', '0', '0', intToDigit (ord char `div` 16), intToDigit (ord char `mod` 16)]
      | otherwise = T.singleton char

actionFields :: Action -> [Text]
actionFields action = case action of
  SetTopic name memory -> ["set-topic", Refs.nameText name, Id.render memory]
  AppendLog name memory -> ["append-log", Refs.nameText name, Id.render memory]
  ResolveTopic name memory -> ["resolve-topic", Refs.nameText name, Id.render memory]
  ResolveLog name memory -> ["resolve-log", Refs.nameText name, Id.render memory]
  SetPin memory -> ["set-pin", Id.render memory]
  ClearPin memory -> ["clear-pin", Id.render memory]
  SetReview a b (ReviewValue author reason) -> ["set-review", Id.render a, Id.render b, author, reason]
  ClearReview a b -> ["clear-review", Id.render a, Id.render b]
  RegisterReplica (ReplicaId replica) label -> ["register-replica", renderIdentifier replica, label]

parseEvent :: ByteString -> Either EventError Event
parseEvent bytes = do
  when (BS.length bytes > maxEventBytes) (Left EventTooLarge)
  body <- maybe (Left (BadEvent "Unknown event protocol header.")) Right (BS.stripPrefix header bytes)
  value <- first (BadEvent . T.pack) (eitherDecodeStrict' body)
  event <- first (BadEvent . T.pack) (parseEither parseFields value)
  unless (renderEvent event == bytes) (Left NonCanonicalEvent)
  pure event

parseFields :: Value -> Parser Event
parseFields value = do
  fields <- parseJSON value :: Parser [Value]
  case fields of
    [storeValue, replicaValue, nonceValue, parentsValue, actionValue, timeValue] -> do
      store <- StoreId <$> (parseJSON storeValue >>= checked . parseIdentifier)
      replica <- ReplicaId <$> (parseJSON replicaValue >>= checked . parseIdentifier)
      nonce <- Nonce <$> (parseJSON nonceValue >>= checked . parseIdentifier)
      parentTexts <- parseJSON parentsValue :: Parser [Text]
      when (length parentTexts > maxEventParents) (fail "Too many parents.")
      parents <- Set.fromList <$> traverse (fmap EventId . checked . first (T.pack . show) . Id.parse) parentTexts
      action <- parseJSON actionValue >>= parseAction
      timeText <- parseJSON timeValue
      time <- maybe (fail "Invalid event time.") pure (parseTimeM True defaultTimeLocale timeFormat (T.unpack timeText))
      either (fail . show) pure (mkEvent store replica nonce parents action time)
    _ -> fail "An event must have exactly six fields."

checked :: Either Text a -> Parser a
checked = either (fail . T.unpack) pure

parseAction :: [Text] -> Parser Action
parseAction fields = case fields of
  ["set-topic", name, memory] -> SetTopic <$> ref name <*> digest memory
  ["append-log", name, memory] -> AppendLog <$> ref name <*> digest memory
  ["resolve-topic", name, memory] -> ResolveTopic <$> ref name <*> digest memory
  ["resolve-log", name, memory] -> ResolveLog <$> ref name <*> digest memory
  ["set-pin", memory] -> SetPin <$> digest memory
  ["clear-pin", memory] -> ClearPin <$> digest memory
  ["set-review", a, b, author, reason] -> SetReview <$> digest a <*> digest b <*> pure (ReviewValue author reason)
  ["clear-review", a, b] -> ClearReview <$> digest a <*> digest b
  ["register-replica", replica, label] -> RegisterReplica <$> (ReplicaId <$> checked (parseIdentifier replica)) <*> pure label
  _ -> fail "Unknown action or incorrect action fields."
  where
    ref = checked . first (T.pack . show) . Refs.mkName
    digest = checked . first (T.pack . show) . Id.parse
