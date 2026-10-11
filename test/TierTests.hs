{-# LANGUAGE OverloadedStrings #-}

module TierTests (tierTests) where

import Akyuu.Refs (NameError (BadSegment), mkName)
import Akyuu.Tier (Place (Place), TierError (BadTierName, BadTierRef, NoColon), parseManifest, placeLog, placeRefs, tierNames, tierRefs)
import Data.Either (isLeft)
import Support (right)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

tierTests :: TestTree
tierTests =
  testGroup
    "Akyuu.Tier"
    [ testCase "reads a tier with refs separated by spaces or commas" $ do
        m <- right (parseManifest "always: a/x b/y, c/z\n")
        a <- right (mkName "a/x")
        b <- right (mkName "b/y")
        c <- right (mkName "c/z")
        tierRefs "always" m @?= Just [a, b, c],
      testCase "skips comments and blank lines" $ do
        m <- right (parseManifest "# the always tier\n\n   \nalways: a/x\n  # more\n")
        tierNames m @?= ["always"],
      testCase "a tier on two lines is one tier, in order, with a ref once" $ do
        m <- right (parseManifest "always: a/x b/y\nalways: b/y c/z\nlater: d/w\n")
        Just rs <- pure (tierRefs "always" m)
        length rs @?= 3
        tierNames m @?= ["always", "later"],
      testCase "an unknown tier is Nothing" $ do
        m <- right (parseManifest "always: a/x\n")
        tierRefs "other" m @?= Nothing,
      testCase "a line with no colon is refused, with its number" $
        parseManifest "always: a/x\nnonsense\n" @?= Left (NoColon 2 "nonsense"),
      testCase "an empty tier name is refused" $
        parseManifest ": a/x" @?= Left (BadTierName 1 ""),
      testCase "a bad ref name is refused" $
        assertBool "bad ref" (isLeft (parseManifest "always: Not_A_Name!\n")),
      testCase "at lines add refs for a directory and the ones below it" $ do
        m <- right (parseManifest "always: a/x\nat ~/devel/akyuu: p/akyuu\nat /srv: p/srv p/more\n")
        pa <- right (mkName "p/akyuu")
        let home = "/Users/l"
        placeRefs (Place home "/Users/l/devel/akyuu") m @?= [pa]
        placeRefs (Place home "/Users/l/devel/akyuu/src/") m @?= [pa]
        placeRefs (Place home "/Users/l/devel/akyuu2") m @?= []
        length (placeRefs (Place home "/srv") m) @?= 2
        tierNames m @?= ["always"],
      testCase "the most specific log line wins, and * is the default" $ do
        m <- right (parseManifest "log *: l/general\nlog ~/devel: l/devel\nlog ~/devel/akyuu: l/akyuu\n")
        a <- right (mkName "l/akyuu")
        d <- right (mkName "l/devel")
        g <- right (mkName "l/general")
        let home = "/h"
        placeLog (Place home "/h/devel/akyuu/src") m @?= Just a
        placeLog (Place home "/h/devel/other") m @?= Just d
        placeLog (Place home "/tmp") m @?= Just g
        placeLog (Place home "/tmp") <$> right (parseManifest "always: a/x") >>= (@?= Nothing),
      testCase "a log line needs exactly one ref" $
        assertBool "refused" (isLeft (parseManifest "log /x: a/b c/d\n")),
      testCase "the error names the ref and the line" $
        case parseManifest "ok: a/x\nalways: a/UPPER\n" of
          Left (BadTierRef 2 "a/UPPER" (BadSegment _)) -> pure ()
          other -> assertBool ("unexpected: " <> show other) False
    ]
