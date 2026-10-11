{-# LANGUAGE OverloadedStrings #-}

module CacheTests (cacheTests) where

import Akyuu.Cache (Cache, CacheError (CacheSQL, CacheStore), Hit (hitId, hitSnippet), Summary (Summary, sumFirstLine, sumId), SyncReport (SyncReport, added, removed), cachePath, cachedIds, closeCache, firstLine, forget, ftsQuery, index, indexedBody, loadGraph, openCache, reindex, search, snippetClose, snippetOpen, summaries, sync)
import Akyuu.Graph (Edge (Edge), EdgeType (About, DerivedFrom, Refines, Supersedes), Graph, dangling, nodes)
import Akyuu.Id (Id)
import Akyuu.Memory (Memory (memAgent, memBody, memCreated, memEdges, memKind), memoryGraph, memoryId)
import Akyuu.Store (Store, StoreError (BadMemory), add, objectPath, openStore, trash)
import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, readMVar, takeMVar)
import Control.Exception (bracket)
import Control.Monad (forM, forM_)
import Data.ByteString qualified as BS
import Data.Either (isLeft, isRight)
import Data.List (isInfixOf, nub, sort, sortOn)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import Database.SQLite.Simple (Error (ErrorBusy), Only (fromOnly), SQLError (sqlError), execute_, query_, withConnection)
import MemoryTests (genMemory, shrinkMemory)
import Support (nid, right, testMemory, withTempDir)
import System.Directory (createDirectoryIfMissing, createFileLink, doesFileExist, removeFile)
import System.FilePath (takeDirectory, (</>))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))
import Test.Tasty.QuickCheck (Arbitrary (arbitrary), Gen, conjoin, elements, forAll, forAllShrink, ioProperty, listOf, shrinkList, testProperty, withMaxSuccess, (.&&.), (===))

cacheTests :: TestTree
cacheTests =
  testGroup
    "Akyuu.Cache"
    [ ftsQueryTests,
      openTests,
      indexTests,
      forgetTests,
      loadGraphTests,
      syncTests,
      reindexTests,
      summaryTests,
      searchTests,
      properties,
      sqliteTests
    ]

-- Test helpers ---------------------------------------------------------

-- A fresh store and a fresh cache in one directory. The test gets the store,
-- the cache and the root directory. The cache is closed when the test ends.
withEnv :: (Store -> Cache -> FilePath -> IO a) -> IO a
withEnv act = withTempDir $ \dir -> do
  s <- right =<< openStore dir
  bracket (right =<< openCache dir) closeCache $ \c -> act s c dir

-- A memory with this body and these edges. Everything else is fixed.
memWith :: Text -> [Edge] -> Memory
memWith body es =
  testMemory "fact" (posixSecondsToUTCTime 1791201600) "claude" (Set.fromList es) body

mem :: Text -> Memory
mem body = memWith body []

-- Add memories to the store, and return their 'Id' values.
addAll :: Store -> [Memory] -> IO [Id]
addAll s = mapM (\m -> right =<< add s m)

-- Add a memory to the store and the cache.
addIndexed :: Store -> Cache -> Memory -> IO Id
addIndexed s c m = do
  i <- right =<< add s m
  right =<< index c i m
  pure i

-- Put bytes in the file of an 'Id', without the store's own functions.
plant :: Store -> Id -> BS.ByteString -> IO ()
plant s i bytes = do
  let path = objectPath s i
  createDirectoryIfMissing True (takeDirectory path)
  BS.writeFile path bytes

-- The graph that the memories must give, built without the cache.
expectedGraph :: [Memory] -> Graph
expectedGraph = foldMap memoryGraph

hitIds :: [Hit] -> [Id]
hitIds = map hitId

-- ftsQuery -------------------------------------------------------------

nulToSpace :: Char -> Char
nulToSpace '\0' = ' '
nulToSpace c = c

