{-# LANGUAGE OverloadedStrings #-}

module TopicTests (topicTests) where

import Akyuu.Amend (Edit (Replace))
import Akyuu.Graph (Edge (Edge), EdgeType (DerivedFrom, Follows))
import Akyuu.Id (render)
import Akyuu.Memory (Memory)
import Akyuu.Refs (Name, mkName)
import Akyuu.Topic (Entry (Entry), changedLines, closeTopics, cutText, isLogTopic, noMatch, renderAdded, renderEntry, renderMade, renderNoted, renderReplaced, renderRevised, renderTopic, suggestNames, tokenPrefix, versionToken)
import Data.Either (isLeft)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import Support (nid, testMemory)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

topicTests :: TestTree
topicTests =
  testGroup
    "Akyuu.Topic"
    [ logCases,
      versionCases,
      nearCases,
      showCases,
      answerCases
    ]

-- Helpers --------------------------------------------------------------

name :: Text -> Name
name = either (error . show) id . mkName

-- A fact with these edges and this body. Everything else is fixed.
mem :: [Edge] -> Text -> Memory
mem es = testMemory "fact" (posixSecondsToUTCTime 1791201600) "claude" (Set.fromList es)

-- Logs -----------------------------------------------------------------

logCases :: TestTree
logCases =
  testGroup
    "isLogTopic"
    [ testCase "a memory with a follows edge is a log" $
        isLogTopic [] (name "me/anything") (mem [Edge Follows (nid 1)] "an episode") @?= True,
      testCase "a ref that the manifest names is a log, even with one episode" $
        isLogTopic [name "me/log"] (name "me/log") (mem [] "the first episode") @?= True,
      testCase "the summary levels of a log are logs" $ do
        isLogTopic [] (name "me/log.l1") (mem [] "a summary") @?= True
        isLogTopic [] (name "me/log.l12") (mem [] "a summary") @?= True,
      testCase "a name that only looks like a level is not a log" $ do
        isLogTopic [] (name "me/log.l") (mem [] "x") @?= False
        isLogTopic [] (name "me/notes.lx") (mem [] "x") @?= False,
      testCase "a plain fact is not a log" $
        isLogTopic [name "me/log"] (name "me/oven") (mem [] "the oven is 90 cm") @?= False,
      testCase "a fact with one evidence link is not a log" $
        isLogTopic [] (name "me/oven") (mem [Edge DerivedFrom (nid 1)] "the oven is 90 cm") @?= False,
      testCase "a log of one episode that nothing names is not found (a known limit)" $
        isLogTopic [name "me/log"] (name "me/other-log") (mem [] "the first episode") @?= False
    ]

-- Versions -------------------------------------------------------------

versionCases :: TestTree
versionCases =
  testGroup
    "versions"
    [ testCase "a version is 12 hex digits, with no sha256- prefix" $ do
        T.length (versionToken (nid 7)) @?= 12
        assertBool "no prefix" (not ("sha256" `T.isInfixOf` versionToken (nid 7))),
      testCase "the start of an id comes back from its version" $
        tokenPrefix (versionToken (nid 7)) @?= Right (T.take 19 (render (nid 7))),
      testCase "a version with 8 digits is enough" $
        tokenPrefix "0707070707" @?= Right "sha256-0707070707",
      testCase "a version with fewer than 8 digits is refused" $
        assertBool "short" (isLeft (tokenPrefix "0707070")),
      testCase "a version that is not hex is refused" $
        assertBool "not hex" (isLeft (tokenPrefix "07070707zz")),
      testCase "white space, upper case and the prefix are accepted" $ do
        tokenPrefix "  0A0B0C0D0E  " @?= Right "sha256-0a0b0c0d0e"
        tokenPrefix "sha256-0a0b0c0d0e" @?= Right "sha256-0a0b0c0d0e"
    ]

-- Near topics and names ------------------------------------------------

nearCases :: TestTree
nearCases =
  testGroup
    "near topics and names"
    [ testCase "a topic with much of the same text is close" $
        closeTopics oven [(name "kitchen/oven", oven <> " It was bought in 2020."), (name "kitchen/rota", "Cleaning is on Mondays and Thursdays for everyone.")]
          @?= [name "kitchen/oven"],
      testCase "nothing is close to an unrelated text" $
        closeTopics oven [(name "kitchen/rota", "Cleaning is on Mondays and Thursdays for everyone.")] @?= [],
      testCase "the closest topic comes first, and at most three are shown" $
        closeTopics oven [(name "a/far", oven <> " One. Two. Three. Four. Five. Six."), (name "a/near", oven <> " One."), (name "a/same", oven), (name "a/extra", oven <> " Seven. Eight. Nine. Ten.")]
          @?= [name "a/same", name "a/near", name "a/extra"],
      testCase "a name with a typo gets the name that was meant" $
        suggestNames (name "kitchen/ovne") [name "kitchen/oven", name "kitchen/rota", name "garden/tomatoes"] @?= [name "kitchen/oven"],
      testCase "the name itself and far names are not suggested" $
        suggestNames (name "kitchen/oven") [name "kitchen/oven", name "garden/tomatoes"] @?= []
    ]
  where
    oven = "The oven in the kitchen is the 90 cm model from Harwell."

-- Showing a topic ------------------------------------------------------

showCases :: TestTree
showCases =
  testGroup
    "showing a topic"
    [ testCase "cutText leaves a short text alone" $
        cutText 20 "a short text" @?= ("a short text", False),
      testCase "cutText cuts at a space near the end" $
        cutText 14 "one two three four" @?= ("one two three", True),
      testCase "cutText cuts a long word where it is" $
        cutText 5 "abcdefghijkl mno" @?= ("abcde", True),
      testCase "an entry shows its topic, kind, author and the text" $ do
        let t = renderEntry 100 (Entry (Just (name "kitchen/oven")) (mem [] "The oven is 90 cm."))
        assertBool "topic" ("topic kitchen/oven (fact, by claude, 2026-10-05 12:00Z)" `T.isPrefixOf` t)
        assertBool "text" ("The oven is 90 cm." `T.isInfixOf` t)
        assertBool "no cut hint" (not ("[cut" `T.isInfixOf` t)),
      testCase "a cut entry says how to read the whole topic" $ do
        let t = renderEntry 10 (Entry (Just (name "kitchen/oven")) (mem [] "The oven in the kitchen is 90 cm wide."))
        assertBool "hint" ("[cut: call recall with topic kitchen/oven to read the whole text]" `T.isSuffixOf` t),
      testCase "an entry that no topic holds says so, and has no hint" $ do
        let t = renderEntry 10 (Entry Nothing (mem [] "The oven in the kitchen is 90 cm wide."))
        assertBool "loose" ("not held by a topic" `T.isPrefixOf` t)
        assertBool "no hint" (not ("[cut" `T.isInfixOf` t)),
      testCase "a topic shows its version, text and links, and no full id" $ do
        let t = renderTopic (name "kitchen/oven") (nid 7) (mem [] "The oven is 90 cm.\n") [name "kitchen/rota"] [name "garden/plan", name "kitchen/shop"]
        T.lines t
          @?= [ "topic kitchen/oven",
                "version: " <> versionToken (nid 7),
                "fact, by claude, 2026-10-05 12:00Z",
                "",
                "The oven is 90 cm.",
                "",
                "about: kitchen/rota",
                "mentioned by: garden/plan, kitchen/shop"
              ]
        assertBool "no sha256-" (not ("sha256-" `T.isInfixOf` t)),
      testCase "a topic with no links shows no link lines" $ do
        let t = renderTopic (name "kitchen/oven") (nid 7) (mem [] "The oven is 90 cm.") [] []
        assertBool "no about" (not ("about:" `T.isInfixOf` t))
        assertBool "no mentions" (not ("mentioned by:" `T.isInfixOf` t)),
      testCase "noMatch is a sentence, not an empty text" $
        assertBool "text" (not (T.null noMatch))
    ]

-- Answers of the writers -----------------------------------------------

answerCases :: TestTree
answerCases =
  testGroup
    "answers of the writers"
    [ testCase "made shows the topic and the version, and the close topics if there are any" $ do
        renderMade oven (nid 7) [] @?= "Made topic kitchen/oven.\nversion: " <> versionToken (nid 7)
        renderMade oven (nid 7) [name "kitchen/rota", name "kitchen/shop"]
          @?= "Made topic kitchen/oven.\nversion: " <> versionToken (nid 7) <> "\nTopics with similar text, in case this repeats one: kitchen/rota, kitchen/shop.",
      testCase "added and replaced show the version" $ do
        renderAdded oven (nid 7) @?= "Added to topic kitchen/oven.\nversion: " <> versionToken (nid 7)
        renderReplaced oven (nid 7) @?= "Replaced the text of topic kitchen/oven.\nversion: " <> versionToken (nid 7),
      testCase "revised shows the changed lines, or none" $ do
        renderRevised oven (nid 7) ["The oven is 60 cm."]
          @?= "Revised topic kitchen/oven. The changed lines now read:\nThe oven is 60 cm.\nversion: " <> versionToken (nid 7)
        renderRevised oven (nid 7) [] @?= "Revised topic kitchen/oven.\nversion: " <> versionToken (nid 7),
      testCase "noted names the log and no memory" $
        renderNoted (name "me/log") @?= "Noted in me/log.",
      testCase "changedLines picks the lines that hold the new text, each once" $
        changedLines [Replace "90" "60 cm"] "The oven is 60 cm.\nIt has a grill.\nThe oven is 60 cm.\nA 60 cm door."
          @?= ["The oven is 60 cm.", "A 60 cm door."],
      testCase "changedLines shows nothing for a deletion" $
        changedLines [Replace "grill" ""] "The oven is 60 cm." @?= [],
      testCase "no answer has a full id" $
        assertBool "no sha256-" (not ("sha256-" `T.isInfixOf` T.concat [renderMade oven (nid 7) [], renderAdded oven (nid 7), renderReplaced oven (nid 7), renderRevised oven (nid 7) []]))
    ]
  where
    oven = name "kitchen/oven"
