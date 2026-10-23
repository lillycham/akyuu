{-# LANGUAGE OverloadedStrings #-}

module TopicOpsTests (topicOpsTests) where

import Akyuu.Amend (Edit (Replace))
import Akyuu.Check (Finding (findingKind), FindingKind (Fork, Unreferenced), defaultCheckOptions)
import Akyuu.Error (AkyuuError (BadInput))
import Akyuu.Memory (Memory (memAboutRefs, memBody, memKind))
import Akyuu.Ops (Env, NewMemory (newAboutRefs, newKind), TopicView (tvAbout, tvId, tvMemory, tvMentionedBy), addToTopic, addUnderRef, appendEpisode, checkStore, getMemory, listRefNames, listRefValues, readRef, recallQuery, recallTopic, rememberTopic, replaceTopic, reviseTopic, supersedeMemory, verifyOk, verifyStore)
import Akyuu.Refs (Name, Ref (current), mkName)
import Akyuu.Topic (Entry (Entry), versionToken)
import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, readMVar, takeMVar)
import Control.Monad (forM, forM_)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import OpsTests (note, withOpsEnv)
import Support (right)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

topicOpsTests :: TestTree
topicOpsTests =
  testGroup
    "topic operations"
    [ rememberCases,
      addToCases,
      reviseCases,
      replaceCases,
      logCases,
      recallCases,
      concurrentCases
    ]

-- Helpers --------------------------------------------------------------

name :: Text -> Name
name = either (error . show) id . mkName

oven, manifest :: Name
oven = name "kitchen/oven"
manifest = name "policy/tiers"

-- A topic with this text.
made :: Env -> Name -> Text -> IO ()
made env n body = () <$ (right =<< addUnderRef env n (note body []))

-- The error text of a refusal, or a test failure.
refusal :: (Show a) => Either AkyuuError a -> IO Text
refusal r = case r of
  Left (BadInput t) -> pure t
  other -> assertFailure ("expected a refusal, got " <> show other)

-- The text of a topic now.
textOf :: Env -> Name -> IO Text
textOf env n = do
  ref <- right =<< readRef env n
  memBody <$> (right =<< getMemory env (current ref))

-- The version of a topic now.
versionOf :: Env -> Name -> IO Text
versionOf env n = versionToken . tvId <$> (right =<< recallTopic env n)

-- Run the actions at once, from a common start.
together :: [IO a] -> IO [a]
together actions = do
  start <- newEmptyMVar
  outputs <- forM actions $ \action -> do
    output <- newEmptyMVar
    _ <- forkIO (readMVar start >> action >>= putMVar output)
    pure output
  putMVar start ()
  mapM takeMVar outputs

-- remember -------------------------------------------------------------

rememberCases :: TestTree
rememberCases =
  testGroup
    "rememberTopic"
    [ testCase "makes a topic that recallTopic reads" $
        withOpsEnv $ \_ env -> do
          _ <- right =<< rememberTopic env oven "claude" "fact" "The oven is 90 cm." Set.empty
          v <- right =<< recallTopic env oven
          memBody (tvMemory v) @?= "The oven is 90 cm."
          memKind (tvMemory v) @?= "fact",
      testCase "refuses a topic that exists, shows its text, and names the verbs" $
        withOpsEnv $ \_ env -> do
          made env oven "The oven is 90 cm.\nIt has a grill."
          t <- refusal =<< rememberTopic env oven "claude" "fact" "Another text." Set.empty
          assertBool "exists" ("kitchen/oven' exists" `T.isInfixOf` t)
          assertBool "start of the text" ("The oven is 90 cm." `T.isInfixOf` t)
          assertBool "the verbs" (all (`T.isInfixOf` t) ["add_to", "revise", "replace"])
          textOf env oven >>= (@?= "The oven is 90 cm.\nIt has a grill."),
      testCase "names the topics that are close to the new text, after the write" $
        withOpsEnv $ \_ env -> do
          made env oven "The oven in the kitchen is the 90 cm model from Harwell."
          made env (name "kitchen/rota") "Cleaning is on Mondays and Thursdays for everyone."
          (_, close) <- right =<< rememberTopic env (name "kitchen/oven-copy") "claude" "fact" "The oven in the kitchen is the 90 cm model from Harwell. It has a grill." Set.empty
          close @?= [oven]
          textOf env (name "kitchen/oven-copy") >>= \t -> assertBool "written" ("grill" `T.isInfixOf` t),
      testCase "refuses a blank text and makes no topic" $
        withOpsEnv $ \_ env -> do
          _ <- refusal =<< rememberTopic env oven "claude" "fact" "  \n" Set.empty
          listRefNames env >>= (@?= Right []),
      testCase "keeps the topics that the memory is about" $
        withOpsEnv $ \_ env -> do
          made env oven "The oven is 90 cm."
          _ <- right =<< rememberTopic env (name "kitchen/shop") "claude" "fact" "Buy a grill pan." (Set.singleton oven)
          v <- right =<< recallTopic env (name "kitchen/shop")
          tvAbout v @?= [oven]
    ]