ftsQueryTests :: TestTree
ftsQueryTests =
  testGroup
    "ftsQuery"
    [ testCase "puts each word in quotes" $
        ftsQuery "foo bar" @?= "\"foo\" \"bar\"",
      testCase "doubles a quote inside a word" $
        ftsQuery "say \"hi\"" @?= "\"say\" \"\"\"hi\"\"\"",
      testCase "keeps a hyphen, which FTS5 would read as an operator" $
        ftsQuery "foo-bar" @?= "\"foo-bar\"",
      testCase "quotes the FTS5 words AND, OR and NOT" $
        ftsQuery "AND OR NOT" @?= "\"AND\" \"OR\" \"NOT\"",
      testCase "gives the empty text for no words" $ do
        ftsQuery "" @?= ""
        ftsQuery "   \t\n " @?= "",
      testCase "ignores extra white space between words" $
        ftsQuery "  a \t b\n" @?= "\"a\" \"b\"",
      testCase "treats a NUL character as white space" $ do
        ftsQuery "a\0b" @?= "\"a\" \"b\""
        ftsQuery "\0" @?= "",
      testProperty "has as many words as the input has, and no NUL" $
        forAll (T.pack <$> arbitrary) $ \t ->
          let q = ftsQuery t
           in conjoin
                [ length (T.words q) === length (T.words (T.map nulToSpace t)),
                  T.any (== '\0') q === False
                ]
    ]

-- openCache ------------------------------------------------------------

