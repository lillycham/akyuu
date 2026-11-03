-- | The append-only protocol tree. Git has its own bare repository; no command
-- checks out files into a live store. Imported bytes pass strict validation.
module Akyuu.Sync.Git
  ( Bundle (..),
    GitError (..),
    prepare,
    fetch,
    readBundle,
    writeBundle,
    push,
    ancestor,
    bundleAt,
    maxArchiveBytes,
    describeGitError,
  )
where

import Akyuu.Id (Id)
import Akyuu.Id qualified as Id
import Akyuu.Memory (renderMemory)
import Akyuu.Sync.Checkpoint (checkpointObjects)
import Akyuu.Sync.Event (eventAction, renderEvent)
import Akyuu.Sync.Process (Deadline, ProcessError (GitFailed), runGit)
import Akyuu.Sync.Repository (RepositoryError, Snapshot, readMemory, snapshotCheckpoint, snapshotState, verifyIncoming)
import Akyuu.Sync.State (State, events, storeId)
import Akyuu.Sync.Types (Action (RegisterReplica), EventId (EventId), StoreId (StoreId), parseIdentifier, renderIdentifier)
import Control.Monad (forM_, unless, void, when)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Except (ExceptT (ExceptT), runExceptT, throwE)
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.Char (isHexDigit)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (decodeUtf8', encodeUtf8)
import Data.Time.Clock.POSIX (getPOSIXTime)
import System.Directory (createDirectory, doesDirectoryExist)

data Bundle = Bundle {bundleState :: State, bundlePayloads :: Map Id ByteString} deriving (Eq, Show)

data GitError = GitCommand Text ProcessError | InvalidArchive Text | ArchiveStorage RepositoryError deriving (Eq, Show)

maxArchiveBytes :: Int
maxArchiveBytes = 256 * 1024 * 1024

git :: Deadline -> FilePath -> [String] -> ByteString -> Int -> ExceptT GitError IO ByteString
git end root args input cap = ExceptT (first (GitCommand (T.pack (case args of command : _ -> command; _ -> "git"))) <$> runGit end (Just root) (["--git-dir", root] <> args) input cap)

prepare :: Deadline -> FilePath -> IO (Either GitError ())
prepare end path = runExceptT $ do
  exists <- lift (doesDirectoryExist path)
  unless exists $ do
    lift (createDirectory path)
    _ <- ExceptT (first (GitCommand "init") <$> runGit end Nothing ["init", "--bare", "--quiet", path] "" 16384)
    pure ()
  bare <- git end path ["rev-parse", "--is-bare-repository"] "" 32
  unless (bare == "true\n") (throwE (InvalidArchive "Transport requires its own bare Git repository."))
  pure ()

-- ls-remote distinguishes an empty branch from a fetch/network failure.
fetch :: Deadline -> FilePath -> Text -> Text -> IO (Either GitError (Maybe Text))
fetch end root remote branch = runExceptT $ do
  advertised <- git end root ["ls-remote", "--refs", "--", T.unpack remote, T.unpack branch] "" 16384
  if BS.null advertised
    then pure Nothing
    else do
      case BC.words advertised of
        [hash, ref] | ref == encodeUtf8 branch && validHash hash -> pure ()
        _ -> throwE (InvalidArchive "The remote advertised an invalid branch tip.")
      _ <- git end root ["fetch", "--quiet", "--no-tags", "--no-recurse-submodules", "--", T.unpack remote, T.unpack ("+" <> branch <> ":refs/akyuu/fetched")] "" 16384
      tip <- git end root ["rev-parse", "--verify", "refs/akyuu/fetched^{commit}"] "" 128
      either throwE (pure . Just) (hashText tip)

ancestor :: Deadline -> FilePath -> Text -> Text -> IO (Either GitError Bool)
ancestor end root older newer = do
  outcome <- runExceptT (git end root ["merge-base", "--is-ancestor", T.unpack older, T.unpack newer] "" 1024)
  pure $ case outcome of Right _ -> Right True; Left (GitCommand _ (GitFailed 1)) -> Right False; Left err -> Left err

data Entry = Entry ByteString Int FilePath deriving (Eq, Show)

readBundle :: Deadline -> FilePath -> Text -> IO (Either GitError Bundle)
readBundle end root tip = runExceptT $ do
  listing <- git end root ["ls-tree", "-r", "-t", "-z", "--full-tree", "--long", T.unpack tip] "" (16 * 1024 * 1024)
  entries <- either throwE pure (parseTree listing)
  let blobs = [(hash, size, path) | Entry hash size path <- entries]
  output <- git end root ["cat-file", "--batch"] (BS.concat [hash <> "\n" | (hash, _, _) <- blobs]) (maxArchiveBytes + 8 * 1024 * 1024)
  files <- either throwE pure (parseBlobs blobs output)
  protocol <- required "protocol" files
  unless (protocol == "akyuu-sync-v1\n") (throwE (InvalidArchive "Unsupported sync protocol."))
  identity <- required "store-id" files
  text <- either (const (throwE (InvalidArchive "Invalid store identity."))) pure (decodeUtf8' identity)
  store <- either (const (throwE (InvalidArchive "Invalid store identity."))) pure (StoreId <$> parseIdentifier (T.dropEnd 1 text))
  let StoreId value = store
  unless (identity == encodeUtf8 (renderIdentifier value <> "\n")) (throwE (InvalidArchive "Noncanonical store identity."))
  let eventFiles = [(EventId digest, bytes) | (path, bytes) <- Map.toList files, Just digest <- [eventPathId path]]
      payloads = Map.fromList [(digest, bytes) | (path, bytes) <- Map.toList files, Just digest <- [objectPathId path]]
  state <- ExceptT (first ArchiveStorage <$> verifyIncoming store eventFiles (Map.toList payloads))
  unless (length eventFiles == Map.size (events state)) (throwE (InvalidArchive "Duplicate event identities in the archive."))
  -- Registration events have one canonical directory; moving them changes
  -- the tree contract even when their content hash remains valid.
  forM_ (Map.toList (events state)) $ \(key, event) -> do
    let path = eventPath key (eventAction event)
    unless (Map.lookup path files == Just (renderEvent event)) (throwE (InvalidArchive "An event has the wrong protocol path."))
  pure (Bundle state payloads)
  where
    required key files = maybe (throwE (InvalidArchive "Missing protocol metadata.")) pure (Map.lookup key files)

parseTree :: ByteString -> Either GitError [Entry]
parseTree bytes = do
  let records = filter (not . BS.null) (BC.split '\0' bytes)
  when (length records > 100000) (Left (InvalidArchive "The archive has too many entries."))
  entries <- traverse entry records
  let blobs = concat entries
  unless (sum [toInteger size | Entry _ size _ <- blobs] <= toInteger maxArchiveBytes) (Left (InvalidArchive "The archive exceeds 256 MiB."))
  unless (Set.size (Set.fromList [path | Entry _ _ path <- blobs]) == length blobs) (Left (InvalidArchive "Duplicate archive paths."))
  pure blobs
  where
    entry record = case BC.break (== '\t') record of
      (header, suffix) -> do
        path <- either (const (Left (InvalidArchive "An archive path is not UTF-8."))) (Right . T.unpack) (decodeUtf8' (BS.drop 1 suffix))
        case BC.words header of
          ["040000", "tree", hash, "-"] | validHash hash && directory path -> Right []
          ["100644", "blob", hash, size] | validHash hash && allowed path -> case BC.readInt size of
            Just (n, rest) | BS.null rest && n >= 0 && n <= bound path -> Right [Entry hash n path]
            _ -> Left (InvalidArchive "An archive record exceeds its size limit.")
          _ -> Left (InvalidArchive "Unsupported archive path, mode or entry type.")
    directory path = path `elem` ["events", "registry", "objects"] || (take 8 path == "objects/" && length path == 10 && all lowerHex (drop 8 path))
    allowed path = path `elem` ["protocol", "store-id"] || maybe False (const True) (eventPathId path) || maybe False (const True) (objectPathId path)
    bound path
      | path `elem` ["protocol", "store-id"] = 128
      | take 8 path == "objects/" = 16 * 1024 * 1024
      | otherwise = 64 * 1024

parseBlobs :: [(ByteString, Int, FilePath)] -> ByteString -> Either GitError (Map FilePath ByteString)
parseBlobs [] rest | BS.null rest = Right Map.empty
parseBlobs ((hash, size, path) : more) bytes = do
  let (header, tailBytes) = BC.break (== '\n') bytes
      payload = BS.take size (BS.drop 1 tailBytes)
      rest = BS.drop (size + 1) (BS.drop 1 tailBytes)
  unless (BC.words header == [hash, "blob", BC.pack (show size)] && BS.length payload == size && BS.take 1 (BS.drop size (BS.drop 1 tailBytes)) == "\n") (Left (InvalidArchive "Invalid Git blob response."))
  Map.insert path payload <$> parseBlobs more rest
parseBlobs _ _ = Left (InvalidArchive "Unexpected Git blob response.")

bundleAt :: Snapshot -> IO (Either GitError Bundle)
bundleAt snapshot = runExceptT $ do
  payloads <- traverse (\i -> (i,) . renderMemory <$> ExceptT (first ArchiveStorage <$> readMemory snapshot i)) (Set.toAscList (checkpointObjects (snapshotCheckpoint snapshot)))
  pure (Bundle (snapshotState snapshot) (Map.fromList payloads))

writeBundle :: Deadline -> FilePath -> Maybe Text -> Bundle -> IO (Either GitError Text)
writeBundle end root parent bundle = runExceptT $ do
  let state = bundleState bundle
      StoreId identity = storeId state
      files =
        Map.fromList
          ( [("protocol", "akyuu-sync-v1\n"), ("store-id", encodeUtf8 (renderIdentifier identity <> "\n"))]
              <> [(eventPath key (eventAction event), renderEvent event) | (key, event) <- Map.toList (events state)]
              <> [(objectPath digest, bytes) | (digest, bytes) <- Map.toList (bundlePayloads bundle)]
          )
  when (sum (map (toInteger . BS.length) (Map.elems files)) > toInteger maxArchiveBytes) (throwE (InvalidArchive "The archive exceeds 256 MiB."))
  when (Map.size files > 100000) (throwE (InvalidArchive "The archive has too many entries."))
  now <- lift getPOSIXTime
  let numbered = zip [1 :: Int ..] (Map.toAscList files)
      number = BC.pack . show
      message = "Publish accepted memory archive.\n"
      stream =
        BS.concat
          ( ["blob\nmark :" <> number n <> "\ndata " <> number (BS.length bytes) <> "\n" <> bytes <> "\n" | (n, (_, bytes)) <- numbered]
              <> ["reset refs/akyuu/prepared\n\ncommit refs/akyuu/prepared\ncommitter Akyuu sync <sync@localhost> " <> number (floor now :: Int) <> " +0000\ndata " <> number (BS.length message) <> "\n" <> message]
              <> maybe [] (\p -> ["from " <> encodeUtf8 p <> "\n"]) parent
              <> ["deleteall\n"]
              <> ["M 100644 :" <> number n <> " " <> BC.pack path <> "\n" | (n, (path, _)) <- numbered]
              <> ["\ndone\n"]
          )
  -- Only the private prepared ref is replaceable. A push race can leave an
  -- unpublished proposal here. Remote pushes below never use force.
  _ <- git end root ["fast-import", "--quiet", "--done", "--force"] stream 16384
  commit <- git end root ["rev-parse", "--verify", "refs/akyuu/prepared^{commit}"] "" 128
  either throwE pure (hashText commit)

push :: Deadline -> FilePath -> Text -> Text -> Text -> IO (Either GitError ())
push end root remote branch commit = runExceptT $ void (git end root ["push", "--quiet", "--", T.unpack remote, T.unpack (commit <> ":" <> branch)] "" 16384)

eventPath :: EventId -> Action -> FilePath
eventPath (EventId digest) action = (case action of RegisterReplica _ _ -> "registry/"; _ -> "events/") <> T.unpack (Id.render digest)

objectPath :: Id -> FilePath
objectPath digest = let text = T.unpack (Id.render digest) in "objects/" <> take 2 (drop 7 text) <> "/" <> text <> ".md"

eventPathId :: FilePath -> Maybe Id
eventPathId path = case break (== '/') path of (dir, '/' : name) | dir `elem` ["events", "registry"] -> either (const Nothing) Just (Id.parse (T.pack name)); _ -> Nothing

objectPathId :: FilePath -> Maybe Id
objectPathId path = case split path of
  ["objects", shard, name] | reverse (take 3 (reverse name)) == ".md" -> do
    digest <- either (const Nothing) Just (Id.parse (T.pack (take (length name - 3) name)))
    if objectPath digest == path && length shard == 2 then Just digest else Nothing
  _ -> Nothing
  where
    split value = case break (== '/') value of (part, []) -> [part]; (part, _ : rest) -> part : split rest

validHash :: ByteString -> Bool
validHash value = BS.length value == 40 && BC.all lowerHex value

lowerHex :: Char -> Bool
lowerHex c = isHexDigit c && c `notElem` ['A' .. 'F']

hashText :: ByteString -> Either GitError Text
hashText bytes = let hash = BC.takeWhile (/= '\n') bytes in if bytes == hash <> "\n" && validHash hash then Right (T.pack (BC.unpack hash)) else Left (InvalidArchive "Invalid Git object ID.")

describeGitError :: GitError -> Text
describeGitError err = case err of GitCommand command failure -> "Git " <> command <> " failed: " <> T.pack (show failure); InvalidArchive message -> message; ArchiveStorage _ -> "The archive has invalid events or memory dependencies."
