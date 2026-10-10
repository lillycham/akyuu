{-# LANGUAGE OverloadedStrings #-}

module RefsTests (refsTests) where

import Akyuu.Id (Id, IdParseError (..), hashBytes)
import Akyuu.Id qualified as Id
import Akyuu.Refs
import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Monad (forM, forM_)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.List (sort)
import Data.Maybe (isJust)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Support (nid, right, withTempDir)
import System.FileLock (SharedExclusive (Exclusive), tryLockFile, unlockFile, withFileLock)
import System.Directory
  ( createDirectory
  , createDirectoryIfMissing
  , doesDirectoryExist
  , listDirectory
  )
import System.FilePath (takeDirectory, (</>))
import Test.Tasty
import Test.Tasty.HUnit
import Test.Tasty.QuickCheck

refsTests :: TestTree
refsTests =
  testGroup
    "Akyuu.Refs"
    [ nameTests
    , advanceTests
    , retainedTests
    , formatTests
    , openTests
    , pathTests
    , getTests
    , setTests
    , lockTests
    , listTests
    , properties
    ]

-- Test helpers ---------------------------------------------------------

-- A fresh, open refs directory. The test gets the refs and the directory
-- above the root.
withRefs :: (Refs -> FilePath -> IO a) -> IO a
withRefs act = withTempDir $ \dir -> do
  opened <- openRefs (dir </> "s")
  case opened of
    Left e -> assertFailure ("openRefs failed: " ++ show e)
    Right r -> act r dir

-- A name that the test knows is valid.
nm :: Text -> Name
nm = either (error . show) id . mkName

-- The file that the lock is on.
lockPath :: Refs -> FilePath
lockPath r = refsRoot r </> "refs" </> ".lock"

-- Put bytes in the file of a name, without the module's own functions.
-- The tests use it to make refs that are damaged.
plant :: Refs -> Name -> ByteString -> IO ()
plant r n bytes = do
  let path = refPath r n
  createDirectoryIfMissing True (takeDirectory path)
  BS.writeFile path bytes

isRefIO :: RefError -> Bool
isRefIO (RefIO _) = True
isRefIO _ = False

-- Set a ref with no check, and take the new value.
set :: Refs -> Name -> Id -> IO Ref
set r n i = right =<< setRef r n Unchecked i

-- Test data ------------------------------------------------------------

a, b, c :: Id
a = nid 1
b = nid 2
c = nid 3

-- The characters that a part of a name can have.
nameChars :: [Char]
nameChars = ['a' .. 'z'] ++ ['0' .. '9'] ++ "-_."

genSegment :: Gen Text
genSegment = do
  n <- choose (1, 12)
  first <- elements (filter (/= '.') nameChars)
  rest <- vectorOf (n - 1) (elements nameChars)
  pure (T.pack (first : rest))

-- A text that 'mkName' accepts.
genNameText :: Gen Text
genNameText = T.intercalate "/" <$> (choose (1, 3) >>= (`vectorOf` genSegment))

genId :: Gen Id
genId = hashBytes . BS.pack <$> arbitrary

genRef :: Gen Ref
genRef = Ref <$> genId <*> (take 6 <$> listOf genId)

-- Names ----------------------------------------------------------------

nameTests :: TestTree
nameTests =
  testGroup
    "mkName"
    [ testCase "accepts a name of one part" $
        fmap nameText (mkName "notes") @?= Right "notes"
    , testCase "accepts a name of several parts" $
        fmap nameText (mkName "claude/notes") @?= Right "claude/notes"
    , testCase "accepts digits, dash, underscore and dot" $
        fmap nameText (mkName "v1.2-x_y") @?= Right "v1.2-x_y"
    , testCase "rejects the empty text" $
        mkName "" @?= Left EmptyName
    , testCase "rejects an empty part in the middle" $
        mkName "a//b" @?= Left (BadSegment "")
    , testCase "rejects a leading slash" $
        mkName "/a" @?= Left (BadSegment "")
    , testCase "rejects a trailing slash" $
        mkName "a/" @?= Left (BadSegment "")
    , testCase "rejects . and .." $ do
        mkName "." @?= Left (BadSegment ".")
        mkName "a/.." @?= Left (BadSegment "..")
        mkName "../a" @?= Left (BadSegment "..")
    , testCase "rejects a part that starts with a dot" $ do
        mkName ".lock" @?= Left (BadSegment ".lock")
        mkName "a/.hidden" @?= Left (BadSegment ".hidden")
    , testCase "rejects upper case" $
        mkName "Notes" @?= Left (BadSegment "Notes")
    , testCase "rejects a space, a backslash and a NUL" $ do
        mkName "a b" @?= Left (BadSegment "a b")
        mkName "a\\b" @?= Left (BadSegment "a\\b")
        mkName "a\0b" @?= Left (BadSegment "a\0b")
    , testCase "rejects a character that is not ASCII" $
        mkName "caf\233" @?= Left (BadSegment "caf\233")
    , testCase "accepts a part of 64 characters" $
        fmap nameText (mkName (T.replicate 64 "a")) @?= Right (T.replicate 64 "a")
    , testCase "rejects a part of 65 characters" $
        mkName (T.replicate 65 "a") @?= Left (BadSegment (T.replicate 65 "a"))
    , testCase "reports the first bad part" $
        mkName "ok/Bad/Worse" @?= Left (BadSegment "Bad")
    ]

-- The pure functions ---------------------------------------------------

advanceTests :: TestTree
advanceTests =
  testGroup
    "advance"
    [ testCase "makes the old value the newest generation" $
        advance b (Ref a []) @?= Ref b [a]
    , testCase "keeps the older generations in order" $
        advance c (Ref b [a]) @?= Ref c [b, a]
    , testCase "does not change a ref that already has this value" $
        advance a (Ref a [b]) @?= Ref a [b]
    , testCase "adds an Id that is in the history, as a new generation" $
        advance a (Ref b [a]) @?= Ref a [b, a]
    ]

retainedTests :: TestTree
retainedTests =
  testGroup
    "retained"
    [ testCase "0 keeps only the current value" $
        retained 0 (Ref c [b, a]) @?= Set.fromList [c]
    , testCase "1 keeps the current value and the newest older one" $
        retained 1 (Ref c [b, a]) @?= Set.fromList [c, b]
    , testCase "a number that is too big keeps everything" $
        retained 10 (Ref c [b, a]) @?= Set.fromList [c, b, a]
    , testCase "a negative number is the same as 0" $
        retained (-3) (Ref c [b, a]) @?= Set.fromList [c]
    ]

formatTests :: TestTree
formatTests =
  testGroup
    "renderRef and parseRef"
    [ testCase "renderRef writes one line for each Id, current first" $
        renderRef (Ref a [b, c])
          @?= TE.encodeUtf8 (T.unlines [Id.render a, Id.render b, Id.render c])
    , testCase "parseRef reads what renderRef wrote" $
        parseRef (renderRef (Ref a [b, c])) @?= Right (Ref a [b, c])
    , testCase "parseRef reads a ref with no history" $
        parseRef (renderRef (Ref a [])) @?= Right (Ref a [])
    , testCase "parseRef accepts a last line without a newline" $
        parseRef (BS.init (renderRef (Ref a [b]))) @?= Right (Ref a [b])
    , testCase "parseRef rejects an empty file" $
        parseRef BS.empty @?= Left EmptyRef
    , testCase "parseRef rejects a blank line" $
        parseRef "\n" @?= Left (BadRefLine 1 (BadPrefix ""))
    , testCase "parseRef reports the number of the bad line" $
        parseRef (renderRef (Ref a [b]) <> "sha256-zz\n")
          @?= Left (BadRefLine 3 (BadHex "zz"))
    , testCase "parseRef rejects bytes that are not UTF-8" $
        parseRef "\255\254" @?= Left NotUtf8
    , testCase "parseRef keeps a repeated Id" $
        parseRef (renderRef (Ref a [a])) @?= Right (Ref a [a])
    ]

-- Opening and paths ----------------------------------------------------

openTests :: TestTree
openTests =
  testGroup
    "openRefs"
    [ testCase "makes the root and refs directories" $
        withTempDir $ \dir -> do
          _ <- right =<< openRefs (dir </> "s")
          doesDirectoryExist (dir </> "s" </> "refs") >>= assertBool "refs"
    , testCase "refsRoot is the directory that openRefs got" $
        withTempDir $ \dir -> do
          r <- right =<< openRefs (dir </> "s")
          refsRoot r @?= dir </> "s"
    , testCase "can open refs that already exist" $
        withRefs $ \r dir -> do
          _ <- set r (nm "x") a
          r' <- right =<< openRefs (dir </> "s")
          getRef r' (nm "x") >>= (@?= Right (Ref a []))
    , testCase "returns RefIO if the directory cannot be made" $
        withTempDir $ \dir -> do
          writeFile (dir </> "file") "x"
          res <- openRefs (dir </> "file" </> "s")
          case res of
            Left e -> assertBool (show e) (isRefIO e)
            Right _ -> assertFailure "expected Left"
    ]

pathTests :: TestTree
pathTests =
  testGroup
    "refPath"
    [ testCase "is root/refs/name" $
        withRefs $ \r dir ->
          refPath r (nm "notes") @?= dir </> "s" </> "refs" </> "notes"
    , testCase "makes a directory for each part but the last" $
        withRefs $ \r dir ->
          refPath r (nm "claude/notes")
            @?= dir </> "s" </> "refs" </> "claude" </> "notes"
    , testCase "does not look at the disk" $
        withRefs $ \r _ -> do
          doesDirectoryExist (takeDirectory (refPath r (nm "a/b"))) >>= assertBool "exists" . not
    ]

-- getRef ---------------------------------------------------------------

getTests :: TestTree
getTests =
  testGroup
    "getRef"
    [ testCase "returns NoSuchRef for a ref that is not there" $
        withRefs $ \r _ ->
          getRef r (nm "x") >>= (@?= Left (NoSuchRef (nm "x")))
    , testCase "returns NoSuchRef if a part of the name is a ref" $
        withRefs $ \r _ -> do
          _ <- set r (nm "a") a
          getRef r (nm "a/b") >>= (@?= Left (NoSuchRef (nm "a/b")))
    , testCase "returns NoSuchRef if the name is a directory of other refs" $
        withRefs $ \r _ -> do
          _ <- set r (nm "a/b") a
          getRef r (nm "a") >>= (@?= Left (NoSuchRef (nm "a")))
    , testCase "reads a ref file that was written by hand" $
        withRefs $ \r _ -> do
          plant r (nm "x") (renderRef (Ref b [a]))
          getRef r (nm "x") >>= (@?= Right (Ref b [a]))
    , testCase "returns CorruptRef for a file that is not a ref" $
        withRefs $ \r _ -> do
          plant r (nm "x") "this is not a ref\n"
          res <- getRef r (nm "x")
          case res of
            Left (CorruptRef n (BadRefLine 1 _)) -> n @?= nm "x"
            other -> assertFailure ("unexpected: " ++ show other)
    , testCase "returns CorruptRef EmptyRef for an empty file" $
        withRefs $ \r _ -> do
          plant r (nm "x") BS.empty
          getRef r (nm "x") >>= (@?= Left (CorruptRef (nm "x") EmptyRef))
    ]

-- setRef ---------------------------------------------------------------

setTests :: TestTree
setTests =
  testGroup
    "setRef"
    [ testCase "makes a new ref, and returns its value" $
        withRefs $ \r _ -> do
          setRef r (nm "x") Unchecked a >>= (@?= Right (Ref a []))
          getRef r (nm "x") >>= (@?= Right (Ref a []))
    , testCase "moves a ref, and keeps the old value in the history" $
        withRefs $ \r _ -> do
          _ <- set r (nm "x") a
          setRef r (nm "x") Unchecked b >>= (@?= Right (Ref b [a]))
          getRef r (nm "x") >>= (@?= Right (Ref b [a]))
    , testCase "does not add a generation for the same Id" $
        withRefs $ \r _ -> do
          _ <- set r (nm "x") a
          _ <- set r (nm "x") a
          getRef r (nm "x") >>= (@?= Right (Ref a []))
    , testCase "keeps refs with different names apart" $
        withRefs $ \r _ -> do
          _ <- set r (nm "x") a
          _ <- set r (nm "y") b
          getRef r (nm "x") >>= (@?= Right (Ref a []))
          getRef r (nm "y") >>= (@?= Right (Ref b []))
    , testCase "makes the directories for a name of several parts" $
        withRefs $ \r _ -> do
          _ <- set r (nm "agent/topic") a
          getRef r (nm "agent/topic") >>= (@?= Right (Ref a []))
    , testCase "leaves only the ref file and the lock file in the refs directory" $
        withRefs $ \r _ -> do
          _ <- set r (nm "x") a
          _ <- set r (nm "x") b
          sort <$> listDirectory (refsRoot r </> "refs") >>= (@?= [".lock", "x"])
    , testGroup
        "NameConflict"
        [ testCase "a name that is the start of an existing ref" $
            withRefs $ \r _ -> do
              _ <- set r (nm "a") a
              setRef r (nm "a/b") Unchecked b
                >>= (@?= Left (NameConflict (nm "a/b")))
        , testCase "a name that is a directory of existing refs" $
            withRefs $ \r _ -> do
              _ <- set r (nm "a/b") a
              setRef r (nm "a") Unchecked b
                >>= (@?= Left (NameConflict (nm "a")))
        , testCase "does not change the ref that is in the way" $
            withRefs $ \r _ -> do
              _ <- set r (nm "a") a
              _ <- setRef r (nm "a/b") Unchecked b
              getRef r (nm "a") >>= (@?= Right (Ref a []))
        ]
    , testGroup
        "Expected"
        [ testCase "MustBeAbsent makes a new ref" $
            withRefs $ \r _ ->
              setRef r (nm "x") MustBeAbsent a >>= (@?= Right (Ref a []))
        , testCase "MustBeAbsent returns Stale for a ref that exists" $
            withRefs $ \r _ -> do
              _ <- set r (nm "x") a
              setRef r (nm "x") MustBeAbsent b
                >>= (@?= Left (Stale (nm "x") (Just a)))
        , testCase "MustBe moves the ref if the value is right" $
            withRefs $ \r _ -> do
              _ <- set r (nm "x") a
              setRef r (nm "x") (MustBe a) b >>= (@?= Right (Ref b [a]))
        , testCase "MustBe returns Stale, with the real value, if it is wrong" $
            withRefs $ \r _ -> do
              _ <- set r (nm "x") a
              setRef r (nm "x") (MustBe c) b
                >>= (@?= Left (Stale (nm "x") (Just a)))
        , testCase "MustBe returns Stale Nothing for a ref that is not there" $
            withRefs $ \r _ ->
              setRef r (nm "x") (MustBe a) b
                >>= (@?= Left (Stale (nm "x") Nothing))
        , testCase "a Stale result does not change the ref" $
            withRefs $ \r _ -> do
              _ <- set r (nm "x") a
              _ <- setRef r (nm "x") (MustBe c) b
              getRef r (nm "x") >>= (@?= Right (Ref a []))
        , testCase "a Stale result does not make a ref" $
            withRefs $ \r _ -> do
              _ <- setRef r (nm "x") (MustBe a) b
              getRef r (nm "x") >>= (@?= Left (NoSuchRef (nm "x")))
        ]
    , testCase "returns CorruptRef if the ref file is damaged" $
        withRefs $ \r _ -> do
          plant r (nm "x") "this is not a ref\n"
          res <- setRef r (nm "x") (MustBe a) b
          case res of
            Left (CorruptRef n _) -> n @?= nm "x"
            other -> assertFailure ("unexpected: " ++ show other)
    ]

-- The lock -------------------------------------------------------------

lockTests :: TestTree
lockTests =
  testGroup
    "lock"
    [ testCase "setRef releases the lock, so the next call works" $
        withRefs $ \r _ -> do
          _ <- set r (nm "x") a
          _ <- set r (nm "x") b
          getRef r (nm "x") >>= (@?= Right (Ref b [a]))
    , testCase "a Stale result also releases the lock" $
        withRefs $ \r _ -> do
          _ <- set r (nm "x") a
          _ <- setRef r (nm "x") (MustBe c) b
          setRef r (nm "x") (MustBe a) b >>= (@?= Right (Ref b [a]))
    , testCase "a NameConflict result also releases the lock" $
        withRefs $ \r _ -> do
          _ <- set r (nm "a") a
          _ <- setRef r (nm "a/b") Unchecked b
          setRef r (nm "z") Unchecked c >>= (@?= Right (Ref c []))
    , -- These tests know that the lock is a file lock on refs/.lock.
      -- Change them if the lock changes. This one takes about a second.
      testCase "returns Locked, and writes nothing, while another holder has the lock" $
        withRefs $ \r _ -> do
          withFileLock (lockPath r) Exclusive $ \_ ->
            setRef r (nm "x") Unchecked a >>= (@?= Left Locked)
          getRef r (nm "x") >>= (@?= Left (NoSuchRef (nm "x")))
    , testCase "works again as soon as the other holder releases the lock" $
        withRefs $ \r _ -> do
          withFileLock (lockPath r) Exclusive $ \_ -> pure ()
          setRef r (nm "x") Unchecked a >>= (@?= Right (Ref a []))
    , testCase "a lock file that nobody holds does not block (as after a crash)" $
        withRefs $ \r _ -> do
          BS.writeFile (lockPath r) BS.empty
          setRef r (nm "x") Unchecked a >>= (@?= Right (Ref a []))
    , testCase "nobody holds the lock after setRef" $
        withRefs $ \r _ -> do
          _ <- set r (nm "x") a
          held <- tryLockFile (lockPath r) Exclusive
          assertBool "the lock is still held" (isJust held)
          mapM_ unlockFile held
    , testCase "of many agents with MustBe, exactly one wins" $
        withRefs $ \r _ -> do
          _ <- set r (nm "x") a
          results <- concurrently [setRef r (nm "x") (MustBe a) (nid n) | n <- [10 .. 17]]
          let wins = [v | Right v <- results]
              losses = [e | Left e <- results]
          length wins @?= 1
          assertBool (show losses) (all isStale losses)
          now <- right =<< getRef r (nm "x")
          history now @?= [a]
          wins @?= [now]
    , testCase "of many agents with Unchecked, no update is lost" $
        withRefs $ \r _ -> do
          results <- concurrently [setRef r (nm "x") Unchecked (nid n) | n <- [10 .. 29]]
          mapM_ right results
          now <- right =<< getRef r (nm "x")
          length (history now) + 1 @?= 20
    ]
  where
    isStale (Stale _ _) = True
    isStale _ = False

-- Run the actions at the same time, and collect the results in order.
concurrently :: [IO x] -> IO [x]
concurrently acts = do
  vars <- forM acts $ \act -> do
    v <- newEmptyMVar
    _ <- forkIO (act >>= putMVar v)
    pure v
  mapM takeMVar vars

-- listRefs -------------------------------------------------------------

listTests :: TestTree
listTests =
  testGroup
    "listRefs"
    [ testCase "returns no names for new refs" $
        withRefs $ \r _ ->
          listRefs r >>= (@?= Right [])
    , testCase "returns the names of all refs, also those with several parts" $
        withRefs $ \r _ -> do
          forM_ ["x", "y", "agent/topic", "agent/other/deep"] $ \n -> set r (nm n) a
          ns <- right =<< listRefs r
          sort ns @?= sort (map nm ["x", "y", "agent/topic", "agent/other/deep"])
    , testCase "skips the lock, hidden files and names that are not valid" $
        withRefs $ \r _ -> do
          _ <- set r (nm "x") a
          BS.writeFile (lockPath r) BS.empty
          BS.writeFile (refsRoot r </> "refs" </> ".tmp123") "x"
          BS.writeFile (refsRoot r </> "refs" </> "Bad Name") "x"
          listRefs r >>= (@?= Right [nm "x"])
    ]

-- Properties -----------------------------------------------------------

properties :: TestTree
properties =
  testGroup
    "properties"
    [ testProperty "mkName accepts every text that follows the rules" $
        forAll genNameText $ \t -> fmap nameText (mkName t) === Right t
    , testProperty "mkName never gives a name that can leave the refs directory" $
        forAll (T.pack <$> listOf (elements "ab./-_ A\\\0\233")) $ \t ->
          case mkName t of
            Left _ -> True
            Right n -> all safe (T.splitOn "/" (nameText n))
    , testProperty "the current value of advance i r is i" $
        forAll ((,) <$> genId <*> genRef) $ \(i, r) -> current (advance i r) === i
    , testProperty "advance is idempotent" $
        forAll ((,) <$> genId <*> genRef) $ \(i, r) ->
          advance i (advance i r) === advance i r
    , testProperty "advance puts the old value first in the history" $
        forAll ((,) <$> genId <*> genRef) $ \(i, r) ->
          i /= current r ==> history (advance i r) === current r : history r
    , testProperty "retained n has the current value and at most n older ones" $
        forAll genRef $ \r -> forAll (choose (0, 8)) $ \n ->
          let s = retained n r
           in conjoin
                [ Set.member (current r) s === True
                , (Set.size s <= n + 1) === True
                ]
    , testProperty "retained grows with n" $
        forAll genRef $ \r -> forAll (choose (0, 8)) $ \n ->
          retained n r `Set.isSubsetOf` retained (n + 1) r
    , testProperty "parseRef (renderRef r) == Right r" $
        forAll genRef $ \r -> parseRef (renderRef r) === Right r
    , testProperty "setRef agrees with a model of advance" $
        withMaxSuccess 30 $
          forAll (listOf ((,) <$> elements pool <*> genId)) $ \steps ->
            ioProperty $ withRefs $ \r _ -> do
              forM_ steps $ \(t, i) -> set r (nm t) i
              let model = foldl (\m (t, i) -> Map.alter (Just . maybe (Ref i []) (advance i)) t m) Map.empty steps
              actual <- forM pool $ \t -> (,) t . either (const Nothing) Just <$> getRef r (nm t)
              pure (actual === [(t, Map.lookup t model) | t <- pool])
    ]
  where
    pool = ["a", "b", "c/d"]
    safe p = p `notElem` ["", ".", ".."] && T.head p /= '.' && T.all (`elem` nameChars) p