openTests :: TestTree
openTests =
  testGroup
    "openCache"
    [ testCase "cachePath is cache.sqlite in the root" $
        cachePath "/some/root" @?= "/some/root" </> "cache.sqlite",
      testCase "makes the cache file" $
        withTempDir $ \dir -> do
          c <- right =<< openCache dir
          closeCache c
          doesFileExist (cachePath dir) >>= assertBool "no cache file",
      testCase "a new cache is empty" $
        withEnv $ \_ c _ -> do
          cachedIds c >>= (@?= Right Set.empty)
          loadGraph c >>= (@?= Right mempty),
      testCase "keeps its rows when it is opened again" $
        withTempDir $ \dir -> do
          s <- right =<< openStore dir
          let m = mem "kept"
          i <- right =<< add s m
          c <- right =<< openCache dir
          right =<< index c i m
          closeCache c
          c' <- right =<< openCache dir
          cachedIds c' >>= (@?= Right (Set.singleton i))
          closeCache c',
      testCase "starts again if the user version is not the schema version" $
        withTempDir $ \dir -> do
          s <- right =<< openStore dir
          let m = mem "old"
          i <- right =<< add s m
          c <- right =<< openCache dir
          right =<< index c i m
          closeCache c
          withConnection (cachePath dir) $ \conn ->
            execute_ conn "PRAGMA user_version = 9999"
          c' <- right =<< openCache dir
          cachedIds c' >>= (@?= Right Set.empty)
          -- The new cache works.
          right =<< index c' i m
          cachedIds c' >>= (@?= Right (Set.singleton i))
          closeCache c',
      testCase "starts again if the file is not a database" $
        withTempDir $ \dir -> do
          BS.writeFile (cachePath dir) "this is not a database, it is only text"
          c <- right =<< openCache dir
          cachedIds c >>= (@?= Right Set.empty)
          right =<< index c (nid 1) (mem "works")
          cachedIds c >>= (@?= Right (Set.singleton (nid 1)))
          closeCache c,
      testCase "keeps a busy file, and returns CacheSQL with ErrorBusy" $
        -- This test waits for the busy timeout of 5 seconds.
        withTempDir $ \dir -> do
          c <- right =<< openCache dir
          right =<< index c (nid 1) (mem "kept")
          closeCache c
          -- In WAL mode a reader does not wait for a writer. So the other
          -- connection goes back to a rollback journal, then takes the lock.
          r <- withConnection (cachePath dir) $ \other -> do
            execute_ other "PRAGMA journal_mode = DELETE"
            execute_ other "BEGIN EXCLUSIVE"
            r <- openCache dir
            execute_ other "ROLLBACK"
            pure r
          case r of
            Left (CacheSQL e) -> sqlError e @?= ErrorBusy
            Left e -> assertFailure ("unexpected: " ++ show e)
            Right c' -> closeCache c' >> assertFailure "expected Left"
          c' <- right =<< openCache dir
          cachedIds c' >>= (@?= Right (Set.singleton (nid 1)))
          closeCache c',
      testCase "waits for a lock that another connection then releases" $
        -- Needs the threaded runtime: SQLite sleeps in a safe foreign call,
        -- and the other thread must run during that sleep.
        withTempDir $ \dir -> do
          c <- right =<< openCache dir
          right =<< index c (nid 1) (mem "kept")
          closeCache c
          held <- newEmptyMVar
          released <- newEmptyMVar
          _ <- forkIO $ do
            withConnection (cachePath dir) $ \other -> do
              execute_ other "PRAGMA journal_mode = DELETE"
              execute_ other "BEGIN EXCLUSIVE"
              putMVar held ()
              threadDelay 1000000
              execute_ other "ROLLBACK"
            putMVar released ()
          takeMVar held
          c' <- right =<< openCache dir
          takeMVar released
          cachedIds c' >>= (@?= Right (Set.singleton (nid 1)))
          closeCache c',
      testCase "keeps every row if several callers open a bad file at once" $
        -- The threads start together and the test repeats, because the race
        -- window is small.
        forM_ [1 .. 25 :: Int] $ \_ -> withTempDir $ \dir -> do
          BS.writeFile (cachePath dir) "this is not a database"
          let n = 8
          gate <- newEmptyMVar
          dones <- forM [1 .. n] $ \k -> do
            done <- newEmptyMVar
            _ <- forkIO $ do
              readMVar gate
              c <- right =<< openCache dir
              right =<< index c (nid k) (mem (T.pack (show k)))
              closeCache c
              putMVar done ()
            pure done
          putMVar gate ()
          mapM_ takeMVar dones
          c <- right =<< openCache dir
          cachedIds c >>= (@?= Right (Set.fromList (map nid [1 .. n])))
          closeCache c,
      testCase "returns a Left if the directory does not exist" $
        withTempDir $ \dir -> do
          r <- openCache (dir </> "missing" </> "deeper")
          assertBool "expected Left" (either (const True) (const False) r)
    ]

-- index ----------------------------------------------------------------

indexTests :: TestTree
indexTests =
  testGroup
    "index"
    [ testCase "adds the memory to cachedIds" $
        withEnv $ \s c _ -> do
          i <- addIndexed s c (mem "hello")
          cachedIds c >>= (@?= Right (Set.singleton i)),
      testCase "adds the edges of the memory to the graph" $
        withEnv $ \s c _ -> do
          let m = memWith "b" [Edge Supersedes (nid 7), Edge About (nid 8)]
          _ <- addIndexed s c m
          loadGraph c >>= (@?= Right (memoryGraph m)),
      testCase "does nothing for an Id that is already in the cache" $
        withEnv $ \s c _ -> do
          let m = memWith "twice" [Edge About (nid 1)]
          i <- addIndexed s c m
          right =<< index c i m
          cachedIds c >>= (@?= Right (Set.singleton i))
          loadGraph c >>= (@?= Right (memoryGraph m))
          fmap hitIds <$> search c "twice" 10 >>= (@?= Right [i]),
      testCase "can index a memory whose body has no word" $
        withEnv $ \s c _ -> do
          i <- addIndexed s c (mem "")
          cachedIds c >>= (@?= Right (Set.singleton i)),
      testCase "can index a body with unusual characters" $
        withEnv $ \s c _ -> do
          i <- addIndexed s c (mem "caf\233 \9731 \"quoted\" it's 100% -x- a\0b")
          cachedIds c >>= (@?= Right (Set.singleton i))
    ]

