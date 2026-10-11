{-# LANGUAGE OverloadedStrings #-}

module CompareTests (compareTests) where

import Akyuu.Compare (Comparison (cmpOnlyA, cmpOnlyB, cmpShared), canDropA, canDropB, compareText, sentences)
import Data.Text qualified as T
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))
import Test.Tasty.QuickCheck (testProperty, (===))

compareTests :: TestTree
compareTests =
  testGroup
    "Akyuu.Compare"
    [ testCase "a text is cut at the end of a sentence and at a line" $
        sentences "One is here. Two is here! Three?\nFour has no stop" @?= ["One is here.", "Two is here!", "Three?", "Four has no stop"],
      testCase "a full stop inside a number does not end a sentence" $
        sentences "Version 3.5 is out. Done." @?= ["Version 3.5 is out.", "Done."],
      testCase "blank lines give no sentence" $
        sentences "\n  \nA.\n\n" @?= ["A."],
      testCase "equal texts have nothing of their own, and can be dropped both ways" $ do
        let c = compareText "Same text. Here." "Same   TEXT.\nHere."
        (cmpOnlyA c, cmpOnlyB c, canDropA c, canDropB c) @?= ([], [], True, True)
        cmpShared c @?= 1,
      testCase "one more sentence is shown, and the shorter one can be dropped" $ do
        let c = compareText "The port is private. Do not commit game data." "The port is private."
        cmpOnlyA c @?= ["Do not commit game data."]
        cmpOnlyB c @?= []
        (canDropA c, canDropB c) @?= (False, True),
      testCase "the order of the sentences does not matter" $ do
        let c = compareText "A one. B two." "B two. A one."
        (cmpOnlyA c, cmpOnlyB c) @?= ([], []),
      testCase "each side can have its own sentence" $ do
        let c = compareText "Shared. Mine." "Shared. Yours."
        (cmpOnlyA c, cmpOnlyB c, canDropA c, canDropB c) @?= (["Mine."], ["Yours."], False, False),
      testCase "a repeated sentence is shown once" $
        cmpOnlyA (compareText "Dup. Dup. Dup." "Other.") @?= ["Dup."],
      testProperty "a text compared with itself has nothing of its own" $ \s ->
        let t = T.pack s
            c = compareText t t
         in (cmpOnlyA c, cmpOnlyB c) === ([], [])
    ]
