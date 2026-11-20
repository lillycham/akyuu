module DisabledTests (disabledTests) where

import Akyuu.Disabled (isDisabled, markerPath, setDisabled)
import Support (withTempDir)
import System.Directory (doesFileExist)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

disabledTests :: TestTree
disabledTests =
  testGroup
    "Akyuu.Disabled"
    [ testCase "off by default with no marker file" $
        withTempDir $ \dir -> do
          d0 <- isDisabled Nothing
          d1 <- isDisabled (Just dir)
          d0 @?= False
          d1 @?= False,
      testCase "setDisabled writes and removes the marker file" $
        withTempDir $ \dir -> do
          setDisabled dir True
          assertBool "marker exists" =<< doesFileExist (markerPath dir)
          dOn <- isDisabled (Just dir)
          dOn @?= True
          setDisabled dir False
          assertBool "marker removed" . not =<< doesFileExist (markerPath dir)
          dOff <- isDisabled (Just dir)
          dOff @?= False,
      testCase "setDisabled False is idempotent when marker is absent" $
        withTempDir $ \dir -> do
          setDisabled dir False
          d <- isDisabled (Just dir)
          d @?= False
    ]