-- forget ---------------------------------------------------------------

forgetTests :: TestTree
forgetTests =
  testGroup
    "forget"
    [ testCase "removes the memory from cachedIds" $
        withEnv $ \s c _ -> do
          i <- addIndexed s c (mem "gone")
          right =<< forget c i
          cachedIds c >>= (@?= Right Set.empty),
      testCase "removes the edges that start at the memory" $
        withEnv $ \s c _ -> do
          i <- addIndexed s c (memWith "has edges" [Edge About (nid 3)])
          right =<< forget c i
          loadGraph c >>= (@?= Right mempty),
      testCase "removes the body from the search index" $
        withEnv $ \s c _ -> do
          i <- addIndexed s c (mem "findable")
          right =<< forget c i
          search c "findable" 10 >>= (@?= Right []),
      testCase "keeps the edges of other memories that point to it" $
        withEnv $ \s c _ -> do
          old <- addIndexed s c (mem "old")
          new <- addIndexed s c (memWith "new" [Edge Supersedes old])
          right =<< forget c old
          g <- right =<< loadGraph c
          nodes g @?= Set.singleton new
          dangling g @?= Set.singleton old,
      testCase "does nothing for an Id that is not in the cache" $
        withEnv $ \_ c _ -> do
          forget c (nid 99) >>= (@?= Right ()),
      testCase "does not touch the other memories" $
        withEnv $ \s c _ -> do
          a <- addIndexed s c (mem "alpha")
          b <- addIndexed s c (mem "beta")
          right =<< forget c a
          cachedIds c >>= (@?= Right (Set.singleton b))
          fmap hitIds <$> search c "beta" 10 >>= (@?= Right [b])
    ]

-- loadGraph ------------------------------------------------------------

loadGraphTests :: TestTree
loadGraphTests =
  testGroup
    "loadGraph"
    [ testCase "is mempty for an empty cache" $
        withEnv $
          \_ c _ -> loadGraph c >>= (@?= Right mempty),
      testCase "keeps a memory that has no edges as a node" $
        withEnv $ \s c _ -> do
          i <- addIndexed s c (mem "alone")
          g <- right =<< loadGraph c
          nodes g @?= Set.singleton i,
      testCase "keeps a target that is not in the store as dangling" $
        withEnv $ \s c _ -> do
          _ <- addIndexed s c (memWith "points away" [Edge About (nid 42)])
          g <- right =<< loadGraph c
          dangling g @?= Set.singleton (nid 42),
      testCase "equals the graph of the memories, for a small chain" $
        withEnv $ \s c _ -> do
          a <- right =<< add s (mem "a")
          let mb = memWith "b" [Edge Supersedes a]
          b <- right =<< add s mb
          let mc = memWith "c" [Edge Refines b, Edge DerivedFrom a]
          forM_ [(a, mem "a"), (b, mb)] $ \(i, m) -> right =<< index c i m
          right =<< index c (memoryId mc) mc
          loadGraph c >>= (@?= Right (expectedGraph [mem "a", mb, mc]))
    ]

-- sync -----------------------------------------------------------------

