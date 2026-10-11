{-# LANGUAGE OverloadedStrings #-}

module StoreTests (storeTests) where

import Akyuu.Id (Id, hashBytes)
import Akyuu.Id qualified as Id
import Akyuu.Memory (Memory (Memory, memAgent, memBody, memCreated, memEdges, memKind), memoryId, renderMemory)
import Akyuu.Store (Store, StoreError (BadMemory, Corrupt, NotFound, StoreIO), add, exists, get, getVerified, list, objectPath, openStore, storeRoot, trash, verify)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.List (sort)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import MemoryTests (genMemory, shrinkMemory)
import Support (nid, right, withTempDir)
import System.Directory
  ( createDirectoryIfMissing,
    doesDirectoryExist,
    doesFileExist,
    getModificationTime,
    listDirectory,
    setModificationTime,
  )
import System.FilePath (takeDirectory, takeFileName, (</>))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))
import Test.Tasty.QuickCheck (forAllShrink, ioProperty, listOf, shrinkList, testProperty, withMaxSuccess, (===))

storeTests :: TestTree
storeTests =
  testGroup
    "Akyuu.Store"
    [ openTests,
      pathTests,
      addTests,
      getTests,
      getVerifiedTests,
      existsTests,
      listTests,
      verifyTests,
      trashTests,
      properties
    ]

-- Test helpers ---------------------------------------------------------

-- A fresh, open store. The test gets the store and the directory above it.
withStore :: (Store -> FilePath -> IO a) -> IO a
withStore act = withTempDir $ \dir -> do
  opened <- openStore (dir </> "s")
  case opened of
    Left e -> assertFailure ("openStore failed: " ++ show e)
    Right s -> act s dir

-- Put bytes in the file of an 'Id', without the store's own functions.
-- The tests use it to make objects that are damaged or in the wrong place.
plant :: Store -> Id -> ByteString -> IO ()
plant s i bytes = do
  let path = objectPath s i
  createDirectoryIfMissing True (takeDirectory path)
  BS.writeFile path bytes

isStoreIO :: StoreError -> Bool
isStoreIO (StoreIO _) = True
isStoreIO _ = False

isBadMemory :: Id -> StoreError -> Bool
isBadMemory i (BadMemory j _) = i == j
isBadMemory _ _ = False

-- Test data ------------------------------------------------------------

-- A small memory. Only the body changes between memories.
mem :: Text -> Memory
mem body =
  Memory
    { memKind = "fact",
      memCreated = posixSecondsToUTCTime 1791201600,
      memAgent = "claude",
      memEdges = Set.empty,
      memBody = body
    }

-- Bytes that are not a memory.
garbage :: ByteString
garbage = "this is not a memory"

-- The name of the file of an object, for example @sha256-9f3a….md@.
fileName :: Id -> FilePath
fileName i = T.unpack (Id.render i) <> ".md"

-- The directory of the shard of an 'Id': its first two hex digits.
shardOf :: Id -> FilePath
shardOf i = take 2 (drop 7 (T.unpack (Id.render i)))

openTests :: TestTree
openTests =
  testGroup
    "openStore"
    [ testCase "makes the root, store and trash directories" $
        withTempDir $ \dir -> do
          _ <- right =<< openStore (dir </> "s")
          mapM_
            (\d -> doesDirectoryExist (dir </> "s" </> d) >>= assertBool d)
            ["", "store", "trash"],
      testCase "storeRoot is the directory that openStore got" $
        withTempDir $ \dir -> do
          s <- right =<< openStore (dir </> "s")
          storeRoot s @?= dir </> "s",
      testCase "can open a store that already exists" $
        withStore $ \s dir -> do
          i <- right =<< add s (mem "kept")
          s' <- right =<< openStore (dir </> "s")
          get s' i >>= (@?= Right (mem "kept")),
      testCase "returns StoreIO if the directory cannot be made" $
        withTempDir $ \dir -> do
          -- A regular file where the root should go.
          BS.writeFile (dir </> "file") "x"
          r <- openStore (dir </> "file" </> "s")
          case r of
            Left e -> assertBool (show e) (isStoreIO e)
            Right _ -> assertFailure "expected Left"
    ]

