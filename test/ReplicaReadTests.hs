{-# LANGUAGE OverloadedStrings #-}

module ReplicaReadTests (replicaReadTests) where

import Akyuu.Memory (Memory (memBody))
import Akyuu.Refs (Name, mkName)
import Akyuu.Sync.Context qualified as Context
import Akyuu.Sync.Search qualified as Search
import Akyuu.Sync.Topics (TopicError (ConfigurationChanged, InvalidInput), TopicHead (headMemory, headMemoryId), TopicStatus (Conflicted, Resolved), TopicView (viewCheckpoint, viewHeads, viewName, viewStatus, viewVersion))
import Akyuu.Sync.Topics qualified as Topics
import Akyuu.Sync.Web qualified as Web
import Akyuu.Tier (Place (Place))
import Control.Monad (void)
import Data.Aeson (Value (Object))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString qualified as BS
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Network.HTTP.Types (statusCode)
import Network.Wai qualified as Wai
import Network.Wai.Internal (ResponseReceived (ResponseReceived))
import Support (right)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))
import TopicsTests (forkTopic, newTopic, onlyHead, topicName, withLocal)

name :: Text -> Name
name = either (error . show) id . mkName

options :: Context.ContextOptions
options = Context.ContextOptions (name "policy/memory") (name "policy/tiers") "always" Nothing []

controls :: Topics.LocalReplica -> Text -> IO ()
controls local manifest = do
  void (Topics.createTopic local (Context.policyRef options) (newTopic "Original policy") >>= right)
  void (Topics.createTopic local (Context.manifestRef options) (newTopic manifest) >>= right)

replicaReadTests :: TestTree
replicaReadTests = testGroup "replica read models" [contextTests, searchTests, webTests]

