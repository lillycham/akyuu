{-# LANGUAGE OverloadedStrings #-}

module WebTests (webTests, at, atKey, strings, treeOf) where

import Akyuu.Cache (Summary (Summary, sumCreated), cachedIds)
import Akyuu.Cache qualified as Cache
import Akyuu.Error (AkyuuError (AmbiguousPrefix, BadId, BadIdSpec, BadInput, CacheFailed, NoSuchPrefix, Pruned, StoreFailed), describe)
import Akyuu.GC (Tombstone (Tombstone))
import Akyuu.GC qualified as GC
import Akyuu.Graph (Edge (Edge), EdgeType (About, DerivedFrom, Refines, Supersedes), Graph, singleton)
import Akyuu.Id (Id, IdParseError (BadLength), hashBytes, render)
import Akyuu.Ops (Env (envCache, envStore), IdSpec (Full, Prefix), NewMemory (NewMemory), addMemory, setRefTo, supersedeMemory)
import Akyuu.Query (SearchOptions (searchHops, searchLimit), defaultSearchOptions)
import Akyuu.Refs (Expected (MustBeAbsent), mkName)
import Akyuu.Store (StoreError (NotFound))
import Akyuu.Store qualified as Store
import Akyuu.Web.Api (Endpoint (CheckEndpoint, ExplainEndpoint, GraphEndpoint, MemoryEndpoint, PageEndpoint, PlanEndpoint, RefsEndpoint, SearchEndpoint, StatsEndpoint, TrashEndpoint, VerifyEndpoint), RouteError (BadParam), WebRequest (WebRequest, reqQuery), WebResponse (resBody, resHeaders, resStatus), parseEndpoint, route, runEndpoint)
import Akyuu.Web.Model (GraphData (GraphData, gdCached, gdGraph, gdStore, gdSummaries, gdTombstones), GraphEdge (geDst, geSrc), GraphNode (gnId, gnInStore, gnStatus), GraphView (gvEdges, gvNodes, gvSeeds, gvTotalEdges, gvTotalNodes, gvTruncated), NodeStatus (HeadNode, MissingTarget, PrunedTarget, SupersededNode), Window (Window, winAll, winFocus, winHops, winLimit), defaultWindow, graphView, graphViewJSON, selectWindow)
import Akyuu.Web.Page (dataMarker, indexPage, scriptSafeJSON, vizPage)
import Akyuu.Web.Server (application, hostAllowed, toWebRequest)
import Control.Monad (forM, forM_)
import Data.Aeson (Value (Array, Bool, Null, Number, Object, String), object, (.=))
import Data.Aeson qualified as A
import Data.Aeson.Key qualified as K
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BL
import Data.Functor.Identity (Identity, runIdentity)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.List (isPrefixOf, sort)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, isJust)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (UTCTime, addUTCTime)
import Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import Network.HTTP.Types (statusCode)
import Network.Wai qualified as Wai
import Network.Wai.Internal (ResponseReceived (ResponseReceived))
import OpsTests (note, withOpsEnv)
import Support (nid, right, testMemory)
import System.Directory (doesDirectoryExist, listDirectory)
import System.FilePath ((</>))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))
import Test.Tasty.QuickCheck (Gen, choose, conjoin, elements, forAll, listOf, testProperty, (===))

webTests :: TestTree
webTests =
  testGroup
    "Akyuu.Web"
    [ routeCases,
      windowCases,
      pageCases,
      serverCases,
      storeCases
    ]

-- The server -----------------------------------------------------------

-- Run the WAI application of the server on one request, with a fake
-- runner, and give the status and the headers.
waiCall :: Int -> Wai.Request -> IO (Int, [(Text, BS.ByteString)])
waiCall port req = do
  out <- newIORef Nothing
  _ <- application port (pure . runIdentity . fake) req $ \r -> do
    writeIORef out (Just (statusCode (Wai.responseStatus r), [(T.pack (show k), v) | (k, v) <- Wai.responseHeaders r]))
    pure ResponseReceived
  readIORef out >>= maybe (assertFailure "no response") pure

