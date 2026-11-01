-- | Protocol identities. These types do not generate randomness or read a store.
module Akyuu.Sync.Types
  ( Identifier,
    mkIdentifier,
    parseIdentifier,
    renderIdentifier,
    StoreId (..),
    ReplicaId (..),
    Nonce (..),
    EventId (..),
    Resource (..),
    ReviewValue (..),
    Action (..),
    resourceOf,
    normaliseAction,
  )
where

import Akyuu.Id (Id)
import Akyuu.Refs (Name)
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as Base16
import Data.Text (Text)
import Data.Text.Encoding (decodeUtf8, encodeUtf8)

-- | A 128-bit identity. Callers must obtain fresh random bytes for new identities.
newtype Identifier = Identifier ByteString deriving (Eq, Ord, Show)

mkIdentifier :: ByteString -> Either Text Identifier
mkIdentifier bytes
  | BS.length bytes == 16 = Right (Identifier bytes)
  | otherwise = Left "An identifier must have 16 bytes."

parseIdentifier :: Text -> Either Text Identifier
parseIdentifier text = do
  bytes <- first (const "An identifier must be lower-case hexadecimal.") (Base16.decode (encodeUtf8 text))
  result <- mkIdentifier bytes
  if renderIdentifier result == text then Right result else Left "An identifier must be lower-case hexadecimal."

renderIdentifier :: Identifier -> Text
renderIdentifier (Identifier bytes) = decodeUtf8 (Base16.encode bytes)

newtype StoreId = StoreId Identifier deriving (Eq, Ord, Show)

newtype ReplicaId = ReplicaId Identifier deriving (Eq, Ord, Show)

newtype Nonce = Nonce Identifier deriving (Eq, Ord, Show)

-- | A distinct type prevents an event ID from being used as a memory ID.
newtype EventId = EventId Id deriving (Eq, Ord, Show)

data Resource
  = RefResource Name
  | PinResource Id
  | ReviewResource Id Id
  | RegistryResource
  deriving (Eq, Ord, Show)

data ReviewValue = ReviewValue
  { reviewAuthor :: Text,
    reviewReason :: Text
  }
  deriving (Eq, Show)

-- | Resolutions are explicit. Ordinary ref actions cannot change a parent's type.
data Action
  = SetTopic Name Id
  | AppendLog Name Id
  | ResolveTopic Name Id
  | ResolveLog Name Id
  | SetPin Id
  | ClearPin Id
  | SetReview Id Id ReviewValue
  | ClearReview Id Id
  | RegisterReplica ReplicaId Text
  deriving (Eq, Show)

normaliseAction :: Action -> Action
normaliseAction (SetReview a b value) = SetReview (min a b) (max a b) value
normaliseAction (ClearReview a b) = ClearReview (min a b) (max a b)
normaliseAction action = action

resourceOf :: Action -> Resource
resourceOf action = case action of
  SetTopic name _ -> RefResource name
  AppendLog name _ -> RefResource name
  ResolveTopic name _ -> RefResource name
  ResolveLog name _ -> RefResource name
  SetPin memory -> PinResource memory
  ClearPin memory -> PinResource memory
  SetReview a b _ -> ReviewResource (min a b) (max a b)
  ClearReview a b -> ReviewResource (min a b) (max a b)
  RegisterReplica _ _ -> RegistryResource