syncTests :: TestTree
syncTests =
  testGroup
    "sync"
    [ testCase "does nothing for an empty store" $
        withEnv $ \s c _ -> do
          r <- right =<< sync c s
          r @?= SyncReport [] [],
      testCase "adds every object of the store, and reports them" $
        withEnv $ \s c _ -> do
          ids <- addAll s [mem "one", mem "two", mem "three"]
          r <- right =<< sync c s
          sort (added r) @?= sort ids
          removed r @?= []
          cachedIds c >>= (@?= Right (Set.fromList ids)),
      testCase "reports nothing the second time" $
        withEnv $ \s c _ -> do
          _ <- addAll s [mem "one", mem "two"]
          _ <- right =<< sync c s
          r <- right =<< sync c s
          r @?= SyncReport [] [],
      testCase "adds only the new objects" $
        withEnv $ \s c _ -> do
          _ <- addAll s [mem "old"]
          _ <- right =<< sync c s
          new <- addAll s [mem "new"]
          r <- right =<< sync c s
          added r @?= new,
      testCase "removes the memories that the store does not have" $
        withEnv $ \s c _ -> do
          ids@(a : _) <- addAll s [mem "keep", mem "sweep me"]
          _ <- right =<< sync c s
          let gone = last ids
          right =<< trash s gone
          r <- right =<< sync c s
          removed r @?= [gone]
          added r @?= []
          cachedIds c >>= (@?= Right (Set.singleton a)),
      testCase "removes the body of a removed memory from the search index" $
        withEnv $ \s c _ -> do
          [i] <- addAll s [mem "ephemeral"]
          _ <- right =<< sync c s
          right =<< trash s i
          _ <- right =<< sync c s
          search c "ephemeral" 10 >>= (@?= Right []),
      testCase "gives the same graph as the memories" $
        withEnv $ \s c _ -> do
          let ms =
                [ mem "root",
                  memWith "child" [Edge About (nid 1)],
                  memWith "other" [Edge Refines (nid 2), Edge DerivedFrom (nid 3)]
                ]
          _ <- addAll s ms
          _ <- right =<< sync c s
          loadGraph c >>= (@?= Right (expectedGraph ms)),
      testCase "fails with CacheStore for an object that is not a memory" $
        withEnv $ \s c _ -> do
          plant s (nid 5) "this is not a memory"
          r <- sync c s
          case r of
            Left (CacheStore (BadMemory i _)) -> i @?= nid 5
            other -> assertFailure ("unexpected: " ++ show other),
      testCase "changes nothing if it fails" $
        withEnv $ \s c _ -> do
          _ <- addAll s [mem "good one"]
          plant s (nid 5) "this is not a memory"
          r <- sync c s
          assertBool "expected Left" (isLeft r)
          cachedIds c >>= (@?= Right Set.empty),
      testCase "skips an object that GC sweeps after the list" $
        withEnv $ \s c _ -> do
          ids <- addAll s [mem "stays"]
          -- A link to a file that is not there: 'list' sees the name, and
          -- 'get' gives NotFound, as if GC swept the object in between.
          let path = objectPath s (nid 6)
          createDirectoryIfMissing True (takeDirectory path)
          createFileLink (path ++ ".gone") path
          r <- right =<< sync c s
          r @?= SyncReport ids []
          cachedIds c >>= (@?= Right (Set.fromList ids)),
      testCase "works again after the bad object is trashed" $
        withEnv $ \s c _ -> do
          ids <- addAll s [mem "good one"]
          plant s (nid 5) "this is not a memory"
          _ <- sync c s
          right =<< trash s (nid 5)
          r <- right =<< sync c s
          added r @?= ids
    ]

-- reindex --------------------------------------------------------------