waiReq :: BS.ByteString -> [Text] -> Maybe BS.ByteString -> Wai.Request
waiReq m p h = Wai.defaultRequest {Wai.requestMethod = m, Wai.pathInfo = p, Wai.requestHeaderHost = h}

serverCases :: TestTree
serverCases =
  testGroup
    "server"
    [ testCase "hostAllowed takes 127.0.0.1 and localhost with the port only" $ do
        hostAllowed 7420 (Just "127.0.0.1:7420") @?= True
        hostAllowed 7420 (Just "localhost:7420") @?= True
        hostAllowed 7420 (Just "127.0.0.1:7421") @?= False
        hostAllowed 7420 (Just "evil.example:7420") @?= False
        hostAllowed 7420 (Just "127.0.0.1") @?= False
        hostAllowed 7420 (Just "0.0.0.0:7420") @?= False
        hostAllowed 7420 Nothing @?= False,
      testCase "a request with a wrong Host gets 403" $ do
        (s, _) <- waiCall 7420 (waiReq "GET" ["api", "stats"] (Just "evil.example:7420"))
        s @?= 403
        (s2, _) <- waiCall 7420 (waiReq "GET" ["api", "stats"] Nothing)
        s2 @?= 403,
      testCase "the application routes a good request, and refuses POST" $ do
        (s, hs) <- waiCall 7420 (waiReq "GET" ["api", "stats"] (Just "127.0.0.1:7420"))
        s @?= 200
        lookup "\"Content-Type\"" hs @?= Just "application/json; charset=utf-8"
        (s2, hs2) <- waiCall 7420 (waiReq "POST" ["api", "stats"] (Just "localhost:7420"))
        s2 @?= 405
        lookup "\"Allow\"" hs2 @?= Just "GET",
      testCase "toWebRequest keeps the query that WAI parsed, as text" $
        reqQuery (toWebRequest Wai.defaultRequest {Wai.queryString = [("q", Just "a%20b"), ("all", Nothing)]})
          @?= [("q", Just "a%20b"), ("all", Nothing)]
    ]

-- Helpers --------------------------------------------------------------

-- Follow a path of keys into a value.
at :: [Text] -> Value -> Maybe Value
at [] v = Just v
at (k : ks) (Object o) = KM.lookup (K.fromText k) o >>= at ks
at _ _ = Nothing

-- One key of an object, by an 'Id' or another text.
atKey :: Text -> Value -> Maybe Value
atKey k = at [k]

-- The strings of a JSON array.
strings :: Maybe Value -> [Text]
strings (Just (Array xs)) = [t | String t <- foldr (:) [] xs]
strings _ = []

-- The objects of a JSON array.
items :: Maybe Value -> [Value]
items (Just (Array xs)) = foldr (:) [] xs
items _ = []

-- A runner that answers with the Show form of the endpoint.
fake :: Endpoint -> Identity (Either AkyuuError Value)
fake e = pure (Right (String (T.pack (show e))))

-- A runner that always fails with this error.
failing :: AkyuuError -> Endpoint -> Identity (Either AkyuuError Value)
failing err _ = pure (Left err)

get :: [Text] -> [(Text, Maybe Text)] -> WebRequest
get p q = WebRequest "GET" p q

-- The endpoint of a GET, or the error.
endpointOf :: [Text] -> [(Text, Maybe Text)] -> Either RouteError Endpoint
endpointOf p q = parseEndpoint (get p q)

body :: WebResponse -> Maybe Value
body = A.decode . resBody

header :: BS.ByteString -> WebResponse -> Maybe BS.ByteString
header h r = lookup h (resHeaders r)

-- Routes ---------------------------------------------------------------