-- add_to ---------------------------------------------------------------

addToCases :: TestTree
addToCases =
  testGroup
    "addToTopic"
    [ testCase "adds a line, and keeps the kind and the links" $
        withOpsEnv $ \_ env -> do
          made env (name "kitchen/rota") "Cleaning is on Mondays."
          _ <- right =<< addUnderRef env oven ((note "The oven is 90 cm." []) {newKind = "preference", newAboutRefs = Set.singleton (name "kitchen/rota")})
          (_, m) <- right =<< addToTopic env manifest "claude" oven "It has a grill."
          memBody m @?= "The oven is 90 cm.\nIt has a grill."
          memKind m @?= "preference"
          memAboutRefs m @?= Set.singleton (name "kitchen/rota")
          textOf env oven >>= (@?= "The oven is 90 cm.\nIt has a grill."),
      testCase "a topic that does not exist is refused, with the near names and remember" $
        withOpsEnv $ \_ env -> do
          made env oven "The oven is 90 cm."
          t <- refusal =<< addToTopic env manifest "claude" (name "kitchen/ovne") "It has a grill."
          assertBool "near" ("Close names: kitchen/oven." `T.isInfixOf` t)
          assertBool "remember" ("remember" `T.isInfixOf` t)
          listRefNames env >>= (@?= Right [oven]),
      testCase "a blank text is refused and nothing is written" $
        withOpsEnv $ \_ env -> do
          made env oven "The oven is 90 cm."
          before <- right =<< readRef env oven
          _ <- refusal =<< addToTopic env manifest "claude" oven " \n"
          after <- right =<< readRef env oven
          after @?= before
    ]

-- revise ---------------------------------------------------------------

reviseCases :: TestTree
reviseCases =
  testGroup
    "reviseTopic"
    [ testCase "applies a patch to the current memory, also if it changed since the agent read it" $
        withOpsEnv $ \_ env -> do
          made env oven "The oven is 90 cm."
          _ <- right =<< addToTopic env manifest "someone else" oven "It has a grill."
          _ <- right =<< reviseTopic env manifest "claude" oven [Replace "90 cm" "60 cm"]
          textOf env oven >>= (@?= "The oven is 60 cm.\nIt has a grill."),
      testCase "a patch that does not apply shows the current text and writes nothing" $
        withOpsEnv $ \_ env -> do
          made env oven "The oven is 90 cm."
          before <- right =<< readRef env oven
          t <- refusal =<< reviseTopic env manifest "claude" oven [Replace "100 cm" "60 cm"]
          assertBool "reason" ("not in the memory" `T.isInfixOf` t)
          assertBool "current text" ("The oven is 90 cm." `T.isInfixOf` t)
          assertBool "no id" (not ("sha256-" `T.isInfixOf` t))
          (right =<< readRef env oven) >>= (@?= before),
      testCase "a patch that would blank the topic is refused" $
        withOpsEnv $ \_ env -> do
          made env oven "The oven is 90 cm."
          _ <- refusal =<< reviseTopic env manifest "claude" oven [Replace "The oven is 90 cm." " "]
          textOf env oven >>= (@?= "The oven is 90 cm.")
    ]

-- replace --------------------------------------------------------------