contextTests :: TestTree
contextTests =
  testGroup
    "configured context"
    [ testCase "tier, place and extra refs retain order and deduplicate" $ withLocal $ \_ local -> do
        controls local "always: me/profile me/shared\nat ~/code: me/project me/shared\nbackground: me/other"
        mapM_ (\ref -> void (Topics.createTopic local (name ref) (newTopic ref) >>= right)) ["me/profile", "me/shared", "me/project", "me/extra"]
        report <- Context.configuredContext local options {Context.wantedPlace = Just (Place "/home/test" "/home/test/code/app"), Context.extraRefs = [name "me/shared", name "me/extra"]} >>= right
        Context.contextReady report @?= True
        map viewName (Context.contextEntries report) @?= map name ["policy/memory", "policy/tiers", "me/profile", "me/shared", "me/project", "me/extra"]
        assertBool "mixed checkpoint context" (all ((== Context.contextCheckpoint report) . viewCheckpoint) (Context.contextEntries report)),
      testCase "missing controls give minimal explicit diagnostics" $ withLocal $ \_ local -> do
        void (Topics.createTopic local topicName (newTopic "extra") >>= right)
        report <- Context.configuredContext local options {Context.extraRefs = [topicName]} >>= right
        Context.contextReady report @?= False
        map viewName (Context.contextEntries report) @?= [Context.policyRef options, Context.manifestRef options, topicName]
        length (Context.contextIssues report) @?= 2,
      testCase "a conflicted policy suspends manifest expansion" $ withLocal $ \root local -> do
        void (Topics.createTopic local (Context.manifestRef options) (newTopic "always: me/hidden") >>= right)
        void (Topics.createTopic local (name "me/hidden") (newTopic "must not expand") >>= right)
        forked <- forkTopic False root local
        let config = options {Context.policyRef = topicName}
        report <- Context.configuredContext local config >>= right
        Context.contextReady report @?= False
        Context.maintenanceReady report @?= False
        map viewName (Context.contextEntries report) @?= [topicName, Context.manifestRef options]
        map viewStatus (take 1 (Context.contextEntries report)) @?= [Conflicted]
        current <- Topics.readTopic local (name "me/hidden") >>= right
        Topics.resolveTopicGuarded (Context.resolutionGuard config (name "me/hidden")) local (name "me/hidden") (viewVersion current) (newTopic "blocked") >>= assertInvalid
        repaired <- Topics.resolveTopicGuarded (Context.resolutionGuard config topicName) local topicName (viewVersion forked) (newTopic "repaired policy") >>= right
        viewStatus repaired @?= Resolved,
      testCase "an invalid manifest is explicit and blocks unrelated resolution" $ withLocal $ \_ local -> do
        controls local "this is not a tier manifest"
        created <- Topics.createTopic local topicName (newTopic "value") >>= right
        report <- Context.configuredContext local options >>= right
        Context.maintenanceReady report @?= False
        assertBool "missing parse diagnostic" (any (T.isInfixOf "invalid") (Context.contextIssues report))
        Topics.resolveTopicGuarded (Context.resolutionGuard options topicName) local topicName (viewVersion created) (newTopic "blocked") >>= assertInvalid,
      testCase "missing tier and missing member preserve the other data" $ withLocal $ \_ local -> do
        controls local "always: me/missing"
        report <- Context.configuredContext local options >>= right
        Context.contextReady report @?= False
        length (Context.contextEntries report) @?= 3
        other <- Context.configuredContext local options {Context.wantedTier = "absent"} >>= right
        Context.contextReady other @?= False
        length (Context.contextEntries other) @?= 2,
      testCase "captured context ignores a later policy version" $ withLocal $ \_ local -> do
        controls local "always:"
        snapshot <- Topics.captureSnapshot local >>= right
        policy <- Topics.readTopic local (Context.policyRef options) >>= right
        void (Topics.replaceTopic local (Context.policyRef options) (viewVersion policy) (newTopic "Later policy") >>= right)
        report <- Context.configuredAt snapshot options >>= right
        entry <- onlyHead (head (Context.contextEntries report))
        memBody (headMemory entry) @?= "Original policy",
      testCase "policy change between validation and commit rejects the resolution" $ withLocal $ \_ local -> do
        controls local "always:"
        created <- Topics.createTopic local topicName (newTopic "unchanged") >>= right
        let racingGuard snapshot = do
              checked <- Context.resolutionGuard options topicName snapshot
              policy <- Topics.readTopic local (Context.policyRef options) >>= right
              void (Topics.replaceTopic local (Context.policyRef options) (viewVersion policy) (newTopic "Changed during validation") >>= right)
              pure checked
        Topics.resolveTopicGuarded racingGuard local topicName (viewVersion created) (newTopic "must not publish") >>= (@?= Left ConfigurationChanged)
        current <- Topics.readTopic local topicName >>= right
        viewVersion current @?= viewVersion created
        entry <- onlyHead current
        memBody (headMemory entry) @?= "unchanged"
    ]