pathTests :: TestTree
pathTests =
  testGroup
    "objectPath"
    [ testCase "is root/store/<first two hex digits>/<rendered Id>.md" $
        withStore $ \s _ ->
          let i = hashBytes "abc"
           in objectPath s i @?= storeRoot s </> "store" </> shardOf i </> fileName i,
      testCase "is the same for the same Id" $
        withStore $
          \s _ -> objectPath s (nid 1) @?= objectPath s (nid 1),
      testCase "is different for different Ids" $
        withStore $
          \s _ -> assertBool "paths equal" (objectPath s (nid 1) /= objectPath s (nid 2)),
      testCase "does not make a file" $
        withStore $ \s _ -> do
          let _ = objectPath s (nid 1)
          doesFileExist (objectPath s (nid 1)) >>= assertBool "file exists" . not
    ]

addTests :: TestTree
addTests =
  testGroup
    "add"
    [ testCase "returns the Id of the memory" $
        withStore $ \s _ ->
          (right =<< add s (mem "a")) >>= (@?= memoryId (mem "a")),
      testCase "writes the canonical form to the path of the Id" $
        withStore $ \s _ -> do
          i <- right =<< add s (mem "a")
          BS.readFile (objectPath s i) >>= (@?= renderMemory (mem "a")),
      testCase "adding the same memory twice gives the same Id and one file" $
        withStore $ \s _ -> do
          i1 <- right =<< add s (mem "a")
          i2 <- right =<< add s (mem "a")
          i1 @?= i2
          listDirectory (takeDirectory (objectPath s i1)) >>= (@?= [fileName i1]),
      testCase "leaves no temporary file behind" $
        withStore $ \s _ -> do
          i <- right =<< add s (mem "a")
          listDirectory (takeDirectory (objectPath s i)) >>= (@?= [takeFileName (objectPath s i)]),
      testCase "does not write again if the object is there" $
        withStore $ \s _ -> do
          i <- right =<< add s (mem "a")
          -- Change the file. A second add must not put the old bytes back.
          BS.writeFile (objectPath s i) "changed"
          _ <- right =<< add s (mem "a")
          BS.readFile (objectPath s i) >>= (@?= "changed"),
      testCase "sets the file time to now if the object is there" $
        withStore $ \s _ -> do
          i <- right =<< add s (mem "a")
          let past = posixSecondsToUTCTime 1000000000
          setModificationTime (objectPath s i) past
          _ <- right =<< add s (mem "a")
          t <- getModificationTime (objectPath s i)
          assertBool "the file time did not move" (t > past)
          BS.readFile (objectPath s i) >>= (@?= renderMemory (mem "a")),
      testCase "writes the object again if it was moved to the trash" $
        withStore $ \s _ -> do
          i <- right =<< add s (mem "a")
          right =<< trash s i
          _ <- right =<< add s (mem "a")
          BS.readFile (objectPath s i) >>= (@?= renderMemory (mem "a")),
      testCase "two different memories are two files" $
        withStore $ \s _ -> do
          i1 <- right =<< add s (mem "a")
          i2 <- right =<< add s (mem "b")
          assertBool "same Id" (i1 /= i2)
          mapM_ (\i -> doesFileExist (objectPath s i) >>= assertBool "missing") [i1, i2]
    ]

getTests :: TestTree
getTests =
  testGroup
    "get"
    [ testCase "reads back what add wrote" $
        withStore $ \s _ -> do
          i <- right =<< add s (mem "a")
          get s i >>= (@?= Right (mem "a")),
      testCase "returns NotFound for an unknown Id" $
        withStore $ \s _ ->
          get s (nid 1) >>= (@?= Left (NotFound (nid 1))),
      testCase "returns BadMemory for a file that is not a memory" $
        withStore $ \s _ -> do
          plant s (nid 1) garbage
          r <- get s (nid 1)
          case r of
            Left e -> assertBool (show e) (isBadMemory (nid 1) e)
            Right _ -> assertFailure "expected Left",
      testCase "does not hash the file again" $
        withStore $ \s _ -> do
          -- A valid memory under the name of another Id.
          plant s (nid 1) (renderMemory (mem "a"))
          get s (nid 1) >>= (@?= Right (mem "a"))
    ]