replaceCases :: TestTree
replaceCases =
  testGroup
    "replaceTopic"
    [ testCase "rewrites the text with the current version, and keeps kind and links" $
        withOpsEnv $ \_ env -> do
          made env (name "kitchen/rota") "Cleaning is on Mondays."
          _ <- right =<< addUnderRef env oven ((note "The oven is 90 cm." []) {newKind = "preference", newAboutRefs = Set.singleton (name "kitchen/rota")})
          v <- versionOf env oven
          (_, m) <- right =<< replaceTopic env manifest "claude" oven v "The oven is 60 cm." Nothing
          memBody m @?= "The oven is 60 cm."
          memKind m @?= "preference"
          memAboutRefs m @?= Set.singleton (name "kitchen/rota"),
      testCase "links that are given replace the old links" $
        withOpsEnv $ \_ env -> do
          made env (name "kitchen/rota") "Cleaning is on Mondays."
          made env oven "The oven is 90 cm."
          v <- versionOf env oven
          (_, m) <- right =<< replaceTopic env manifest "claude" oven v "The oven is 60 cm." (Just (Set.singleton (name "kitchen/rota")))
          memAboutRefs m @?= Set.singleton (name "kitchen/rota"),
      testCase "a stale version is refused with the current version and text, and nothing is written" $
        withOpsEnv $ \_ env -> do
          made env oven "The oven is 90 cm."
          old <- versionOf env oven
          _ <- right =<< addToTopic env manifest "someone else" oven "It has a grill."
          now <- versionOf env oven
          before <- right =<< readRef env oven
          t <- refusal =<< replaceTopic env manifest "claude" oven old "A rewrite from old knowledge." Nothing
          assertBool "changed" ("changed since you read it" `T.isInfixOf` t)
          assertBool "current version" (now `T.isInfixOf` t)
          assertBool "current text" ("It has a grill." `T.isInfixOf` t)
          assertBool "no full id" (not ("sha256-" `T.isInfixOf` t))
          (right =<< readRef env oven) >>= (@?= before),
      testCase "a version that no topic ever had is a change, and shows the current text and no id" $
        withOpsEnv $ \_ env -> do
          made env oven "The oven is 90 cm."
          now <- versionOf env oven
          before <- right =<< readRef env oven
          t <- refusal =<< replaceTopic env manifest "claude" oven "000000000000" "New text." Nothing
          assertBool "changed" ("changed since you read it" `T.isInfixOf` t)
          assertBool "current version" (now `T.isInfixOf` t)
          assertBool "current text" ("The oven is 90 cm." `T.isInfixOf` t)
          assertBool "no id" (not ("sha256-" `T.isInfixOf` t))
          (right =<< readRef env oven) >>= (@?= before),
      testCase "a version that is too short is refused" $
        withOpsEnv $ \_ env -> do
          made env oven "The oven is 90 cm."
          t <- refusal =<< replaceTopic env manifest "claude" oven "0707" "New text." Nothing
          assertBool "digits" ("8 or more hex digits" `T.isInfixOf` t),
      testCase "a link to a ref that does not exist is refused and nothing is written" $
        withOpsEnv $ \_ env -> do
          made env oven "The oven is 90 cm."
          v <- versionOf env oven
          before <- right =<< readRef env oven
          _ <- refusal =<< replaceTopic env manifest "claude" oven v "New text." (Just (Set.singleton (name "nowhere/topic")))
          (right =<< readRef env oven) >>= (@?= before)
    ]

-- Logs -----------------------------------------------------------------

logCases :: TestTree
logCases =
  testGroup
    "logs are refused"
    [ testCase "a log that the manifest names, with one episode" $
        withOpsEnv $ \_ env -> do
          made env manifest "log *: me/log"
          _ <- right =<< appendEpisode env (name "me/log") (note "the first episode" [])
          forM_ [addToTopic env manifest "claude" (name "me/log") "x", reviseTopic env manifest "claude" (name "me/log") [Replace "first" "second"]] $ \act -> do
            t <- refusal =<< act
            assertBool "log" ("is a log" `T.isInfixOf` t)
            assertBool "note" ("note" `T.isInfixOf` t)
          textOf env (name "me/log") >>= (@?= "the first episode"),
      testCase "a log with two episodes, that the manifest does not name" $
        withOpsEnv $ \_ env -> do
          _ <- right =<< appendEpisode env (name "me/other") (note "the first episode" [])
          _ <- right =<< appendEpisode env (name "me/other") (note "the second episode" [])
          v <- versionOf env (name "me/other")
          t <- refusal =<< replaceTopic env manifest "claude" (name "me/other") v "A rewrite." Nothing
          assertBool "log" ("is a log" `T.isInfixOf` t)
          textOf env (name "me/other") >>= (@?= "the second episode"),
      testCase "a log of one episode that nothing names is a topic (a known limit)" $
        withOpsEnv $ \_ env -> do
          _ <- right =<< appendEpisode env (name "me/unnamed") (note "the only episode" [])
          _ <- right =<< addToTopic env manifest "claude" (name "me/unnamed") "A line."
          textOf env (name "me/unnamed") >>= (@?= "the only episode\nA line.")
    ]