searchTests :: TestTree
searchTests =
  testGroup
    "current-head search"
    [ testCase "one matching branch returns every alternative" $ withLocal $ \root local -> do
        void (forkTopic False root local)
        Search.SearchReport _ _ hits <- Search.searchTopics local "local" 10 >>= right
        length hits @?= 1
        length (viewHeads (Search.hitTopic (head hits))) @?= 2
        Set.size (Search.matchedHeads (head hits)) @?= 1,
      testCase "words in different branches do not create a fabricated match" $ withLocal $ \root local -> do
        void (forkTopic False root local)
        Search.SearchReport _ _ hits <- Search.searchTopics local "local remote" 10 >>= right
        hits @?= [],
      testCase "explicit selection removes the other branch from current search" $ withLocal $ \root local -> do
        forked <- forkTopic False root local
        selected <- case filter ((== "remote branch") . memBody . headMemory) (viewHeads forked) of
          entry : _ -> pure entry
          _ -> assertFailure "No remote branch."
        void (Topics.selectTopic local topicName (viewVersion forked) (headMemoryId selected) >>= right)
        Search.SearchReport _ _ old <- Search.searchTopics local "local" 10 >>= right
        Search.SearchReport _ _ current <- Search.searchTopics local "remote" 10 >>= right
        old @?= []
        length current @?= 1,
      testCase "superseded content is absent and FTS retains stemming" $ withLocal $ \_ local -> do
        created <- Topics.createTopic local topicName (newTopic "archived-only") >>= right
        void (Topics.replaceTopic local topicName (viewVersion created) (newTopic "garden flowers") >>= right)
        Search.SearchReport _ _ old <- Search.searchTopics local "archived" 10 >>= right
        old @?= []
        Search.SearchReport _ _ current <- Search.searchTopics local "flower" 10 >>= right
        length current @?= 1,
      testCase "limit applies to topics after branch grouping" $ withLocal $ \root local -> do
        void (forkTopic False root local)
        Search.SearchReport _ _ hits <- Search.searchTopics local "branch" 1 >>= right
        length hits @?= 1
        Set.size (Search.matchedHeads (head hits)) @?= 2,
      testCase "invalid limits and blank queries fail explicitly" $ withLocal $ \_ local -> do
        Search.searchTopics local "word" 0 >>= assertInvalid
        Search.searchTopics local "word" 101 >>= assertInvalid
        Search.searchTopics local "  " 10 >>= assertInvalid,
      testCase "old captured search remains stable after a replacement" $ withLocal $ \_ local -> do
        created <- Topics.createTopic local topicName (newTopic "earlier") >>= right
        snapshot <- Topics.captureSnapshot local >>= right
        void (Topics.replaceTopic local topicName (viewVersion created) (newTopic "later") >>= right)
        Search.SearchReport _ _ old <- Search.searchAt snapshot "earlier" 10 >>= right
        Search.SearchReport _ _ current <- Search.searchTopics local "earlier" 10 >>= right
        length old @?= 1
        current @?= []
    ]

webTests :: TestTree
webTests =
  testGroup
    "replica browser"
    [ testCase "bundle, context and search share one checkpoint" $ withLocal $ \root local -> do
        void (forkTopic False root local)
        bundle <- Web.readView local options (Just "local") 10 >>= right
        at ["context", "checkpoint"] bundle @?= at ["checkpoint"] bundle
        at ["search", "checkpoint"] bundle @?= at ["checkpoint"] bundle,
      testCase "host, method and endpoint checks are enforced" $ withLocal $ \_ local -> do
        call local "GET" [] Nothing [] >>= (@?= 403)
        call local "POST" [] (Just "localhost:7421") [] >>= (@?= 405)
        call local "GET" ["unknown"] (Just "localhost:7421") [] >>= (@?= 404)
        call local "GET" [] (Just "localhost:7421") [] >>= (@?= 200)
        call local "GET" ["api", "view"] (Just "localhost:7421") [("limit", Just "0")] >>= (@?= 400)
        call local "GET" ["api", "view"] (Just "localhost:7421") [("q", Just "word"), ("q", Just "other")] >>= (@?= 400),
      testCase "static export escapes memory text outside executable script" $ withLocal $ \_ local -> do
        void (Topics.createTopic local topicName (newTopic "</script><img src=x onerror=alert(1)>") >>= right)
        bytes <- Web.staticPage local options >>= right
        assertBool "unescaped body" (not (BS.isInfixOf "</script><img" bytes))
        assertBool "missing embedded data" (BS.isInfixOf "id=\"akyuu-data\"" bytes)
        assertBool "missing escaped body" (BS.isInfixOf "\\u003c/script\\u003e" bytes)
    ]
  where
    call local method path host query = do
      result <- newIORef 0
      let request = Wai.defaultRequest {Wai.requestMethod = method, Wai.pathInfo = path, Wai.requestHeaderHost = host, Wai.queryString = query}
      _ <- Web.application 7421 local options request $ \response -> writeIORef result (statusCode (Wai.responseStatus response)) >> pure ResponseReceived
      readIORef result

assertInvalid :: (Show a) => Either TopicError a -> IO ()
assertInvalid (Left (InvalidInput _)) = pure ()
assertInvalid result = assertFailure ("Expected invalid input: " <> show result)

at :: [Text] -> Value -> Maybe Value
at [] value = Just value
at (key : rest) (Object fields) = KM.lookup (Key.fromText key) fields >>= at rest
at _ _ = Nothing