reindexTests :: TestTree
reindexTests =
  testGroup
    "reindex"
    [ testCase "reports every object of the store as added" $
        withEnv $ \s c _ -> do
          ids <- addAll s [mem "a", mem "b"]
          _ <- right =<< sync c s
          r <- right =<< reindex c s
          sort (added r) @?= sort ids
          removed r @?= [],
      testCase "removes a row for an object that is not in the store" $
        withEnv $ \s c _ -> do
          _ <- addAll s [mem "real"]
          right =<< index c (nid 77) (mem "ghost")
          _ <- right =<< reindex c s
          ids <- right =<< cachedIds c
          assertBool "the ghost is still there" (nid 77 `Set.notMember` ids),
      testCase "changes nothing if it fails" $
        withEnv $ \s c _ -> do
          _ <- addAll s [mem "good one"]
          _ <- right =<< sync c s
          before <- right =<< cachedIds c
          plant s (nid 5) "this is not a memory"
          r <- reindex c s
          assertBool "expected Left" (isLeft r)
          cachedIds c >>= (@?= Right before),
      testCase "gives the same graph as before" $
        withEnv $ \s c _ -> do
          let ms = [mem "a", memWith "b" [Edge About (nid 1)]]
          _ <- addAll s ms
          _ <- right =<< sync c s
          before <- right =<< loadGraph c
          _ <- right =<< reindex c s
          loadGraph c >>= (@?= Right before),
      testCase "rebuilds a cache whose file was deleted" $
        withTempDir $ \dir -> do
          s <- right =<< openStore dir
          let ms = [mem "a", memWith "b" [Edge About (nid 1)]]
          _ <- addAll s ms
          c <- right =<< openCache dir
          _ <- right =<< sync c s
          closeCache c
          removeFile (cachePath dir)
          c' <- right =<< openCache dir
          _ <- right =<< sync c' s
          loadGraph c' >>= (@?= Right (expectedGraph ms))
          closeCache c'
    ]

-- summaries ------------------------------------------------------------

summaryTests :: TestTree
summaryTests =
  testGroup
    "summaries"
    [ testCase "an empty cache gives no summaries" $
        withEnv $
          \_ c _ -> summaries c >>= (@?= Right []),
      testCase "gives the headers and the first line of each memory, sorted by id" $
        withEnv $ \s c _ -> do
          let m1 = (mem "\n\n  First line  \nsecond line") {memKind = "note", memAgent = "codex"}
              m2 = memWith "" [Edge About (nid 1)]
          is <- mapM (addIndexed s c) [m1, m2]
          got <- right =<< summaries c
          got
            @?= sortOn
              sumId
              [ Summary i (memKind m) (memAgent m) (memCreated m) (firstLine (memBody m))
              | (i, m) <- zip is [m1, m2]
              ]
          sort (map sumFirstLine got) @?= ["", "First line"],
      testCase "firstLine skips blank lines, strips and cuts" $ do
        firstLine "\n\n  First line  \nsecond" @?= "First line"
        firstLine "" @?= ""
        firstLine (T.replicate 200 "x") @?= T.replicate 120 "x",
      testProperty "the summaries match the memories that sync indexed" $
        withMaxSuccess 20 $
          forAll (listOf genMemory) $ \ms -> ioProperty $
            withEnv $ \s c _ -> do
              is <- addAll s ms
              _ <- right =<< sync c s
              got <- right =<< summaries c
              let want =
                    [ Summary i (memKind m) (memAgent m) (memCreated m) (firstLine (indexedBody (memBody m)))
                    | (i, m) <- Map.toAscList (Map.fromList (zip is ms))
                    ]
              pure (got === want)
    ]

-- search ---------------------------------------------------------------

