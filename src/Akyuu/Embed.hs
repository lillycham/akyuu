{-# LANGUAGE OverloadedStrings #-}

-- | Search by meaning: vectors for the bodies of the memories.
--
-- Akyuu runs no model and names none. A person sets a command. The command
-- reads a text on stdin and writes a vector on stdout, so any runtime can sit
-- behind it (LM Studio, Ollama, llama.cpp, MLX, a script). The command and the
-- name of the model come from the environment:
--
-- > AKYUU_EMBED_COMMAND   the command, run with sh -c
-- > AKYUU_EMBED_MODEL     the key of the vectors (default: the command)
-- > AKYUU_EMBED_TIMEOUT   seconds for one call (default 10)
-- > AKYUU_EMBED_MAX_CHARS the most characters sent for one memory (default 4000)
--
-- The command gets @AKYUU_EMBED_ROLE=query@ or @document@, because some models
-- want a different prefix for each.
--
-- An embedding is derived data that is keyed by an 'Id', and an 'Id' names
-- one text, so a vector is never out of date. The vectors are in their own
-- file (@embeddings.sqlite@ in the root of the store), not in the cache: the
-- cache is thrown away often, and a vector costs a model call. The model is
-- part of the key. A vector from another model is never compared.
--
-- This module has the pure parts (vectors, similarity, fusion, the formats)
-- and the parts that run the command and keep the table.
module Akyuu.Embed
  ( -- * Vectors
    Vector,
    cosine,
    encodeVector,
    decodeVector,
    parseVector,
    rankBySimilarity,
    chunkText,
    maxChunks,
    fuse,

    -- * The command
    Embedder (..),
    Role (..),
    embedderFromEnv,
    embedSettings,
    runEmbedder,
    embedText,

    -- * The table
    VectorStore,
    vectorsPath,
    openVectors,
    closeVectors,
    putVectors,
    loadVectors,
    storedIds,
    pruneVectors,
  )
where

import Akyuu.Id (Id)
import Akyuu.Id qualified as Id
import Control.Applicative ((<|>))
import Control.Exception (IOException, SomeException, bracketOnError, onException, try)
import Control.Monad (forM_)
import Data.Aeson (Value (Array, Number, Object))
import Data.Aeson qualified as A
import Data.Aeson.KeyMap qualified as KM
import Data.Bits (shiftL, (.|.))
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Builder (floatLE, toLazyByteString)
import Data.ByteString.Lazy qualified as BL
import Data.List (sortOn)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Ord (Down (Down))
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (decodeUtf8', encodeUtf8)
import Database.SQLite.Simple (Connection, Only (Only), close, execute, execute_, open, query, query_, withTransaction)
import GHC.Float (castWord32ToFloat)
import System.Environment (getEnvironment)
import System.Exit (ExitCode (ExitSuccess))
import System.FilePath ((</>))
import System.IO (hClose, hSetBinaryMode)
import System.Posix.Signals (sigTERM, signalProcessGroup)
import System.Process (CreateProcess (create_group, env, std_err, std_in, std_out), ProcessHandle, StdStream (CreatePipe, NoStream), getPid, shell, waitForProcess, withCreateProcess)
import System.Timeout (timeout)
import Text.Read (readMaybe)

-- | A vector of one model.
type Vector = [Float]

-- Pure parts -----------------------------------------------------------

-- | The cosine similarity of two vectors, from -1 to 1. A zero vector, and
-- vectors of two lengths, give 0. This function is pure.
cosine :: Vector -> Vector -> Double
cosine a b
  | length a /= length b || na == 0 || nb == 0 = 0
  | otherwise = dot / (sqrt na * sqrt nb)
  where
    dot = foldl' (+) 0 (zipWith (\x y -> realToFrac x * realToFrac y) a b)
    na = sumSq a
    nb = sumSq b
    sumSq = foldl' (\s x -> s + realToFrac x * realToFrac x) (0 :: Double)

-- | A vector as bytes: 4 bytes for each number, little-endian IEEE 754.
encodeVector :: Vector -> ByteString
encodeVector = BL.toStrict . toLazyByteString . foldMap floatLE

-- | The inverse of 'encodeVector'. 'Nothing' if the length is not a multiple
-- of 4.
decodeVector :: ByteString -> Maybe Vector
decodeVector bs
  | BS.length bs `mod` 4 /= 0 = Nothing
  | otherwise = Just (go (BS.unpack bs))
  where
    go (a : b : c : d : rest) = castWord32ToFloat (w a 0 .|. w b 8 .|. w c 16 .|. w d 24) : go rest
    go _ = []
    w x s = fromIntegral x `shiftL` s

-- | Read the output of a command. Four shapes are accepted, so that the
-- answer of a model server can be used as it is:
--
-- * a JSON array of numbers;
-- * @{"embedding": [...]}@ (Ollama);
-- * @{"embeddings": [[...]]}@ (Ollama, the first vector);
-- * @{"data": [{"embedding": [...]}]}@ (OpenAI, LM Studio, llama.cpp).
--
-- Anything else, and an empty vector, is an error with a text.
parseVector :: ByteString -> Either Text Vector
parseVector bs = case A.eitherDecodeStrict bs of
  Left _ -> Left "The embedding command did not print JSON."
  Right v -> maybe (Left "The embedding command printed JSON that has no vector.") nonEmpty (find' v)
  where
    nonEmpty [] = Left "The embedding command printed an empty vector."
    nonEmpty xs = Right xs
    find' v = case v of
      Array xs | all isNum xs -> nums xs
      Object o ->
        firstJust
          [ KM.lookup "embedding" o >>= find',
            KM.lookup "embeddings" o >>= firstElem >>= find',
            KM.lookup "data" o >>= firstElem >>= find'
          ]
      _ -> Nothing
    isNum (Number _) = True
    isNum _ = False
    nums xs = traverse (\x -> case x of Number n -> Just (realToFrac n); _ -> Nothing) (foldr (:) [] xs)
    firstElem (Array xs) = case foldr (:) [] xs of
      (x : _) -> Just x
      [] -> Nothing
    firstElem _ = Nothing
    firstJust = foldr (\m r -> maybe r Just m) Nothing

-- | The memories ordered by cosine similarity to the query, best first,
-- with the similarity. Vectors of another length than the query are left
-- out. This function is pure.
--
-- A memory can have several vectors (one for each chunk of a long text). It
-- appears once, with the best of them.
rankBySimilarity :: Vector -> [(Id, Vector)] -> [(Id, Double)]
rankBySimilarity q vs =
  sortOn (\(i, s) -> (Down s, i)) (Map.toList (Map.fromListWith max [(i, cosine q v) | (i, v) <- vs, length v == length q]))

-- | The most chunks of one memory that get a vector. A longer memory is
-- embedded from its start: that is its first 'maxChunks' chunks.
maxChunks :: Int
maxChunks = 8

-- | Cut a text into chunks of at most @n@ characters, for a model with a
-- limited input. The cuts are at blank lines where they can be, so a
-- paragraph stays whole; a paragraph longer than @n@ is cut at @n@. A text
-- that fits is one chunk. An empty text is one empty chunk. This function is
-- pure.
chunkText :: Int -> Text -> [Text]
chunkText n t
  | T.length t <= n = [t]
  | otherwise = pack' [] (concatMap hard (T.splitOn "\n\n" t))
  where
    hard p
      | T.length p <= n = [p]
      | otherwise = T.chunksOf n p
    pack' acc [] = [T.intercalate "\n\n" (reverse acc) | not (null acc)]
    pack' acc (p : ps)
      | null acc = pack' [p] ps
      | T.length (T.intercalate "\n\n" (reverse (p : acc))) <= n = pack' (p : acc) ps
      | otherwise = T.intercalate "\n\n" (reverse acc) : pack' [p] ps

-- | Reciprocal rank fusion of ranked lists: a memory scores @1 / (60 + r)@
-- in each list (r from 1), and the scores add. The order is by score, and
-- an equal score keeps the place in the first list that has the memory. The
-- sum does not use the scores of the lists, so lists with different scales
-- (bm25 and cosine) can be joined. This function is pure.
fuse :: [[Id]] -> [Id]
fuse lists = map fst (sortOn (\(i, s) -> (Down s, firstSeen i)) (Map.toList scores))
  where
    scores = Map.fromListWith (+) [(i, 1 / (60 + fromIntegral r)) | l <- lists, (r, i) <- zip [1 :: Int ..] l] :: Map.Map Id Double
    firstSeen i = Map.findWithDefault (maxBound :: Int) i order
    order = Map.fromListWith min [(i, k) | (k, i) <- zip [0 ..] (concat lists)]

-- The command ----------------------------------------------------------

-- | What the command is, from the environment.
data Embedder = Embedder
  { embCommand :: Text,
    -- | The key of the vectors.
    embModel :: Text,
    -- | Seconds for one call.
    embTimeout :: Int,
    -- | The most characters of a text that the command gets.
    embMaxChars :: Int
  }
  deriving (Eq, Show)

-- | Who the text is for: the memory that is stored, or the words of a search.
data Role = Document | QueryText
  deriving (Eq, Show)

-- | The embedder that the environment names, or 'Nothing' if
-- @AKYUU_EMBED_COMMAND@ is not set or is empty.
-- | The environment, with the settings of the config file under it. The
-- file is @$AKYUU_CONFIG@, or @$XDG_CONFIG_HOME/akyuu/embed.env@, or
-- @~/.config/akyuu/embed.env@. A line is @NAME=value@, and the value is
-- everything after the first @=@ (spaces stay). A line that starts with @#@
-- is a comment. A variable of the real environment wins over the file.
--
-- The file is for a client that does not start in a shell with the variables
-- (a desktop app, a service): all of them then read the same settings. A
-- missing or unreadable file is no file.
embedSettings :: IO [(String, String)]
embedSettings = do
  e <- getEnvironment
  let path =
        lookup "AKYUU_CONFIG" e
          <|> ((</> "akyuu" </> "embed.env") <$> lookup "XDG_CONFIG_HOME" e)
          <|> ((</> ".config" </> "akyuu" </> "embed.env") <$> lookup "HOME" e)
  r <- maybe (pure (Left ())) (\p -> either (const (Left ())) Right <$> (try (BS.readFile p) :: IO (Either IOException ByteString))) path
  let fromFile = case r of
        Right bs | Right t <- decodeUtf8' bs -> mapMaybe entry (T.lines t)
        _ -> []
      -- A line may start with export, and may end with a carriage return. A
      -- value in matching quotes loses them. Nothing else is interpreted.
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
  pure (e <> [kv | kv@(k, _) <- fromFile, k `notElem` map fst e])

embedderFromEnv :: IO (Maybe Embedder)
embedderFromEnv = do
  e <- embedSettings
  let get k = T.pack <$> lookup k e
      num k d = fromMaybe d (lookup k e >>= readMaybe >>= \n -> if n > 0 then Just n else Nothing)
  pure $ case get "AKYUU_EMBED_COMMAND" of
    Just c
      | not (T.null (T.strip c)) ->
          Just
            Embedder
              { embCommand = c,
                embModel = fromMaybe c (get "AKYUU_EMBED_MODEL"),
                -- At most an hour, so that the microseconds cannot overflow.
                embTimeout = min 3600 (num "AKYUU_EMBED_TIMEOUT" 10),
                embMaxChars = num "AKYUU_EMBED_MAX_CHARS" 4000
              }
    _ -> Nothing

-- | Run the command on a text and read the vector. A failure of any kind
-- (the command is missing, it exits with an error, it takes too long, its
-- output is not a vector) is a 'Left' with a text, never an exception.
runEmbedder :: Embedder -> Role -> Text -> IO (Either Text Vector)
runEmbedder e role t = do
  base <- embedSettings
  let role' = case role of Document -> "document"; QueryText -> "query"
      proc' =
        (shell (T.unpack (embCommand e)))
          { std_in = CreatePipe,
            std_out = CreatePipe,
            std_err = NoStream,
            env = Just (("AKYUU_EMBED_ROLE", role') : filter ((/= "AKYUU_EMBED_ROLE") . fst) base),
            -- Its own process group, so that a timeout stops the children too
            -- (the curl of a script), not only the shell.
            create_group = True
          }
      input = encodeUtf8 (T.take (embMaxChars e) t)
      go = withCreateProcess proc' $ \mi mo _ ph -> flip onException (stopGroup ph) $ case (mi, mo) of
        (Just hin, Just hout) -> do
          hSetBinaryMode hin True
          hSetBinaryMode hout True
          -- A command that exits before it reads its input closes the pipe.
          _ <- try (BS.hPut hin input) :: IO (Either IOException ())
          _ <- try (hClose hin) :: IO (Either IOException ())
          out <- BS.hGetContents hout
          code <- waitForProcess ph
          pure (code, out)
        _ -> ioError (userError "no pipes")
  r <- try (timeout (embTimeout e * 1000000) go) :: IO (Either SomeException (Maybe (ExitCode, ByteString)))
  pure $ case r of
    Left ex -> Left ("The embedding command could not run: " <> T.pack (show ex))
    Right Nothing -> Left ("The embedding command took more than " <> T.pack (show (embTimeout e)) <> " seconds.")
    Right (Just (code, out))
      | code /= ExitSuccess -> Left ("The embedding command failed (" <> T.pack (show code) <> ").")
      | otherwise -> either (Left . ("The embedding command: " <>)) Right (parseVector out)

-- | The vectors of a whole memory: one for each chunk ('chunkText'), at most
-- 'maxChunks'. The first failure is the result.
embedText :: Embedder -> Role -> Text -> IO (Either Text [Vector])
embedText e role t = sequence <$> mapM (runEmbedder e role) (take maxChunks (chunkText (embMaxChars e) t))

-- The table ------------------------------------------------------------

-- | The open table of vectors.
newtype VectorStore = VectorStore Connection

-- | @\<root\>/embeddings.sqlite@.
vectorsPath :: FilePath -> FilePath
vectorsPath root = root </> "embeddings.sqlite"

-- | Open the table, and make it if the file is new. The table is
-- @chunks(id, model, chunk, dim, vec)@ with the key @(id, model, chunk)@.
-- The table of version 0.1.0.0 (@vectors@, one vector for each memory) is
-- dropped: it is derived data, and @akyuu embed@ makes the vectors again.
openVectors :: FilePath -> IO (Either Text VectorStore)
openVectors path = do
  r <- try $ bracketOnError (open path) close $ \c -> do
    -- Two processes can write at once (akyuu embed and a server): wait.
    execute_ c "PRAGMA busy_timeout = 5000"
    execute_ c "PRAGMA journal_mode = WAL"
    execute_ c "DROP TABLE IF EXISTS vectors"
    execute_ c "CREATE TABLE IF NOT EXISTS chunks (id TEXT NOT NULL, model TEXT NOT NULL, chunk INTEGER NOT NULL, dim INTEGER NOT NULL, vec BLOB NOT NULL, PRIMARY KEY (id, model, chunk)) WITHOUT ROWID"
    pure (VectorStore c)
  pure (either (\e -> Left (T.pack (show (e :: SomeException)))) Right r)

closeVectors :: VectorStore -> IO ()
closeVectors (VectorStore c) = close c

-- | Keep the vectors of a memory, one for each chunk. They replace the vectors
-- that the memory had for the model.
putVectors :: VectorStore -> Text -> Id -> [Vector] -> IO ()
putVectors (VectorStore c) model i vs =
  withTransaction c $ do
    execute c "DELETE FROM chunks WHERE id = ? AND model = ?" (Id.render i, model)
    forM_ (zip [0 :: Int ..] vs) $ \(k, v) ->
      execute c "INSERT INTO chunks (id, model, chunk, dim, vec) VALUES (?, ?, ?, ?, ?)" (Id.render i, model, k, length v, encodeVector v)

-- | Remove the vectors of other models, and of memories that are not in the
-- set (GC deleted them). Returns the number of rows removed.
pruneVectors :: VectorStore -> Text -> Set Id -> IO Int
pruneVectors (VectorStore c) model live = do
  rows <- query_ c "SELECT DISTINCT id, model FROM chunks" :: IO [(Text, Text)]
  let gone = [(i, m) | (i, m) <- rows, m /= model || either (const True) (`Set.notMember` live) (Id.parse i)]
  withTransaction c $ forM_ gone $ \(i, m) -> execute c "DELETE FROM chunks WHERE id = ? AND model = ?" (i, m)
  pure (length gone)

-- | The vectors of a model. A row that cannot be read is left out.
loadVectors :: VectorStore -> Text -> IO [(Id, Vector)]
loadVectors (VectorStore c) model = do
  rows <- query c "SELECT id, vec FROM chunks WHERE model = ?" (Only model) :: IO [(Text, ByteString)]
  pure (mapMaybe (\(i, b) -> (,) <$> either (const Nothing) Just (Id.parse i) <*> decodeVector b) rows)

-- | The memories that have a vector of this model.
storedIds :: VectorStore -> Text -> IO (Set Id)
storedIds s model = Set.fromList . map fst <$> loadVectors s model

-- | Stop the process group of a command (its shell and the children).
-- An error (the group is gone) is ignored.
stopGroup :: ProcessHandle -> IO ()
stopGroup ph = do
  mp <- getPid ph
  forM_ mp (\p -> (try (signalProcessGroup sigTERM p) :: IO (Either SomeException ())))
