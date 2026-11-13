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
    describeEventError,
    maxEventBytes,
    maxEventParents,
  )
where

import Akyuu.Id qualified as Id
import Akyuu.Refs qualified as Refs
import Akyuu.Sync.Stamp (formatStamp, parseStamp)
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
import Data.Time (UTCTime (utctDay, utctDayTime), toGregorian)

-- | A validated event. The fields are positional and the getters below are
-- plain functions: an exported record field would permit a record update,
-- which changes a validated value without a second validation.
data Event = Event StoreId ReplicaId Nonce (Set EventId) Action UTCTime
  deriving (Eq, Show)

eventStore :: Event -> StoreId
eventStore (Event store _ _ _ _ _) = store

eventReplica :: Event -> ReplicaId
eventReplica (Event _ replica _ _ _ _) = replica

eventNonce :: Event -> Nonce
eventNonce (Event _ _ nonce _ _ _) = nonce

eventParents :: Event -> Set EventId
eventParents (Event _ _ _ parents _ _) = parents

eventAction :: Event -> Action
eventAction (Event _ _ _ _ action _) = action

eventTime :: Event -> UTCTime
eventTime (Event _ _ _ _ _ time) = time

data EventError
  = EventTooLarge
  | TooManyParents
  | BadEvent Text
  | NonCanonicalEvent
  deriving (Eq, Show)

describeEventError :: EventError -> Text
describeEventError failure = case failure of
  EventTooLarge -> "The event exceeds " <> T.pack (show maxEventBytes) <> " bytes. Use a shorter name, label or reason."
  TooManyParents -> "The resource has more than " <> T.pack (show maxEventParents) <> " concurrent heads. One event cannot consume them all."
  BadEvent message -> message
  NonCanonicalEvent -> "The event is not in its canonical form."

maxEventBytes, maxEventParents :: Int
maxEventBytes = 65536
maxEventParents = 256

header :: ByteString
header = "akyuu-sync-event-v1\n"

-- | Validation rejects sub-second and leap-second times rather than losing data.
mkEvent :: StoreId -> ReplicaId -> Nonce -> Set EventId -> Action -> UTCTime -> Either EventError Event
mkEvent store replica nonce parents action time = fst <$> construct store replica nonce parents action time

-- The canonical bytes come back with the event. The parser compares them with
-- its input, so a decode renders an event once.
construct :: StoreId -> ReplicaId -> Nonce -> Set EventId -> Action -> UTCTime -> Either EventError (Event, ByteString)
construct store replica nonce parents action time = do
  when (Set.size parents > maxEventParents) (Left TooManyParents)
  let event = Event store replica nonce parents (normaliseAction action) time
      timeText = formatStamp time
      (year, _, _) = toGregorian (utctDay time)
  unless (year >= 1 && year <= 9999 && utctDayTime time < 86400 && parseStamp timeText == Just time) $
    Left (BadEvent "Event time must round-trip at whole-second precision.")
  case action of
    RegisterReplica _ label -> unless (validAuthor label) (Left (BadEvent "Replica label must be nonempty, trimmed, and one line."))
    SetReview _ _ (ReviewValue author _) -> unless (validAuthor author) (Left (BadEvent "Review author must be nonempty, trimmed, and one line."))
    _ -> Right ()
  let bytes = renderWith timeText event
  when (BS.length bytes > maxEventBytes) (Left EventTooLarge)
  pure (event, bytes)
  where
    validAuthor text = not (T.null text) && T.strip text == text && not (T.any (`elem` ['\n', '\r', '\NUL']) text)

eventId :: Event -> EventId
eventId = EventId . Id.hashBytes . renderEvent

renderEvent :: Event -> ByteString
renderEvent event = renderWith (formatStamp (eventTime event)) event

renderWith :: String -> Event -> ByteString
renderWith timeText event = header <> array fields <> "\n"
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
        string (T.pack timeText)
      ]

-- The wire encoding is explicit rather than dependent on an Aeson version.
array :: [ByteString] -> ByteString
array fields = "[" <> BS.intercalate "," fields <> "]"

string :: Text -> ByteString
string text = "\"" <> encodeUtf8 (if T.any special text then T.concatMap escape text else text) <> "\""
  where
    special char = char == '"' || char == '\\' || ord char < 32
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
  (event, canonical) <- first (BadEvent . T.pack) (parseEither parseFields value)
  unless (canonical == bytes) (Left NonCanonicalEvent)
  pure event

parseFields :: Value -> Parser (Event, ByteString)
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
      time <- maybe (fail "Invalid event time.") pure (parseStamp (T.unpack timeText))
      either (fail . show) pure (construct store replica nonce parents action time)
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