getVerifiedTests :: TestTree
getVerifiedTests =
  testGroup
    "getVerified"
    [ testCase "reads back what add wrote" $
        withStore $ \s _ -> do
          i <- right =<< add s (mem "a")
          getVerified s i >>= (@?= Right (mem "a")),
      testCase "returns NotFound for an unknown Id" $
        withStore $ \s _ ->
          getVerified s (nid 1) >>= (@?= Left (NotFound (nid 1))),
      testCase "returns Corrupt for a valid memory under the wrong name" $
        withStore $ \s _ -> do
          plant s (nid 1) (renderMemory (mem "a"))
          getVerified s (nid 1) >>= (@?= Left (Corrupt (nid 1))),
      testCase "returns Corrupt, not BadMemory, for damaged bytes" $
        withStore $ \s _ -> do
          plant s (nid 1) garbage
          getVerified s (nid 1) >>= (@?= Left (Corrupt (nid 1))),
      testCase "returns BadMemory if the bytes match the name but are not a memory" $
        withStore $ \s _ -> do
          let i = hashBytes garbage
          plant s i garbage
          r <- getVerified s i
          case r of
            Left e -> assertBool (show e) (isBadMemory i e)
            Right _ -> assertFailure "expected Left"
    ]

existsTests :: TestTree
existsTests =
  testGroup
    "exists"
    [ testCase "is False for an unknown Id" $
        withStore $
          \s _ -> exists s (nid 1) >>= (@?= Right False),
      testCase "is True after add" $
        withStore $ \s _ -> do
          i <- right =<< add s (mem "a")
          exists s i >>= (@?= Right True),
      testCase "does not read the file" $
        withStore $ \s _ -> do
          plant s (nid 1) garbage
          exists s (nid 1) >>= (@?= Right True)
    ]

listTests :: TestTree
listTests =
  testGroup
    "list"
    [ testCase "is empty for an empty store" $
        withStore $
          \s _ -> list s >>= (@?= Right []),
      testCase "has the Id of each object that was added" $
        withStore $ \s _ -> do
          ids <- mapM (\b -> right =<< add s (mem b)) ["a", "b", "c"]
          is <- right =<< list s
          sort is @?= sort ids,
      testCase "has an Id once if its memory is added twice" $
        withStore $ \s _ -> do
          i <- right =<< add s (mem "a")
          _ <- right =<< add s (mem "a")
          list s >>= (@?= Right [i]),
      testCase "skips a file whose name is not an Id" $
        withStore $ \s _ -> do
          i <- right =<< add s (mem "a")
          let dir = takeDirectory (objectPath s i)
          BS.writeFile (dir </> "junk.tmp") "x"
          BS.writeFile (dir </> ".tmp-1234") "x"
          list s >>= (@?= Right [i]),
      testCase "skips a file in the store directory, such as .DS_Store" $
        withStore $ \s _ -> do
          i <- right =<< add s (mem "a")
          let base = storeRoot s </> "store"
          BS.writeFile (base </> ".DS_Store") "x"
          BS.writeFile (base </> "README") "x"
          BS.writeFile (takeDirectory (objectPath s i) </> ".DS_Store") "x"
          list s >>= (@?= Right [i]),
      testCase "skips a directory whose name is not a shard" $
        withStore $ \s _ -> do
          i <- right =<< add s (mem "a")
          let base = storeRoot s </> "store"
          -- Not two hex digits: too long, upper case, or not hex.
          mapM_
            (\d -> createDirectoryIfMissing True (base </> d) >> BS.writeFile (base </> d </> fileName i) "x")
            ["notes", "AB", "zz", "a"]
          list s >>= (@?= Right [i]),
      testCase "does not list an object that is in the trash" $
        withStore $ \s _ -> do
          i <- right =<< add s (mem "a")
          _ <- right =<< trash s i
          list s >>= (@?= Right [])
    ]

