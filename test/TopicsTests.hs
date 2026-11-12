{-# LANGUAGE OverloadedStrings #-}

module TopicsTests (topicsTests, withLocal, forkTopic, topicName, newTopic, onlyHead) where

import Akyuu.Error (AkyuuError (BadInput))
import Akyuu.Graph (Edge (Edge, kind), EdgeType (Follows, Supersedes))
import Akyuu.Id qualified as Id
import Akyuu.Memory (Memory (memAboutRefs, memAgent, memBody, memEdges), memoryId, renderMemory)
import Akyuu.Ops (NewMemory (NewMemory, newAboutRefs), buildMemory, withEnv)
import Akyuu.Refs (Name, mkName)
import Akyuu.Sync.Event (mkEvent)
import Akyuu.Sync.Repository (importState, loadSnapshot, openRepository, snapshotState)
import Akyuu.Sync.State (RefKind (LogKind))
import Akyuu.Sync.State qualified as State
import Akyuu.Sync.Topics (LocalReplica, TopicContext (TopicContext), TopicError (ExistingTopic, InvalidInput, InvalidSelection, NeedsResolution, StaleTopic), TopicHead (headEvent, headKind, headMemory, headMemoryId, headReplica, headTime), TopicStatus (Conflicted, LogTopic, Missing, Resolved, TypeConflicted), TopicView (viewCheckpoint, viewHeads, viewName, viewStatus, viewVersion), conflicts, contextTopics, createTopic, initialiseLocal, openLocal, readTopic, replaceTopic, resolveLogGuarded, resolveTopic, selectTopic)
import Akyuu.Sync.Types (Action (AppendLog, RegisterReplica, SetTopic), Nonce (Nonce), ReplicaId (ReplicaId), Resource (RegistryResource), mkIdentifier)
import Data.ByteString qualified as BS
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Support (right, withTempDir)
import System.Directory (doesFileExist)
import System.FilePath ((</>))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

topicName :: Name
topicName = either (error . show) id (mkName "me/topic")

newTopic :: Text -> NewMemory
newTopic body = NewMemory "fact" "test-author" Set.empty body Set.empty

withLocal :: (FilePath -> LocalReplica -> IO a) -> IO a
withLocal action = withTempDir $ \root -> initialiseLocal root "test-replica" >>= right >>= action root

onlyHead :: TopicView -> IO TopicHead
onlyHead view = case viewHeads view of
  [entry] -> pure entry
  _ -> assertFailure "Expected exactly one topic head."

-- A second registered replica writes from the original read, after a local
-- replacement. Type conflicts instead declare a concurrent log from no parent.
forkTopic :: Bool -> FilePath -> LocalReplica -> IO TopicView
forkTopic mixed root local = do
  original <- createTopic local topicName (newTopic "original") >>= right
  base <- onlyHead original
  _ <- replaceTopic local topicName (viewVersion original) (newTopic "local branch") >>= right
  repo <- openRepository root >>= right
  before <- loadSnapshot repo >>= right
  let state = snapshotState before
      ident byte = either (error . show) id (mkIdentifier (BS.replicate 16 byte))
      remote = ReplicaId (ident 9)
      registration = either (error . show) id (mkEvent (State.storeId state) remote (Nonce (ident 10)) (Map.keysSet (State.resourceHeads state RegistryResource)) (RegisterReplica remote "remote") (headTime base))
      content = either (error . show) id (buildMemory (headTime base) (newTopic "remote branch"))
      action = if mixed then AppendLog topicName (memoryId content) else SetTopic topicName (memoryId content)
      parents = if mixed then Set.empty else Set.singleton (headEvent base)
      branch = either (error . show) id (mkEvent (State.storeId state) remote (Nonce (ident 11)) parents action (headTime base))
      incoming = either (error . show) id (State.fromEvents (State.storeId state) (registration : branch : Map.elems (State.events state)))
  _ <- importState repo incoming [(memoryId content, renderMemory content)] >>= right
  readTopic local topicName >>= right

topicsTests :: TestTree
topicsTests =
  testGroup
    "Akyuu.Sync.Topics"
    [ testCase "local identity survives reinitialisation and reopening" $ withLocal $ \root local -> do
        before <- BS.readFile (root </> "REPLICA")
        initialiseLocal root "another label" >>= (@?= Right local)
        openLocal root >>= (@?= Right local)
        BS.readFile (root </> "REPLICA") >>= (@?= before),
      testCase "missing topic has an explicit status and no heads" $ withLocal $ \_ local -> do
        view <- readTopic local topicName >>= right
        viewStatus view @?= Missing
        viewHeads view @?= [],
      testCase "create returns content and a new causal version" $ withLocal $ \_ local -> do
        before <- readTopic local topicName >>= right
        created <- createTopic local topicName (newTopic "first") >>= right
        viewStatus created @?= Resolved
        entry <- onlyHead created
        memBody (headMemory entry) @?= "first"
        memAgent (headMemory entry) @?= "test-author"
        assertBool "version did not change" (viewVersion before /= viewVersion created),
      testCase "creation never overwrites an existing topic" $ withLocal $ \_ local -> do
        created <- createTopic local topicName (newTopic "first") >>= right
        createTopic local topicName (newTopic "second") >>= (@?= Left (ExistingTopic created)),
      testCase "replacement adds supersession and rejects an old token" $ withLocal $ \_ local -> do
        original <- createTopic local topicName (newTopic "first") >>= right
        old <- onlyHead original
        revised <- replaceTopic local topicName (viewVersion original) (newTopic "second") >>= right
        current <- onlyHead revised
        assertBool "missing supersession edge" (Edge Supersedes (headMemoryId old) `Set.member` memEdges (headMemory current))
        replaceTopic local topicName (viewVersion original) (newTopic "third") >>= (@?= Left (StaleTopic revised)),
      testCase "a memory ID cannot substitute for the opaque version" $ withLocal $ \_ local -> do
        original <- createTopic local topicName (newTopic "first") >>= right
        entry <- onlyHead original
        wrong <- right (State.parseVersion (Id.render (headMemoryId entry)))
        replaceTopic local topicName wrong (newTopic "second") >>= (@?= Left (StaleTopic original)),
      testCase "conflict reads preserve every head and replica" $ withLocal $ \root local -> do
        forked <- forkTopic False root local
        viewStatus forked @?= Conflicted
        Set.fromList (map (memBody . headMemory) (viewHeads forked)) @?= Set.fromList ["local branch", "remote branch"]
        Set.size (Set.fromList (map headReplica (viewHeads forked))) @?= 2
        replaceTopic local topicName (viewVersion forked) (newTopic "overwrite") >>= (@?= Left (NeedsResolution forked)),
      testCase "an unaffected topic remains writable" $ withLocal $ \root local -> do
        _ <- forkTopic False root local
        other <- right (mkName "me/other")
        created <- createTopic local other (newTopic "independent") >>= right
        changed <- replaceTopic local other (viewVersion created) (newTopic "still independent") >>= right
        viewStatus changed @?= Resolved,
      testCase "resolution consumes every conflict head and supersedes their memories" $ withLocal $ \root local -> do
        forked <- forkTopic False root local
        resolved <- resolveTopic local topicName (viewVersion forked) (newTopic "merged") >>= right
        viewStatus resolved @?= Resolved
        entry <- onlyHead resolved
        assertBool "merge lost supersession evidence" (all (\old -> Edge Supersedes (headMemoryId old) `Set.member` memEdges (headMemory entry)) (viewHeads forked)),
      testCase "selection reuses content without inventing supersession edges" $ withLocal $ \root local -> do
        forked <- forkTopic False root local
        chosen <- case viewHeads forked of
          entry : _ -> pure entry
          _ -> assertFailure "Expected a conflict."
        resolved <- selectTopic local topicName (viewVersion forked) (headMemoryId chosen) >>= right
        entry <- onlyHead resolved
        headMemory entry @?= headMemory chosen
        headMemoryId entry @?= headMemoryId chosen
        assertBool "selection reused the old version" (viewVersion resolved /= viewVersion forked),
      testCase "selection rejects a memory outside the current heads" $ withLocal $ \root local -> do
        forked <- forkTopic False root local
        selectTopic local topicName (viewVersion forked) (Id.hashBytes "not a head") >>= (@?= Left (InvalidSelection (Id.hashBytes "not a head"))),
      testCase "concurrent topic and log declarations require explicit resolution" $ withLocal $ \root local -> do
        forked <- forkTopic True root local
        viewStatus forked @?= TypeConflicted
        replaceTopic local topicName (viewVersion forked) (newTopic "overwrite") >>= (@?= Left (NeedsResolution forked))
        resolved <- resolveTopic local topicName (viewVersion forked) (newTopic "chosen topic") >>= right
        viewStatus resolved @?= Resolved,
      testCase "a type conflict can resolve to the log and keep its history" $ withLocal $ \root local -> do
        forked <- forkTopic True root local
        let logHeads = [headMemoryId entry | entry <- viewHeads forked, headKind entry == LogKind]
        assertBool "expected a log head" (not (null logHeads))
        resolved <- resolveLogGuarded (const (pure (Right []))) local topicName (viewVersion forked) (newTopic "kept as a log") >>= right
        viewStatus resolved @?= LogTopic
        entry <- onlyHead resolved
        Set.filter ((== Follows) . kind) (memEdges (headMemory entry)) @?= Set.fromList (map (Edge Follows) logHeads),
      testCase "only a type conflict can resolve to a log" $ withLocal $ \root local -> do
        forked <- forkTopic False root local
        result <- resolveLogGuarded (const (pure (Right []))) local topicName (viewVersion forked) (newTopic "not a log")
        assertBool "a topic conflict became a log" (case result of Left (InvalidInput _) -> True; _ -> False),
      testCase "context includes missing and conflict markers from one checkpoint" $ withLocal $ \root local -> do
        _ <- forkTopic False root local
        missing <- right (mkName "me/missing")
        TopicContext checkpoint views <- contextTopics local [topicName, missing, topicName] >>= right
        map viewName views @?= [missing, topicName]
        map viewStatus views @?= [Missing, Conflicted]
        assertBool "mixed checkpoints" (all ((== checkpoint) . viewCheckpoint) views),
      testCase "conflict listing omits resolved topics" $ withLocal $ \root local -> do
        _ <- forkTopic False root local
        other <- right (mkName "me/other")
        _ <- createTopic local other (newTopic "independent") >>= right
        TopicContext _ views <- conflicts local >>= right
        map viewName views @?= [topicName],
      testCase "blank bodies and missing about-ref targets leave state unchanged" $ withLocal $ \_ local -> do
        before <- readTopic local topicName >>= right
        createTopic local topicName (newTopic " \n ") >>= assertInvalid
        missing <- right (mkName "me/missing")
        createTopic local topicName ((newTopic "linked") {newAboutRefs = Set.singleton missing}) >>= assertInvalid
        readTopic local topicName >>= (@?= Right before),
      testCase "about-ref links can name a conflicted topic" $ withLocal $ \root local -> do
        _ <- forkTopic False root local
        other <- right (mkName "me/other")
        created <- createTopic local other ((newTopic "linked") {newAboutRefs = Set.singleton topicName}) >>= right
        entry <- onlyHead created
        memAboutRefs (headMemory entry) @?= Set.singleton topicName,
      testCase "logical prefix names can coexist" $ withLocal $ \_ local -> do
        _ <- createTopic local topicName (newTopic "parent name") >>= right
        nested <- right (mkName "me/topic/detail")
        created <- createTopic local nested (newTopic "child name") >>= right
        viewStatus created @?= Resolved,
      testCase "legacy environment refuses checkpoint roots without legacy files" $ withLocal $ \root _ -> do
        result <- withEnv root (const (pure (Right ())))
        case result of
          Left (BadInput _) -> pure ()
          _ -> assertFailure ("Unexpected legacy open: " <> show result)
        traverse (doesFileExist . (root </>)) ["cache.sqlite", "refs", "store"] >>= (@?= [False, False, False])
    ]
  where
    assertInvalid (Left (InvalidInput _)) = pure ()
    assertInvalid other = assertFailure ("Expected invalid input, got " <> show other)
