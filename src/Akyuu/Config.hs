{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | The settings of akyuu: a config file, the environment, and defaults.
--
-- The file is TOML, at @$AKYUU_CONFIG@, or @$XDG_CONFIG_HOME/akyuu/config.toml@,
-- or @~/.config/akyuu/config.toml@:
--
-- > root = "~/.local/share/akyuu"
-- > policy-ref = "me/policy"
-- > tiers-ref = "policy/tiers"
-- > agent = "me"
-- >
-- > [embed]
-- > profile = "nomic"
-- >
-- > [embed.profiles.nomic]
-- > command = "akyuu-embed-llama"
-- > key = "llama:nomic-v1.5-q8_0"
-- > query-prefix = "search_query: "
-- > document-prefix = "search_document: "
-- > min = 0.55
-- > timeout = 60
-- > args = { gguf = "/models/nomic-embed-text-v1.5.Q8_0.gguf" }
--
-- Every setting is optional. A variable of the environment wins over the
-- file (@AKYUU_ROOT@, @AKYUU_POLICY_REF@, @AKYUU_TIERS_REF@, @AKYUU_AGENT@,
-- @AKYUU_EMBED_PROFILE@, @AKYUU_EMBED_MIN@, @AKYUU_EMBED_TIMEOUT@,
-- @AKYUU_EMBED_MAX_CHARS@), and an option of the command line wins over both.
--
-- A profile is one way to make vectors: a command and everything that goes
-- with the model (the key of its vectors, its prefixes, its minimum
-- similarity). The keys of @args@ go to the command as variables
-- (@gguf@ becomes @AKYUU_EMBED_GGUF@); akyuu itself does not read them.
--
-- The older way still works: @AKYUU_EMBED_COMMAND@ and the other
-- @AKYUU_EMBED_*@ variables, in the environment or in the file @embed.env@,
-- make a profile named @environment@. It wins over the profiles of the file.
module Akyuu.Config
  ( -- * Settings
    Config (..),
    EmbedSettings (..),
    Source (..),
    Sourced (..),
    sourceText,
    ConfigError (..),
    describeConfigError,
    loadConfig,
    withRootOption,

    -- * Pure parts
    FileConfig (..),
    Profile (..),
    parseConfigText,
    parseLegacy,
    resolve,
    expandHome,
    environmentProfile,
  )
where

import Akyuu.Tier (defaultPolicyRef, defaultTiersRef, policyRefVar, tiersRefVar)
import Control.Applicative ((<|>))
import Control.Exception (IOException, try)
import Data.ByteString qualified as BS
import Data.Char (isAlphaNum, toUpper)
import Data.List (isPrefixOf, isSuffixOf)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (decodeUtf8')
import System.Environment (getEnvironment)
import System.FilePath ((</>))
import Text.Read (readMaybe)
import Toml (Result (Failure, Success), Value' (Bool', Double', Integer', Text'), decode)
import Toml.Schema (FromValue (fromValue), optKey, parseTableFromValue, reqKey)

-- Types -----------------------------------------------------------------

-- | Where a setting came from.
data Source
  = -- | An option of the command line.
    FromFlag
  | -- | A variable of the environment.
    FromEnv String
  | -- | A config file (the TOML file or the older @embed.env@).
    FromFile FilePath
  | -- | Nothing set it.
    Default
  deriving (Eq, Show)

sourceText :: Source -> Text
sourceText = \case
  FromFlag -> "the command line"
  FromEnv v -> "$" <> T.pack v
  FromFile p -> T.pack p
  Default -> "the default"

-- | A setting and where it came from.
data Sourced a = Sourced {sValue :: a, sSource :: Source}
  deriving (Eq, Show)

-- | How akyuu makes vectors, with every default filled in.
data EmbedSettings = EmbedSettings
  { -- | The name of the profile (@environment@ for the older variables).
    esProfile :: Text,
    -- | Where the choice of the profile came from.
    esSource :: Source,
    -- | The command, run with @sh -c@.
    esCommand :: Text,
    -- | The key of the vectors.
    esKey :: Text,
    -- | Put before the text of a search.
    esQueryPrefix :: Text,
    -- | Put before the text of a memory.
    esDocumentPrefix :: Text,
    -- | The lowest cosine similarity that counts as near.
    esMin :: Maybe Double,
    -- | Seconds for one call, at most 3600.
    esTimeout :: Int,
    -- | The most characters of a text in one call.
    esMaxChars :: Int,
    -- | The arguments of the profile: what the command gets as
    -- @AKYUU_EMBED_*@ variables. For the fingerprint and for display.
    esArgs :: [(Text, Text)],
    -- | The whole environment of the command.
    esCommandEnv :: [(String, String)]
  }
  deriving (Eq, Show)

-- | All the settings.
data Config = Config
  { -- | The config file that was read, if one was.
    cfgFile :: Maybe FilePath,
    -- | The root of the store. There is no default: a wrong guess would
    -- make a new, empty store in a place that the person did not choose.
    cfgRoot :: Maybe (Sourced FilePath),
    cfgPolicyRef :: Sourced Text,
    cfgTiersRef :: Sourced Text,
    cfgAgent :: Sourced Text,
    -- | 'Nothing' when search by meaning is off.
    cfgEmbed :: Maybe EmbedSettings,
    -- | Things to tell the person: unknown keys, values that were left out,
    -- an old file.
    cfgNotes :: [Text]
  }
  deriving (Eq, Show)

-- | A config that cannot be used.
data ConfigError
  = -- | The file is not UTF-8, or cannot be read.
    ConfigUnreadable FilePath Text
  | -- | The file is not valid TOML, or a value has the wrong type.
    ConfigInvalid FilePath [Text]
  | -- | A profile was asked for that the file does not have.
    UnknownProfile Text Source [Text]
  deriving (Eq, Show)

describeConfigError :: ConfigError -> Text
describeConfigError = \case
  ConfigUnreadable p why -> "The config file " <> T.pack p <> " cannot be read: " <> why
  ConfigInvalid p errs -> "The config file " <> T.pack p <> " is not valid: " <> T.intercalate "; " errs
  UnknownProfile n src known ->
    "There is no embedding profile named "
      <> n
      <> " (from "
      <> sourceText src
      <> "). "
      <> if null known then "The config file has no profiles." else "The profiles are: " <> T.intercalate ", " known <> "."

-- The file ---------------------------------------------------------------

-- | What the TOML file says. Every field is optional.
data FileConfig = FileConfig
  { fcRoot :: Maybe Text,
    fcPolicyRef :: Maybe Text,
    fcTiersRef :: Maybe Text,
    fcAgent :: Maybe Text,
    fcProfile :: Maybe Text,
    fcProfiles :: Map Text Profile
  }
  deriving (Eq, Show)

-- | One table of @[embed.profiles]@.
data Profile = Profile
  { prCommand :: Text,
    prKey :: Text,
    prQueryPrefix :: Text,
    prDocumentPrefix :: Text,
    prMin :: Maybe Double,
    prTimeout :: Maybe Int,
    prMaxChars :: Maybe Int,
    prArgs :: Map Text Text
  }
  deriving (Eq, Show)

-- | The @[embed]@ table.
data EmbedTable = EmbedTable (Maybe Text) (Map Text Profile)

-- | A value of @args@: a string, a number or a boolean, as text.
newtype Arg = Arg Text

instance FromValue FileConfig where
  fromValue = parseTableFromValue $ do
    root <- optKey "root"
    policy <- optKey "policy-ref"
    tiers <- optKey "tiers-ref"
    agent <- optKey "agent"
    EmbedTable profile profiles <- fromMaybe (EmbedTable Nothing Map.empty) <$> optKey "embed"
    pure (FileConfig root policy tiers agent profile profiles)

instance FromValue EmbedTable where
  fromValue = parseTableFromValue (EmbedTable <$> optKey "profile" <*> (fromMaybe Map.empty <$> optKey "profiles"))

instance FromValue Profile where
  fromValue =
    parseTableFromValue $
      Profile
        <$> reqKey "command"
        <*> reqKey "key"
        <*> (fromMaybe "" <$> optKey "query-prefix")
        <*> (fromMaybe "" <$> optKey "document-prefix")
        <*> optKey "min"
        <*> optKey "timeout"
        <*> optKey "max-chars"
        <*> (maybe Map.empty (Map.map (\(Arg a) -> a)) <$> optKey "args")

instance FromValue Arg where
  fromValue = \case
    Text' _ t -> pure (Arg t)
    Integer' _ n -> pure (Arg (T.pack (show n)))
    Double' _ d -> pure (Arg (T.pack (show d)))
    Bool' _ b -> pure (Arg (if b then "true" else "false"))
    _ -> fail "an argument must be a string, a number or a boolean"

-- | Read the text of a TOML file: the settings and the warnings (unknown
-- keys), or the errors. The checks of the values (a timeout above 0, a
-- minimum from -1 to 1) are here too. This function is pure.
parseConfigText :: Text -> Either [Text] (FileConfig, [Text])
parseConfigText t = case decode t of
  Failure es -> Left (map T.pack es)
  Success ws fc -> case concatMap check (Map.toList (fcProfiles fc)) of
    [] -> Right (fc, map T.pack ws)
    es -> Left es
  where
    check (n, p) =
      [ "embed.profiles." <> n <> ".min must be from -1 to 1"
      | Just m <- [prMin p],
        m < -1 || m > 1
      ]
        <> ["embed.profiles." <> n <> ".timeout must be at least 1" | Just s <- [prTimeout p], s < 1]
        <> ["embed.profiles." <> n <> ".max-chars must be at least 1" | Just s <- [prMaxChars p], s < 1]
        <> ["embed.profiles." <> n <> ".command must not be empty" | T.null (T.strip (prCommand p))]
        <> ["embed.profiles." <> n <> ".key must not be empty" | T.null (T.strip (prKey p))]

-- | Read the older @embed.env@: lines of @NAME=value@. The value is
-- everything after the first @=@ (spaces stay). A line that starts with @#@ is
-- a comment, a line may start with @export@ and end with a carriage return,
-- and a value in matching quotes loses them. Nothing else is interpreted.
-- This function is pure.
parseLegacy :: Text -> [(String, String)]
parseLegacy = mapMaybe entry . T.lines
  where
    entry raw
      | T.null (T.strip l) || "#" `T.isPrefixOf` T.stripStart l = Nothing
      | otherwise = case T.breakOn "=" (dropExport (T.stripStart l)) of
          (k, v) | not (T.null v) && not (T.null (T.strip k)) -> Just (T.unpack (T.strip k), T.unpack (unquote (T.drop 1 v)))
          _ -> Nothing
      where
        l = fromMaybe raw (T.stripSuffix "\r" raw)
    dropExport x = maybe x T.stripStart (T.stripPrefix "export " x)
    unquote v
      | T.length v >= 2, T.head v == T.last v, T.head v `elem` ['"', '\''] = T.init (T.tail v)
      | otherwise = v

-- Loading ------------------------------------------------------------------

-- | The files that were found.
data Found = Found
  { foundToml :: Maybe (FilePath, Text),
    foundLegacy :: Maybe (FilePath, Text),
    foundNotes :: [Text]
  }

-- | Find the config file. @$AKYUU_CONFIG@ names one file: TOML if its name
-- ends in @.toml@, else the older format. Without it, the directory is
-- @$XDG_CONFIG_HOME/akyuu@ or @~/.config/akyuu@, and @config.toml@ goes
-- before @embed.env@. A file that is missing is no file.
findFiles :: [(String, String)] -> IO (Either ConfigError Found)
findFiles env = case nonEmpty "AKYUU_CONFIG" of
  Just p
    | ".toml" `isSuffixOf` p -> fmap (\t -> Found ((,) p <$> t) Nothing []) <$> readText p
    | otherwise -> fmap (\t -> Found Nothing ((,) p <$> t) (maybe [] (const [old p]) t)) <$> readText p
  Nothing -> case dir of
    Nothing -> pure (Right (Found Nothing Nothing []))
    Just d -> do
      let tomlPath = d </> "config.toml"
          envPath = d </> "embed.env"
      rt <- readText tomlPath
      rl <- readText envPath
      pure $ do
        t <- rt
        l <- rl
        pure $ case (t, l) of
          (Just tt, Just _) -> Found (Just (tomlPath, tt)) Nothing [T.pack envPath <> " is not read, because " <> T.pack tomlPath <> " is there. Remove it."]
          (Just tt, Nothing) -> Found (Just (tomlPath, tt)) Nothing []
          (Nothing, Just lt) -> Found Nothing (Just (envPath, lt)) [old envPath]
          (Nothing, Nothing) -> Found Nothing Nothing []
  where
    nonEmpty k = case lookup k env of
      Just v | not (null v) -> Just v
      _ -> Nothing
    dir =
      ((</> "akyuu") <$> nonEmpty "XDG_CONFIG_HOME")
        <|> ((\h -> h </> ".config" </> "akyuu") <$> nonEmpty "HOME")
    old p = T.pack p <> " is the older format. Move its settings to config.toml (see akyuu(1)), and remove it."
    readText p = do
      r <- try (BS.readFile p) :: IO (Either IOException BS.ByteString)
      pure $ case r of
        Left _ -> Right Nothing
        Right bs -> either (const (Left (ConfigUnreadable p "it is not UTF-8"))) (Right . Just) (decodeUtf8' bs)

-- | Read the config file and the environment.
loadConfig :: IO (Either ConfigError Config)
loadConfig = do
  env <- getEnvironment
  found <- findFiles env
  pure $ do
    f <- found
    file <- case foundToml f of
      Nothing -> Right Nothing
      Just (p, t) -> either (Left . ConfigInvalid p) (\(fc, ws) -> Right (Just (p, fc, ws))) (parseConfigText t)
    let legacy = (\(p, t) -> (p, parseLegacy t)) <$> foundLegacy f
    c <- resolve env ((\(p, fc, _) -> (p, fc)) <$> file) legacy
    pure c {cfgNotes = foundNotes f <> maybe [] (\(p, _, ws) -> map ((T.pack p <> ": ") <>) ws) file <> cfgNotes c}

-- | Put the @--root@ option over the root of the config.
withRootOption :: Maybe FilePath -> Config -> Config
withRootOption Nothing c = c
withRootOption (Just r) c
  | null r = c
  | otherwise = c {cfgRoot = Just (Sourced r FromFlag)}

-- | Put the settings together: the environment, then the TOML file, then the
-- older file, then the defaults. This function is pure.
resolve :: [(String, String)] -> Maybe (FilePath, FileConfig) -> Maybe (FilePath, [(String, String)]) -> Either ConfigError Config
resolve env file legacy = do
  embed <- embedFrom
  pure
    Config
      { cfgFile = (fst <$> file) <|> (fst <$> legacy),
        cfgRoot =
          (sourced "AKYUU_ROOT" <$> nonEmpty "AKYUU_ROOT")
            <|> (file >>= \(p, fc) -> (\r -> Sourced (expandHome home (T.unpack r)) (FromFile p)) <$> fcRoot fc),
        cfgPolicyRef = textSetting policyRefVar fcPolicyRef defaultPolicyRef,
        cfgTiersRef = textSetting tiersRefVar fcTiersRef defaultTiersRef,
        cfgAgent = textSetting "AKYUU_AGENT" fcAgent "agent",
        cfgEmbed = embed,
        cfgNotes = numberNotes
      }
  where
    home = nonEmpty "HOME"
    nonEmpty k = case lookup k env of
      Just v | not (null v) -> Just v
      _ -> Nothing
    sourced k v = Sourced v (FromEnv k)
    fileValue get = file >>= \(p, fc) -> (\v -> Sourced v (FromFile p)) <$> nonBlank (get fc)
    nonBlank m = m >>= \v -> if T.null (T.strip v) then Nothing else Just v
    textSetting var get def =
      fromMaybe (Sourced def Default) $
        (sourced var . T.pack <$> nonEmpty var) <|> fileValue get

    -- The variables of the older way: the environment, with embed.env under
    -- it. A variable of the environment wins.
    legacyVars = maybe [] (\(p, kvs) -> [(k, (v, FromFile p)) | (k, v) <- kvs, k `notElem` map fst env]) legacy
    embedVars = [(k, (v, FromEnv k)) | (k, v) <- env] <> legacyVars
    embedVar k = case lookup k embedVars of
      Just (v, s) | not (null v) -> Just (v, s)
      _ -> Nothing

    -- Numbers that override a profile. A value that is not a number is left
    -- out, and the notes say so.
    positive k = embedVar k >>= positiveNumber . fst
    minVar = embedVar "AKYUU_EMBED_MIN" >>= similarity . fst
    numberNotes =
      [ "$" <> T.pack k <> " is not a number in range, so it is left out: " <> T.pack v
      | (k, valid) <-
          [ ("AKYUU_EMBED_TIMEOUT", maybe False (const True) . positiveNumber),
            ("AKYUU_EMBED_MAX_CHARS", maybe False (const True) . positiveNumber),
            ("AKYUU_EMBED_MIN", maybe False (const True) . similarity)
          ],
        Just (v, _) <- [embedVar k],
        not (valid v)
      ]
    positiveNumber v = readMaybe v >>= \n -> if n > 0 then Just (n :: Int) else Nothing
    similarity v = readMaybe v >>= \m -> if m >= -1 && m <= 1 then Just (m :: Double) else Nothing

    embedFrom = case embedVar "AKYUU_EMBED_COMMAND" of
      Just (cmd, src) | not (all (== ' ') cmd) -> Right (Just (environmentProfile cmd src embedVars positive minVar))
      _ -> fromProfiles
    fromProfiles =
      let profiles = maybe Map.empty (fcProfiles . snd) file
          wanted =
            ((\v -> (T.pack v, FromEnv "AKYUU_EMBED_PROFILE")) <$> nonEmpty "AKYUU_EMBED_PROFILE")
              <|> (file >>= \(p, fc) -> (\n -> (n, FromFile p)) <$> nonBlank (fcProfile fc))
              <|> case (file, Map.toList profiles) of
                (Just (p, _), [(n, _)]) -> Just (n, FromFile p)
                _ -> Nothing
       in case wanted of
            Nothing
              | Map.null profiles -> Right Nothing
              | otherwise -> Left (ConfigInvalid (maybe "" fst file) ["embed.profile must name one of the profiles: " <> T.intercalate ", " (Map.keys profiles)])
            Just (n, src) -> case Map.lookup n profiles of
              Nothing -> Left (UnknownProfile n src (Map.keys profiles))
              Just pr -> Right (Just (fromProfile n src pr))
    fromProfile n src pr =
      EmbedSettings
        { esProfile = n,
          esSource = src,
          esCommand = prCommand pr,
          esKey = prKey pr,
          esQueryPrefix = prQueryPrefix pr,
          esDocumentPrefix = prDocumentPrefix pr,
          esMin = minVar <|> prMin pr,
          esTimeout = min 3600 (fromMaybe 10 (positive "AKYUU_EMBED_TIMEOUT" <|> prTimeout pr)),
          esMaxChars = fromMaybe 4000 (positive "AKYUU_EMBED_MAX_CHARS" <|> prMaxChars pr),
          esArgs = Map.toList (prArgs pr),
          esCommandEnv = [(k, v) | (k, v) <- env, k `notElem` map fst argVars] <> argVars
        }
      where
        argVars = [(argVar k, T.unpack v) | (k, v) <- Map.toList (prArgs pr)]

-- | The profile of the older variables: @AKYUU_EMBED_COMMAND@ and the rest,
-- from the environment and @embed.env@. The command gets them all, as before.
-- This function is pure.
environmentProfile ::
  String ->
  Source ->
  [(String, (String, Source))] ->
  (String -> Maybe Int) ->
  Maybe Double ->
  EmbedSettings
environmentProfile cmd src vars positive minVar =
  EmbedSettings
    { esProfile = "environment",
      esSource = src,
      esCommand = T.pack cmd,
      esKey = maybe (T.pack cmd) T.pack (get "AKYUU_EMBED_MODEL"),
      esQueryPrefix = maybe "" T.pack (get "AKYUU_EMBED_QUERY_PREFIX"),
      esDocumentPrefix = maybe "" T.pack (get "AKYUU_EMBED_DOCUMENT_PREFIX"),
      esMin = minVar,
      esTimeout = min 3600 (fromMaybe 10 (positive "AKYUU_EMBED_TIMEOUT")),
      esMaxChars = fromMaybe 4000 (positive "AKYUU_EMBED_MAX_CHARS"),
      esArgs = [(T.pack k, T.pack v) | (k, (v, _)) <- vars, "AKYUU_EMBED_" `isPrefixOf` k, k `notElem` control],
      esCommandEnv = [(k, v) | (k, (v, _)) <- vars]
    }
  where
    get k = case lookup k vars of
      Just (v, _) | not (null v) -> Just v
      _ -> Nothing
    control = ["AKYUU_EMBED_COMMAND", "AKYUU_EMBED_MODEL", "AKYUU_EMBED_MIN", "AKYUU_EMBED_TIMEOUT", "AKYUU_EMBED_MAX_CHARS", "AKYUU_EMBED_ROLE", "AKYUU_EMBED_PROFILE"]

-- | The variable of an argument: @gguf@ is @AKYUU_EMBED_GGUF@, and
-- @api-model@ is @AKYUU_EMBED_API_MODEL@.
argVar :: Text -> String
argVar k = "AKYUU_EMBED_" <> map (\c -> if isAlphaNum c then toUpper c else '_') (T.unpack k)

-- | Expand a leading @~/@ with the home directory. This function is pure.
expandHome :: Maybe FilePath -> FilePath -> FilePath
expandHome (Just h) ('~' : '/' : rest) = h </> rest
expandHome (Just h) "~" = h
expandHome _ p = p
