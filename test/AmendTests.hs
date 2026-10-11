{-# LANGUAGE OverloadedStrings #-}

module AmendTests (amendTests) where

import Akyuu.Amend (AmendError (EmptyFrom, MoreThanOnce, NoEdits, NotInBody), Edit (Append, Replace), applyEdits)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

amendTests :: TestTree
amendTests =
  testGroup
    "Akyuu.Amend"
    [ testCase "a replacement changes one place" $
        applyEdits [Replace "tea" "coffee"] "Lilly likes tea." @?= Right "Lilly likes coffee.",
      testCase "a text that is not there is an error" $
        applyEdits [Replace "milk" "oat"] "Lilly likes tea." @?= Left (NotInBody "milk"),
      testCase "a text that occurs twice is an error" $
        applyEdits [Replace "x" "b"] "x and x" @?= Left (MoreThanOnce "x" 2),
      testCase "an empty text to replace is an error" $
        applyEdits [Replace "" "b"] "a" @?= Left EmptyFrom,
      testCase "append starts a new line, and does not double a line feed" $ do
        applyEdits [Append "more"] "one" @?= Right "one\nmore"
        applyEdits [Append "more"] "one\n" @?= Right "one\nmore",
      testCase "edits apply in order" $
        applyEdits [Replace "a" "b", Replace "b" "c"] "a" @?= Right "c",
      testCase "no edits is an error" $
        applyEdits [] "a" @?= Left NoEdits
    ]