verifyTests :: TestTree
verifyTests =
  testGroup
    "verify"
    [ testCase "finds nothing in an empty store" $
        withStore $
          \s _ -> verify s >>= (@?= Right []),
      testCase "finds nothing in a sound store" $
        withStore $ \s _ -> do
          mapM_ (\b -> right =<< add s (mem b)) ["a", "b"]
          verify s >>= (@?= Right []),
      testCase "finds an object whose content does not match its name" $
        withStore $ \s _ -> do
          _ <- right =<< add s (mem "a")
          plant s (nid 1) (renderMemory (mem "b"))
          verify s >>= (@?= Right [nid 1]),
      testCase "finds only the damaged objects" $
        withStore $ \s _ -> do
          good <- right =<< add s (mem "a")
          plant s (nid 1) garbage
          plant s (nid 2) garbage
          bad <- right =<< verify s
          sort bad @?= sort [nid 1, nid 2]
          assertBool "good object listed" (good `notElem` bad)
    ]

trashTests :: TestTree
trashTests =
  testGroup
    "trash"
    [ testCase "moves the file to the trash directory" $
        withStore $ \s _ -> do
          i <- right =<< add s (mem "a")
          before <- BS.readFile (objectPath s i)
          _ <- right =<< trash s i
          doesFileExist (objectPath s i) >>= assertBool "still in store" . not
          let inTrash = storeRoot s </> "trash" </> fileName i
          doesFileExist inTrash >>= assertBool "not in trash"
          BS.readFile inTrash >>= (@?= before),
      testCase "the object is gone from the store" $
        withStore $ \s _ -> do
          i <- right =<< add s (mem "a")
          _ <- right =<< trash s i
          exists s i >>= (@?= Right False)
          get s i >>= (@?= Left (NotFound i)),
      testCase "returns NotFound for an unknown Id" $
        withStore $ \s _ ->
          trash s (nid 1) >>= (@?= Left (NotFound (nid 1))),
      testCase "leaves the other objects alone" $
        withStore $ \s _ -> do
          i1 <- right =<< add s (mem "a")
          i2 <- right =<< add s (mem "b")
          _ <- right =<< trash s i1
          get s i2 >>= (@?= Right (mem "b"))
    ]

-- Each case makes its own store, so keep the number of cases low.
properties :: TestTree
properties =
  testGroup
    "properties"
    [ testProperty "get gives back every memory that add wrote" $
        withMaxSuccess 30 $
          forAllShrink genMemory shrinkMemory $ \m ->
            ioProperty $ withStore $ \s _ -> do
              i <- right =<< add s m
              r <- get s i
              pure (r === Right m),
      testProperty "getVerified agrees with get on every added memory" $
        withMaxSuccess 30 $
          forAllShrink genMemory shrinkMemory $ \m ->
            ioProperty $ withStore $ \s _ -> do
              i <- right =<< add s m
              r1 <- get s i
              r2 <- getVerified s i
              pure (r1 === r2),
      testProperty "add returns memoryId" $
        withMaxSuccess 30 $
          forAllShrink genMemory shrinkMemory $ \m ->
            ioProperty $ withStore $ \s _ -> do
              i <- right =<< add s m
              pure (i === memoryId m),
      testProperty "list is the set of the Ids that were added" $
        withMaxSuccess 30 $
          forAllShrink (listOf genMemory) (shrinkList shrinkMemory) $ \ms ->
            ioProperty $ withStore $ \s _ -> do
              mapM_ (\m -> right =<< add s m) ms
              is <- right =<< list s
              pure (sort is === Set.toAscList (Set.fromList (map memoryId ms))),
      testProperty "verify finds nothing in a store that only add wrote" $
        withMaxSuccess 30 $
          forAllShrink (listOf genMemory) (shrinkList shrinkMemory) $ \ms ->
            ioProperty $ withStore $ \s _ -> do
              mapM_ (\m -> right =<< add s m) ms
              r <- verify s
              pure (r === Right [])
    ]