routeCases :: TestTree
routeCases =
  testGroup
    "route"
    [ testCase "the root gives the page, as HTML, with the security headers" $ do
        let r = runIdentity (route fake (get [] []))
        resStatus r @?= 200
        header "Content-Type" r @?= Just "text/html; charset=utf-8"
        resBody r @?= BL.fromStrict indexPage
        isJust (header "Content-Security-Policy" r) @?= True
        header "X-Content-Type-Options" r @?= Just "nosniff",
      testCase "a method other than GET gets 405 with Allow: GET" $
        forM_ ["POST", "PUT", "DELETE", "PATCH", "HEAD", "OPTIONS"] $ \m -> do
          let r = runIdentity (route fake (WebRequest m ["api", "stats"] []))
          resStatus r @?= 405
          header "Allow" r @?= Just "GET",
      testCase "a path with no endpoint gets 404" $
        forM_ [["api"], ["api", "nope"], ["etc", "passwd"], ["..", "store"], ["api", "memory"]] $ \p ->
          resStatus (runIdentity (route fake (get p []))) @?= 404,
      testCase "each endpoint is found, also with a trailing slash" $ do
        endpointOf ["api", "stats"] [] @?= Right StatsEndpoint
        endpointOf ["api", "stats", ""] [] @?= Right StatsEndpoint
        endpointOf ["api", "refs"] [] @?= Right RefsEndpoint
        endpointOf ["api", "gc", "plan"] [] @?= Right PlanEndpoint
        endpointOf ["api", "trash"] [] @?= Right TrashEndpoint
        endpointOf ["api", "verify"] [] @?= Right VerifyEndpoint
        endpointOf ["api", "check"] [] @?= Right CheckEndpoint
        endpointOf ["index.html"] [] @?= Right PageEndpoint,
      testCase "the graph has the default window" $
        endpointOf ["api", "graph"] [] @?= Right (GraphEndpoint defaultWindow),
      testCase "the graph reads focus, hops, limit and all" $
        endpointOf ["api", "graph"] [("focus", Just (render (nid 1))), ("hops", Just "3"), ("limit", Just "7"), ("all", Nothing)]
          @?= Right (GraphEndpoint (Window (Just (nid 1)) 3 7 True)),
      testCase "the graph refuses a bad hops, limit or focus" $ do
        endpointOf ["api", "graph"] [("hops", Just "11")] @?= Left (BadParam "The parameter 'hops' must be a whole number from 0 to 10.")
        endpointOf ["api", "graph"] [("hops", Just "-1")] @?= Left (BadParam "The parameter 'hops' must be a whole number from 0 to 10.")
        endpointOf ["api", "graph"] [("limit", Just "0")] @?= Left (BadParam "The parameter 'limit' must be a whole number from 1 to 100000.")
        endpointOf ["api", "graph"] [("focus", Just "sha256-1234")] @?= Left (BadParam (describe (BadId "sha256-1234" (BadLength 2)))),
      testCase "a memory can be a whole id or the start of one" $ do
        endpointOf ["api", "memory", render (nid 1)] [] @?= Right (MemoryEndpoint (Full (nid 1)))
        endpointOf ["api", "memory", "0101"] [] @?= Right (MemoryEndpoint (Prefix "sha256-0101"))
        endpointOf ["api", "memory", "zz"] [] @?= Left (BadParam (describe (BadIdSpec "zz"))),
      testCase "explain needs a whole id" $ do
        endpointOf ["api", "gc", "explain", render (nid 2)] [] @?= Right (ExplainEndpoint (nid 2))
        resStatus (runIdentity (route fake (get ["api", "gc", "explain", "0101"] []))) @?= 400,
      testCase "search needs q, and reads limit and hops" $ do
        endpointOf ["api", "search"] [] @?= Left (BadParam "The parameter 'q' is missing.")
        endpointOf ["api", "search"] [("q", Just "  ")] @?= Left (BadParam "The parameter 'q' must have at least one word.")
        endpointOf ["api", "search"] [("q", Just "nix"), ("limit", Just "3"), ("hops", Just "0")]
          @?= Right (SearchEndpoint defaultSearchOptions {searchLimit = 3, searchHops = 0} "nix")
        endpointOf ["api", "search"] [("q", Just "nix"), ("q", Just "other")]
          @?= Right (SearchEndpoint defaultSearchOptions "nix"),
      testCase "a bad parameter gets 400 with an error text" $ do
        let r = runIdentity (route fake (get ["api", "search"] []))
        resStatus r @?= 400
        (body r >>= at ["error"]) @?= Just (String "The parameter 'q' is missing."),
      testCase "an endpoint gives the JSON of the runner" $ do
        let r = runIdentity (route fake (get ["api", "refs"] []))
        resStatus r @?= 200
        header "Content-Type" r @?= Just "application/json; charset=utf-8"
        body r @?= Just (String "RefsEndpoint"),
      testCase "an error of the operation gets its status and text" $ do
        let check err s = do
              let r = runIdentity (route (failing err) (get ["api", "refs"] []))
              resStatus r @?= s
              (body r >>= at ["error"]) @?= Just (String (describe err))
        check (StoreFailed (NotFound (nid 1))) 404
        check (Pruned (nid 1) (Tombstone t0) Set.empty) 410
        check (NoSuchPrefix "sha256-0101") 404
        check (AmbiguousPrefix "sha256-01" [nid 1]) 400
        check (CacheFailed Cache.CacheLocked) 500,
      testCase "the page is not given to the runner" $
        resStatus (runIdentity (route (failing (BadInput "no")) (get [] []))) @?= 200
    ]