searchTests :: TestTree
searchTests =
  testGroup
    "search"
    [ testCase "finds a memory by a word in its body" $
        withEnv $ \s c _ -> do
          i <- addIndexed s c (mem "Lilly prefers Haskell for the memory store")
          fmap hitIds <$> search c "haskell" 10 >>= (@?= Right [i]),
      testCase "ignores case" $
        withEnv $ \s c _ -> do
          i <- addIndexed s c (mem "Lilly prefers Haskell")
          fmap hitIds <$> search c "HASKELL" 10 >>= (@?= Right [i]),
      testCase "matches word stems" $
        withEnv $ \s c _ -> do
          i <- addIndexed s c (mem "The graph is derived from the store")
          fmap hitIds <$> search c "derive" 10 >>= (@?= Right [i]),
      testCase "needs all the words" $
        withEnv $ \s c _ -> do
          a <- addIndexed s c (mem "tea and biscuits")
          _ <- addIndexed s c (mem "tea only")
          fmap hitIds <$> search c "tea biscuits" 10 >>= (@?= Right [a]),
      testCase "finds a word with non-ASCII characters" $
        withEnv $ \s c _ -> do
          i <- addIndexed s c (mem "a caf\233 in Z\252rich")
          fmap hitIds <$> search c "caf\233" 10 >>= (@?= Right [i]),
      testCase "gives no hits for a word that is not there" $
        withEnv $ \s c _ -> do
          _ <- addIndexed s c (mem "something")
          search c "absent" 10 >>= (@?= Right []),
      testCase "gives no hits for a text without words" $
        withEnv $ \s c _ -> do
          _ <- addIndexed s c (mem "something")
          search c "" 10 >>= (@?= Right [])
          search c "   " 10 >>= (@?= Right []),
      testCase "gives no hits for a limit of 0 or less" $
        withEnv $ \s c _ -> do
          _ <- addIndexed s c (mem "something")
          search c "something" 0 >>= (@?= Right [])
          search c "something" (-1) >>= (@?= Right []),
      testCase "returns at most the limit" $
        withEnv $ \s c _ -> do
          forM_ [1 .. 5 :: Int] $ \n -> addIndexed s c (mem ("tea number " <> T.pack (show n)))
          hits <- right =<< search c "tea" 3
          length hits @?= 3,
      testCase "puts the best match first" $
        withEnv $ \s c _ -> do
          short <- addIndexed s c (mem "store")
          _ <- addIndexed s c (mem "a long text that has the word store in it only once among many other words")
          hits <- right =<< search c "store" 10
          take 1 (hitIds hits) @?= [short],
      testCase "marks the matching word in the snippet" $
        withEnv $ \s c _ -> do
          _ <- addIndexed s c (mem "Lilly prefers Haskell for the memory store")
          [h] <- right =<< search c "haskell" 10
          assertBool (T.unpack (hitSnippet h)) ("\SOHHaskell\STX" `isInfixOf` T.unpack (hitSnippet h)),
      testCase "a bracket in the body is text, and not a mark" $
        withEnv $ \s c _ -> do
          _ <- addIndexed s c (mem "see [x] and [the Haskell] list")
          [h] <- right =<< search c "haskell" 10
          let t = hitSnippet h
          assertBool (T.unpack t) ("[x]" `T.isInfixOf` t && "[the \SOHHaskell\STX]" `T.isInfixOf` t)
          T.count (T.singleton snippetOpen) t @?= 1
          T.count (T.singleton snippetClose) t @?= 1,
      testCase "the marks in the body do not look like marks in the snippet" $
        withEnv $ \s c _ -> do
          _ <- addIndexed s c (mem "a \SOHfake\STX mark and a Haskell word")
          [h] <- right =<< search c "haskell" 10
          let t = hitSnippet h
          T.count (T.singleton snippetOpen) t @?= 1
          T.count (T.singleton snippetClose) t @?= 1
          assertBool (T.unpack t) ("\xFFFD\&fake\xFFFD" `T.isInfixOf` t),
      testCase "does not find a memory that was forgotten" $
        withEnv $ \s c _ -> do
          i <- addIndexed s c (mem "short lived")
          right =<< forget c i
          search c "lived" 10 >>= (@?= Right []),
      testGroup
        "text that FTS5 would reject, as a plain query"
        [ testCase (show q) $
            withEnv $ \s c _ -> do
              _ <- addIndexed s c (mem "foo bar baz")
              r <- search c q 10
              assertBool (show r) (isRight r)
        | q <-
            [ "foo-bar",
              "\"unterminated",
              "AND",
              "foo OR",
              "NEAR(",
              "*",
              "col:foo",
              "^foo",
              "a b c d e f g h",
              "\0"
            ]
        ]
    ]

-- SQLite ---------------------------------------------------------------