-- recall ---------------------------------------------------------------

recallCases :: TestTree
recallCases =
  testGroup
    "recall"
    [ testCase "a topic shows the topics that it is about and that are about it" $
        withOpsEnv $ \_ env -> do
          made env oven "The oven is 90 cm."
          _ <- right =<< rememberTopic env (name "kitchen/shop") "claude" "fact" "Buy a grill pan." (Set.singleton oven)
          v <- right =<< recallTopic env oven
          tvMentionedBy v @?= [name "kitchen/shop"]
          tvAbout v @?= []
          w <- right =<< recallTopic env (name "kitchen/shop")
          tvAbout w @?= [oven],
      testCase "a topic that does not exist is an error with near names" $
        withOpsEnv $ \_ env -> do
          made env oven "The oven is 90 cm."
          t <- refusal =<< recallTopic env (name "kitchen/ovne")
          assertBool "near" ("kitchen/oven" `T.isInfixOf` t),
      testCase "a query finds the topic, and an old version becomes the current text" $
        withOpsEnv $ \_ env -> do
          made env oven "The lighthouse keeper wrote the first oven note."
          _ <- right =<< supersedeMemory env oven Nothing (note "The oven is 60 cm now, say the lighthouse keeper." [])
          es <- right =<< recallQuery env 5 "lighthouse"
          case es of
            [Entry (Just n) i m] -> do
              n @?= oven
              memBody m @?= "The oven is 60 cm now, say the lighthouse keeper."
              ref <- right =<< readRef env oven
              i @?= current ref
            other -> assertFailure (show other),
      testCase "a query with no hit gives no entries" $
        withOpsEnv $ \_ env -> do
          made env oven "The oven is 90 cm."
          recallQuery env 5 "zeppelin" >>= (@?= Right []),
      testCase "a memory that no ref holds has no topic" $
        withOpsEnv $ \_ env -> do
          _ <- right =<< appendEpisode env (name "me/log") (note "the lighthouse keeper arrived" [])
          _ <- right =<< appendEpisode env (name "me/log") (note "the weather was calm" [])
          es <- right =<< recallQuery env 5 "lighthouse"
          case es of
            [Entry Nothing _ m] -> memBody m @?= "the lighthouse keeper arrived"
            other -> assertFailure (show other),
      testCase "the limit applies to the entries" $
        withOpsEnv $ \_ env -> do
          forM_ [1 :: Int .. 4] $ \k -> made env (name ("notes/n" <> T.pack (show k))) ("A lighthouse story, number " <> T.pack (show k))
          es <- right =<< recallQuery env 2 "lighthouse"
          length es @?= 2
    ]

-- Concurrent writers ---------------------------------------------------

concurrentCases :: TestTree
concurrentCases =
  testGroup
    "concurrent writers"
    [ testCase "twenty add_to calls to one topic keep all twenty lines, and leave no spare memory" $
        withOpsEnv $ \_ env -> do
          made env oven "The oven."
          let lines' = ["line " <> T.pack (show k) | k <- [1 .. 20 :: Int]]
          results <- together [addToTopic env manifest "claude" oven l | l <- lines']
          forM_ results $ \r -> () <$ right r
          body <- textOf env oven
          Set.fromList (T.lines body) @?= Set.fromList ("The oven." : lines')
          length (T.lines body) @?= 21
          findings <- right =<< checkStore env defaultCheckOptions
          assertBool "no fork" (Fork `notElem` map findingKind findings)
          assertBool "no spare memory" (Unreferenced `notElem` map findingKind findings)
          report <- right =<< verifyStore env
          verifyOk report @?= True
          -- every memory in the store is the head or an ancestor of it: the
          -- 21 versions, and no object of a lost race
          heads <- right =<< listRefValues env
          length heads @?= 1,
      testCase "a revise and an add_to at once both take effect" $
        withOpsEnv $ \_ env -> do
          made env oven "The oven is 90 cm."
          rs <- together [() <$ (right =<< reviseTopic env manifest "claude" oven [Replace "90 cm" "60 cm"]), () <$ (right =<< addToTopic env manifest "claude" oven "It has a grill.")]
          rs @?= [(), ()]
          body <- textOf env oven
          assertBool "revised" ("60 cm" `T.isInfixOf` body)
          assertBool "added" ("It has a grill." `T.isInfixOf` body)
    ]