-- Windows --------------------------------------------------------------

t0 :: UTCTime
t0 = posixSecondsToUTCTime 1791201600

build :: [(Id, [(EdgeType, Id)])] -> Graph
build = foldMap (\(i, es) -> singleton i [Edge k t | (k, t) <- es])

-- A summary for each node, created n seconds after t0.
summariesFor :: [(Id, Int)] -> Map.Map Id Summary
summariesFor xs = Map.fromList [(i, Summary i "fact" "claude" (addUTCTime (fromIntegral n) t0) "line") | (i, n) <- xs]

dataOf :: Graph -> Map.Map Id Summary -> GraphData
dataOf g s =
  GraphData
    { gdGraph = g,
      gdSummaries = s,
      gdStore = Map.keysSet s,
      gdCached = Map.keysSet s,
      gdTombstones = Map.empty
    }

windowCases :: TestTree
windowCases =
  testGroup
    "graph windows"
    [ testCase "the default window starts at the newest heads" $ do
        -- b supersedes a; c and d are heads; d is the newest.
        let g = build [(nid 1, []), (nid 2, [(Supersedes, nid 1)]), (nid 3, []), (nid 4, [])]
            created = fmap sumCreated . (`Map.lookup` summariesFor [(nid 1, 1), (nid 2, 2), (nid 3, 3), (nid 4, 4)])
        snd (selectWindow defaultWindow {winLimit = 2} created g) @?= [nid 4, nid 3]
        fst (selectWindow defaultWindow {winLimit = 2, winHops = 0} created g) @?= Set.fromList [nid 3, nid 4],
      testCase "hops reach older and newer memories, and dangling targets" $ do
        let g = build [(nid 1, []), (nid 2, [(Supersedes, nid 1)]), (nid 3, [(About, nid 2), (About, nid 9)])]
            w = defaultWindow {winFocus = Just (nid 2), winHops = 1}
        fst (selectWindow w (const Nothing) g) @?= Set.fromList [nid 1, nid 2, nid 3]
        fst (selectWindow w {winFocus = Just (nid 3)} (const Nothing) g) @?= Set.fromList [nid 2, nid 3, nid 9],
      testCase "all shows every node and every dangling target" $ do
        let g = build [(nid 1, [(About, nid 9)]), (nid 2, [])]
        fst (selectWindow defaultWindow {winAll = True} (const Nothing) g) @?= Set.fromList [nid 1, nid 2, nid 9],
      testCase "the view has the status of each node, and only edges between shown nodes" $ do
        let g = build [(nid 1, []), (nid 2, [(Supersedes, nid 1), (About, nid 8), (Refines, nid 9)])]
            d = (dataOf g (summariesFor [(nid 1, 1), (nid 2, 2)])) {gdTombstones = Map.singleton (nid 8) t0}
            v = graphView defaultWindow {winAll = True} d
        map (\n -> (gnId n, gnStatus n)) (gvNodes v)
          @?= [(nid 1, SupersededNode), (nid 2, HeadNode), (nid 8, PrunedTarget t0), (nid 9, MissingTarget)]
        length (gvEdges v) @?= 3
        gvTruncated v @?= False
        let small = graphView defaultWindow {winFocus = Just (nid 1), winHops = 0} d
        map gnId (gvNodes small) @?= [nid 1]
        gvEdges small @?= []
        gvTruncated small @?= True
        (gvTotalNodes small, gvTotalEdges small) @?= (4, 3),
      testCase "a node that only the cache has is marked" $ do
        let g = build [(nid 1, [])]
            d = (dataOf g (summariesFor [(nid 1, 1)])) {gdStore = Set.empty}
        map gnInStore (gvNodes (graphView defaultWindow d)) @?= [False],
      testCase "the JSON of a view has the counts and the window" $ do
        let g = build [(nid 1, []), (nid 2, [(Supersedes, nid 1)])]
            v = graphViewJSON (graphView defaultWindow (dataOf g (summariesFor [(nid 1, 1), (nid 2, 2)])))
        at ["total", "nodes"] v @?= Just (Number 2)
        at ["shown", "edges"] v @?= Just (Number 1)
        at ["truncated"] v @?= Just (Bool False)
        at ["window", "hops"] v @?= Just (Number 2)
        map (at ["status"]) (items (at ["nodes"] v)) @?= [Just "superseded", Just "head"],
      testCase "a big graph is cut to a window" $ do
        -- 3000 memories in 1000 chains of three.
        let chain k = [(nid' (3 * k), []), (nid' (3 * k + 1), [(Supersedes, nid' (3 * k))]), (nid' (3 * k + 2), [(Supersedes, nid' (3 * k + 1))])]
            g = build (concatMap chain [0 .. 999])
            sums = summariesFor [(nid' n, n) | n <- [0 .. 2999]]
            v = graphView defaultWindow (dataOf g sums)
        gvTotalNodes v @?= 3000
        length (gvSeeds v) @?= winLimit defaultWindow
        length (gvNodes v) @?= 3 * winLimit defaultWindow
        gvTruncated v @?= True,
      testProperty "the view never has an edge to a node that it does not show" $
        forAll genGraph $ \g ->
          forAll (choose (0, 3)) $ \h ->
            let v = graphView defaultWindow {winHops = h, winLimit = 2} (dataOf g Map.empty)
                shown = Set.fromList (map gnId (gvNodes v))
             in conjoin [geSrc e `Set.member` shown && geDst e `Set.member` shown | e <- gvEdges v],
      testProperty "all shows every edge of the graph" $
        forAll genGraph $ \g ->
          let v = graphView defaultWindow {winAll = True} (dataOf g Map.empty)
           in (length (gvEdges v), gvTruncated v) === (gvTotalEdges v, False)
    ]

-- An 'Id' for a number up to 65535. 'nid' only has 256 values.
nid' :: Int -> Id
nid' n = hashBytes (TE.encodeUtf8 (T.pack (show n)))

genGraph :: Gen Graph
genGraph =
  build
    <$> listOf
      ( (,)
          <$> elements universe
          <*> listOf ((,) <$> elements [minBound .. maxBound] <*> elements universe)
      )
  where
    universe = map nid [0 .. 6]

-- The page -------------------------------------------------------------

pageCases :: TestTree
pageCases =
  testGroup
    "page"
    [ testCase "the page has the data marker" $
        BS.isInfixOf dataMarker indexPage @?= True,
      testCase "vizPage puts the data in a JSON script element, in place of the marker" $ do
        let p = vizPage (object ["a" .= (1 :: Int)])
        BS.isInfixOf "<script type=\"application/json\" id=\"akyuu-data\">{\"a\":1}</script>" p @?= True
        BS.isInfixOf dataMarker p @?= False,
      testCase "a body cannot end the script element" $ do
        let p = vizPage (object ["body" .= ("</script><script>alert(1)</script><!--" :: Text)])
        BS.isInfixOf "</script><script>alert" p @?= False
        BS.isInfixOf "<!--\"" p @?= False,
      testProperty "scriptSafeJSON has no < > & and decodes to the same value" $ \s ->
        let v = object ["t" .= T.pack s]
            out = scriptSafeJSON v
         in conjoin
              [ BL.any (`elem` [0x3c, 0x3e, 0x26]) out === False,
                A.decode out === Just v
              ]
    ]

-- A real store ---------------------------------------------------------

-- Run an endpoint against the store, as the server does, and give the
-- status and the JSON.
call :: Env -> [Text] -> [(Text, Maybe Text)] -> IO (Int, Value)
call env p q = do
  r <- route (runEndpoint env) (get p q)
  pure (resStatus r, fromMaybe Null (body r))

-- Every file under a directory with its content. The cache files are left
-- out, because SQLite can touch its own files on a read.
treeOf :: FilePath -> IO [(FilePath, BS.ByteString)]
treeOf root = sort <$> go ""
  where
    go rel = do
      names <- listDirectory (root </> rel)
      concat
        <$> forM
          (filter (not . ("cache.sqlite" `isPrefixOf`)) names)
          ( \n -> do
              let r = rel </> n
              isDir <- doesDirectoryExist (root </> r)
              if isDir
                then ((r, "<dir>") :) <$> go r
                else (\bs -> [(r, bs)]) <$> BS.readFile (root </> r)
          )

-- A small store: a ref with two generations, a note about the current one,
-- a pin, and a dangling edge. The cache is in sync.
smallStore :: Env -> IO (Id, Id, Id)
smallStore env = do
  v1 <- right =<< addMemory env (note "Lilly prefers Haskell." [])
  n <- right (mkName "claude/lang")
  _ <- right =<< setRefTo env n MustBeAbsent v1
  v2 <- right =<< supersedeMemory env n (Just v1) (note "Lilly prefers Haskell and Nix." [])
  about <- right =<< addMemory env (note "The flake pins nixpkgs." [Edge About v2, Edge DerivedFrom (nid 7)])
  right =<< GC.pin (envStore env) about
  _ <- right =<< Cache.sync (envCache env) (envStore env)
  pure (v1, v2, about)

storeCases :: TestTree
storeCases =
  testGroup
    "endpoints on a store"
    [ testCase "stats counts the store" $
        withOpsEnv $ \_ env -> do
          _ <- smallStore env
          (s, v) <- call env ["api", "stats"] []
          s @?= 200
          (at ["memories"] v, at ["cached"] v, at ["refs"] v, at ["pins"] v) @?= (Just (Number 3), Just (Number 3), Just (Number 1), Just (Number 1))
          assertBool "no newest time" (at ["newest"] v /= Just Null),
      testCase "the stats fingerprint changes when the store changes" $
        withOpsEnv $ \_ env -> do
          _ <- smallStore env
          (_, v1) <- call env ["api", "stats"] []
          _ <- right =<< addMemory env (note "one more" [])
          (_, v2) <- call env ["api", "stats"] []
          assertBool "same fingerprint" (at ["fingerprint"] v1 /= at ["fingerprint"] v2),
      testCase "the graph has every node, with its status, and the dangling target" $
        withOpsEnv $ \_ env -> do
          (v1, v2, about) <- smallStore env
          (s, v) <- call env ["api", "graph"] [("all", Just "1")]
          s @?= 200
          let status i = [at ["status"] x | x <- items (at ["nodes"] v), at ["id"] x == Just (String (render i))]
          status v1 @?= [Just "superseded"]
          status v2 @?= [Just "head"]
          status about @?= [Just "head"]
          status (nid 7) @?= [Just "missing"]
          at ["shown", "edges"] v @?= Just (Number 3),
      testCase "a focus that is not in the graph gives 404" $
        withOpsEnv $ \_ env -> do
          _ <- smallStore env
          (s, _) <- call env ["api", "graph"] [("focus", Just (render (nid 5)))]
          s @?= 404,
      testCase "a memory by the start of its id has its body, edges and refs" $
        withOpsEnv $ \_ env -> do
          (v1, v2, about) <- smallStore env
          (s, v) <- call env ["api", "memory", T.take 14 (render v1)] []
          s @?= 200
          at ["id"] v @?= Just (String (render v1))
          at ["body"] v @?= Just "Lilly prefers Haskell."
          at ["status"] v @?= Just "superseded"
          [(at ["name"] r, at ["generation"] r) | r <- items (at ["refs"] v)] @?= [(Just "claude/lang", Just (Number 1))]
          [(at ["dir"] e, at ["kind"] e, at ["id"] e) | e <- items (at ["edges"] v)] @?= [(Just "in", Just "supersedes", Just (String (render v2)))]
          (s2, _) <- call env ["api", "memory", render about] []
          s2 @?= 200,
      testCase "a missing memory gives 404, and a bad id 400" $
        withOpsEnv $ \_ env -> do
          _ <- smallStore env
          (s1, _) <- call env ["api", "memory", render (nid 5)] []
          s1 @?= 404
          (s2, _) <- call env ["api", "memory", "xyz"] []
          s2 @?= 400,
      testCase "refs gives each ref with its history" $
        withOpsEnv $ \_ env -> do
          (v1, v2, _) <- smallStore env
          (_, v) <- call env ["api", "refs"] []
          [(at ["name"] r, at ["current"] r, strings (at ["history"] r)) | r <- items (at ["refs"] v)]
            @?= [(Just "claude/lang", Just (String (render v2)), [render v1])]
          at ["kept"] v @?= Just (Number 5),
      testCase "search puts the current memory first and has the context" $
        withOpsEnv $ \_ env -> do
          (v1, v2, about) <- smallStore env
          (s, v) <- call env ["api", "search"] [("q", Just "haskell")]
          s @?= 200
          [at ["id"] m | m <- items (at ["matches"] v)] @?= [Just (String (render v2)), Just (String (render v1))]
          [strings (at ["supersededBy"] m) | m <- items (at ["matches"] v)] @?= [[], [render v2]]
          (render about `elem` strings (at ["context"] v)) @?= True,
      testCase "search gives a snippet with marks that a bracket of the body cannot copy" $
        withOpsEnv $ \_ env -> do
          _ <- right =<< addMemory env (NewMemory "fact" "claude" Set.empty "see [x] and Haskell")
          _ <- right =<< Cache.sync (envCache env) (envStore env)
          (s, v) <- call env ["api", "search"] [("q", Just "haskell")]
          s @?= 200
          [at ["snippet"] m | m <- items (at ["matches"] v)] @?= [Just (String "see [x] and \SOHHaskell\STX")],
      testCase "the plan is empty for a young store, and lists the young nodes" $
        withOpsEnv $ \_ env -> do
          _ <- smallStore env
          (s, v) <- call env ["api", "gc", "plan"] []
          s @?= 200
          strings (at ["planned"] v) @?= []
          length (strings (at ["young"] v)) @?= 3
          at ["policy", "keepGenerations"] v @?= Just (Number 5),
      testCase "explain lists the ref generation, the pin and the young rule" $
        withOpsEnv $ \_ env -> do
          (v1, _, about) <- smallStore env
          (_, w1) <- call env ["api", "gc", "explain", render v1] []
          at ["live"] w1 @?= Just (Bool True)
          [at ["reason"] r | r <- items (at ["reasons"] w1)] @?= [Just "ref", Just "young"]
          [at ["refs"] r | r <- items (at ["reasons"] w1), at ["reason"] r == Just "ref"]
            @?= [Just (A.toJSON [object ["name" .= ("claude/lang" :: Text), "generation" .= (1 :: Int)]])]
          (_, w2) <- call env ["api", "gc", "explain", render about] []
          [at ["reason"] r | r <- items (at ["reasons"] w2)] @?= [Just "pin", Just "young"]
          (s3, _) <- call env ["api", "gc", "explain", render (nid 5)] []
          s3 @?= 404,
      testCase "trash lists the pins, the trash and the tombstones" $
        withOpsEnv $ \_ env -> do
          (_, _, about) <- smallStore env
          (_, v) <- call env ["api", "trash"] []
          [(at ["id"] p, at ["inStore"] p) | p <- items (at ["pins"] v)] @?= [(Just (String (render about)), Just (Bool True))]
          items (at ["trash"] v) @?= []
          items (at ["tombstones"] v) @?= [],
      testCase "verify shows the dangling target and the drift of the cache" $
        withOpsEnv $ \_ env -> do
          _ <- smallStore env
          fresh <- right =<< Store.add (envStore env) (testMemory "fact" t0 "claude" Set.empty "not in the cache")
          (s, v) <- call env ["api", "verify"] []
          s @?= 200
          at ["ok"] v @?= Just (Bool False)
          strings (at ["missing"] v) @?= [render (nid 7)]
          at ["drift", "inSync"] v @?= Just (Bool False)
          strings (at ["drift", "storeOnly"] v) @?= [render fresh]
          strings (at ["drift", "cacheOnly"] v) @?= [],
      testCase "check lists a fork and names the refs" $
        withOpsEnv $ \_ env -> do
          base <- right =<< Store.add (envStore env) (testMemory "fact" t0 "claude" Set.empty "the old text of a note")
          let sup = Set.singleton (Edge Supersedes base)
          _ <- right =<< Store.add (envStore env) (testMemory "fact" t0 "claude" sup "first new text")
          _ <- right =<< Store.add (envStore env) (testMemory "fact" t0 "claude" sup "second new text")
          (s, v) <- call env ["api", "check"] []
          s @?= 200
          [at ["kind"] x | x <- items (at ["findings"] v), at ["severity"] x == Just "problem"] @?= [Just "fork"]
          at ["refs"] v @?= Just (object []),
      testCase "a memory that the cache does not have is in the graph, marked" $
        withOpsEnv $ \_ env -> do
          _ <- smallStore env
          fresh <- right =<< Store.add (envStore env) (testMemory "fact" t0 "claude" Set.empty "not in the cache\nsecond")
          (_, v) <- call env ["api", "graph"] [("all", Just "1")]
          [(at ["inCache"] x, at ["line"] x) | x <- items (at ["nodes"] v), at ["id"] x == Just (String (render fresh))]
            @?= [(Just (Bool False), Just "not in the cache")],
      testCase "no endpoint writes to the store, the refs, the pins or the cache" $
        withOpsEnv $ \dir env -> do
          (v1, _, _) <- smallStore env
          _ <- right =<< Store.add (envStore env) (testMemory "fact" t0 "claude" Set.empty "not in the cache")
          treeBefore <- treeOf dir
          cachedBefore <- right =<< cachedIds (envCache env)
          let paths =
                [ (["api", "stats"], []),
                  (["api", "graph"], []),
                  (["api", "graph"], [("all", Just "1")]),
                  (["api", "memory", render v1], []),
                  (["api", "refs"], []),
                  (["api", "search"], [("q", Just "haskell")]),
                  (["api", "gc", "plan"], []),
                  (["api", "gc", "explain", render v1], []),
                  (["api", "trash"], []),
                  (["api", "verify"], []),
                  (["api", "check"], []),
                  ([], [])
                ]
          forM_ paths $ \(p, q) -> do
            (s, _) <- call env p q
            assertBool ("status " <> show s <> " for " <> show p) (s == 200)
          treeAfter <- treeOf dir
          cachedAfter <- right =<< cachedIds (envCache env)
          treeAfter @?= treeBefore
          cachedAfter @?= cachedBefore
    ]