sqliteTests :: TestTree
sqliteTests =
  testGroup
    "SQLite"
    [ testCase "is built thread-safe (THREADSAFE=1 or 2)" $
        withConnection ":memory:" $ \conn -> do
          opts <- map fromOnly <$> (query_ conn "PRAGMA compile_options" :: IO [Only Text])
          assertBool (show opts) (any (`elem` opts) ["THREADSAFE=1", "THREADSAFE=2"])
    ]

-- Properties -----------------------------------------------------------

-- Text that is likely to upset FTS5.
genQuery :: Gen Text
genQuery = T.pack <$> listOf (elements "ab\"-*:()^ \tANDORNEA\233\0")

properties :: TestTree
properties =
  testGroup
    "properties"
    [ testProperty "search never fails, for any text" $
        withMaxSuccess 60 $
          forAll genQuery $ \q -> ioProperty $
            withEnv $ \s c _ -> do
              _ <- addIndexed s c (mem "foo bar baz")
              isRight <$> search c q 5,
      testProperty "sync, then loadGraph, gives the graph of the memories" $
        withMaxSuccess 30 $
          forAllShrink (listOf genMemory) (shrinkList shrinkMemory) $ \ms -> ioProperty $
            withEnv $ \s c _ -> do
              _ <- addAll s ms
              _ <- right =<< sync c s
              g <- right =<< loadGraph c
              pure (g === expectedGraph ms),
      testProperty "sync reports each memory once, and a second sync reports none" $
        withMaxSuccess 30 $
          forAllShrink (listOf genMemory) (shrinkList shrinkMemory) $ \ms -> ioProperty $
            withEnv $ \s c _ -> do
              ids <- addAll s ms
              first' <- right =<< sync c s
              second <- right =<< sync c s
              pure $
                conjoin
                  [ sort (added first') === sort (nub ids),
                    second === SyncReport [] []
                  ],
      testProperty "after memories are trashed, sync gives the graph of the rest" $
        withMaxSuccess 30 $
          forAllShrink ((,) <$> listOf genMemory <*> listOf arbitrary) (const []) $ \(ms, flags) -> ioProperty $
            withEnv $ \s c _ -> do
              ids <- addAll s ms
              _ <- right =<< sync c s
              let pairs = nubOn' fst (zip ids ms)
                  marked = zip pairs (flags ++ repeat False)
                  kept = [m | ((_, m), False) <- marked]
                  gone = [i | ((i, _), True) <- marked]
              forM_ gone $ \i -> right =<< trash s i
              r <- right =<< sync c s
              g <- right =<< loadGraph c
              pure $
                conjoin
                  [ sort (removed r) === sort gone,
                    g === expectedGraph kept
                  ],
      testProperty "a cache that is rebuilt from the store is the same" $
        withMaxSuccess 20 $
          forAllShrink (listOf genMemory) (shrinkList shrinkMemory) $ \ms -> ioProperty $
            withTempDir $ \dir -> do
              s <- right =<< openStore dir
              _ <- addAll s ms
              c <- right =<< openCache dir
              _ <- right =<< sync c s
              original <- right =<< loadGraph c
              closeCache c
              removeFile (cachePath dir)
              c' <- right =<< openCache dir
              _ <- right =<< sync c' s
              rebuilt <- right =<< loadGraph c'
              closeCache c'
              pure (rebuilt === original),
      testProperty "every memory can be indexed, and found by cachedIds" $
        withMaxSuccess 50 $
          forAllShrink genMemory shrinkMemory $ \m -> ioProperty $
            withEnv $ \_ c _ -> do
              let i = memoryId m
              r <- index c i m
              ids <- cachedIds c
              pure (isRight r .&&. ids === Right (Set.singleton i))
    ]
  where
    -- The first pair for each 'Id': the store holds one object for equal content.
    nubOn' f = foldr (\x acc -> x : filter ((/= f x) . f) acc) []
