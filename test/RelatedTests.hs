{-# LANGUAGE OverloadedStrings #-}

module RelatedTests (relatedTests) where

import Akyuu.Embed (Vector)
import Akyuu.Refs (Name, mkName, nameText)
import Akyuu.Related (Config (Config), Reason (Linked, Mentioned, SimilarText), Related (relName, relReason, relScore), Topic (Topic, rtLinks, rtName, rtText), defaultConfig, mentions, relatedLimit, relatedTo, similarityStats, topicVector)
import Control.Monad (forM)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, testCase, (@?=))
import Test.Tasty.QuickCheck (Gen, choose, conjoin, forAll, oneof, shuffle, sublistOf, testProperty, vectorOf, (===))

relatedTests :: TestTree
relatedTests =
  testGroup
    "Akyuu.Related"
    [ cosineCases,
      evidenceCases,
      mentionCases,
      siblingCases,
      vectorCases,
      propertyCases
    ]

-- Helpers --------------------------------------------------------------

name :: Text -> Name
name = either (error . show) id . mkName

-- A topic with a vector (or none), the topics its memory links to, and a text.
topic :: Text -> Maybe Vector -> [Text] -> Text -> Topic
topic n v links = Topic (name n) v (Set.fromList (map name links))

-- Change one topic of a list.
adjust :: Text -> (Topic -> Topic) -> [Topic] -> [Topic]
adjust n f = map (\t -> if rtName t == name n then f t else t)

-- Do these scores match, up to rounding?
closeTo :: [Double] -> [Double] -> Assertion
closeTo got want = do
  length got @?= length want
  mapM_ (\(g, w) -> assertBool (show g <> " is not " <> show w) (abs (g - w) < 1e-9)) (zip got want)

-- The list of related topics for one topic, with the statistics of all.
related :: Config -> [Topic] -> Text -> [Related]
related cfg ts = relatedWithout cfg [] ts

-- The same, with some topics left out.
relatedWithout :: Config -> [Text] -> [Topic] -> Text -> [Related]
relatedWithout cfg out ts n = relatedTo cfg (similarityStats ts) (Set.fromList (map name out)) (name n) ts

-- Their names and reasons.
shown :: [Related] -> [(Text, Reason)]
shown = map (\r -> (nameText (relName r), relReason r))

-- Five topics on a quarter circle and beyond. Seen from q, the cosine of a is
-- 0.95, of b 0.50, of c 0 and of d -1. Over all ten pairs the mean is about
-- 0.09 and the spread about 0.68, so q has a above the mean (z 1.3), b above
-- it (z 0.6), and c and d below it.
population :: [Topic]
population =
  [ topic "notes/q" (Just [1, 0]) [] "",
    topic "notes/a" (Just [0.95, 0.31]) [] "",
    topic "notes/b" (Just [0.5, 0.87]) [] "",
    topic "notes/c" (Just [0, 1]) [] "",
    topic "notes/d" (Just [-1, 0]) [] ""
  ]

-- Cosine ---------------------------------------------------------------

cosineCases :: TestTree
cosineCases =
  testGroup
    "cosine"
    [ testCase "the closest topic comes first, and a topic below the mean is left out" $
        shown (related defaultConfig population "notes/q")
          @?= [("notes/a", SimilarText), ("notes/b", SimilarText)],
      testCase "the topic itself never appears, and an unknown name gives nothing" $ do
        assertBool "self" ("notes/q" `notElem` map fst (shown (related defaultConfig population "notes/q")))
        related defaultConfig population "notes/nope" @?= [],
      testCase "one topic, or none, has nothing to be related to" $ do
        related defaultConfig [topic "notes/q" (Just [1, 0]) [] ""] "notes/q" @?= []
        related defaultConfig [] "notes/q" @?= [],
      testCase "equal vectors have no spread, so nothing stands out" $
        related defaultConfig [topic n (Just [1, 0]) [] "" | n <- ["notes/a", "notes/b", "notes/c"]] "notes/a" @?= [],
      testCase "with no spread a link still lists the topic" $
        shown
          ( related
              defaultConfig
              [topic "notes/a" (Just [1, 0]) ["notes/b"] "", topic "notes/b" (Just [1, 0]) [] "", topic "notes/c" (Just [1, 0]) [] ""]
              "notes/a"
          )
          @?= [("notes/b", Linked)],
      testCase "pair statistics preserve zero and mismatched vector semantics" $ do
        let ts =
              [ topic "notes/q" (Just [2, 0]) [] "",
                topic "notes/a" (Just [3, 0]) [] "",
                topic "notes/b" (Just [0, 4]) [] "",
                topic "notes/zero" (Just [0, 0]) [] "",
                topic "notes/short" (Just [1]) [] ""
              ]
            rs = related defaultConfig ts "notes/q"
        shown rs @?= [("notes/a", SimilarText)]
        closeTo (map relScore rs) [3],
      testCase "a topic that is left out is skipped" $
        shown (relatedWithout defaultConfig ["notes/a"] population "notes/q") @?= [("notes/b", SimilarText)],
      testCase "the limit counts what is left after the topics that are left out" $ do
        let near = [[0.99, 0.1], [0.98, 0.2], [0.97, 0.24], [0.96, 0.28]]
            far = [[-1, 0], [0, 1], [0, -1], [-0.7, 0.7]]
            ts =
              topic "notes/0" (Just [1, 0]) [] ""
                : [topic ("notes/n" <> T.pack (show i)) (Just v) [] "" | (i, v) <- zip [1 :: Int ..] near]
                  <> [topic ("notes/f" <> T.pack (show i)) (Just v) [] "" | (i, v) <- zip [1 :: Int ..] far]
        map fst (shown (relatedWithout defaultConfig ["notes/n1"] ts "notes/0")) @?= ["notes/n2", "notes/n3", "notes/n4"],
      testCase "a topic that is left out can still be the only one with evidence elsewhere" $ do
        let ts = [topic "notes/t" Nothing [] "", topic "notes/l" Nothing ["notes/t"] "", topic "notes/m" Nothing [] "see notes/t"]
        shown (relatedWithout defaultConfig ["notes/l"] ts "notes/t") @?= [("notes/m", Mentioned)],
      testCase "the list holds at most relatedLimit topics" $ do
        -- Four topics close to the first one, and four far from it that pull the mean down.
        let near = [[0.99, 0.1], [0.98, 0.2], [0.97, 0.24], [0.96, 0.28]]
            far = [[-1, 0], [0, 1], [0, -1], [-0.7, 0.7]]
            ts =
              topic "notes/0" (Just [1, 0]) [] ""
                : [topic ("notes/n" <> T.pack (show i)) (Just v) [] "" | (i, v) <- zip [1 :: Int ..] near]
                  <> [topic ("notes/f" <> T.pack (show i)) (Just v) [] "" | (i, v) <- zip [1 :: Int ..] far]
        map fst (shown (related defaultConfig ts "notes/0")) @?= ["notes/n1", "notes/n2", "notes/n3"]
        length (related defaultConfig ts "notes/0") @?= relatedLimit
    ]

-- Links and mentions -----------------------------------------------------

evidenceCases :: TestTree
evidenceCases =
  testGroup
    "links and mentions"
    [ testCase "a link outweighs a small cosine difference" $
        shown (related defaultConfig (adjust "notes/q" (\t -> t {rtLinks = Set.fromList [name "notes/b"]}) population) "notes/q")
          @?= [("notes/b", Linked), ("notes/a", SimilarText)],
      testCase "a link counts from either direction" $
        shown (related defaultConfig (adjust "notes/b" (\t -> t {rtLinks = Set.fromList [name "notes/q"]}) population) "notes/q")
          @?= [("notes/b", Linked), ("notes/a", SimilarText)],
      testCase "a link to a name that is not a topic is ignored" $
        shown (related defaultConfig (adjust "notes/q" (\t -> t {rtLinks = Set.fromList [name "notes/gone"]}) population) "notes/q")
          @?= [("notes/a", SimilarText), ("notes/b", SimilarText)],
      testCase "a source that links to many topics gives each link less" $ do
        let ts =
              [ topic "notes/t" Nothing [] "",
                topic "notes/s1" Nothing ["notes/t"] "",
                topic "notes/s2" Nothing ["notes/t", "notes/u", "notes/v"] "",
                topic "notes/u" Nothing [] "",
                topic "notes/v" Nothing [] ""
              ]
            rs = related defaultConfig ts "notes/t"
        map (nameText . relName) rs @?= ["notes/s1", "notes/s2"]
        map relScore rs `closeTo` [2, 2 / sqrt 3],
      testCase "a mention counts, and ranks below a link" $ do
        let ts = [topic "notes/t" Nothing [] "", topic "notes/m" Nothing [] "see notes/t", topic "notes/l" Nothing ["notes/t"] ""]
        shown (related defaultConfig ts "notes/t") @?= [("notes/l", Linked), ("notes/m", Mentioned)],
      testCase "a mention counts from either direction" $ do
        let ts = [topic "notes/t" Nothing [] "see notes/m", topic "notes/m" Nothing [] ""]
        shown (related defaultConfig ts "notes/t") @?= [("notes/m", Mentioned)]
        shown (related defaultConfig ts "notes/m") @?= [("notes/t", Mentioned)],
      testCase "a topic with a link and a mention is listed as linked" $ do
        let ts = [topic "notes/t" Nothing [] "", topic "notes/x" Nothing ["notes/t"] "also notes/t"]
        map relReason (related defaultConfig ts "notes/t") @?= [Linked]
        map relScore (related defaultConfig ts "notes/t") `closeTo` [3],
      testCase "a topic that mentions many topics gives each mention less" $ do
        let ts =
              [ topic "notes/t" Nothing [] "",
                topic "notes/m1" Nothing [] "notes/t",
                topic "notes/m2" Nothing [] "notes/t notes/u notes/v",
                topic "notes/u" Nothing [] "",
                topic "notes/v" Nothing [] ""
              ]
            rs = related defaultConfig ts "notes/t"
        map (nameText . relName) rs @?= ["notes/m1", "notes/m2"]
        map relScore rs `closeTo` [1, 1 / sqrt 3],
      testCase "without vectors only linked or mentioned topics are listed" $ do
        let ts = [topic "notes/a" Nothing [] "", topic "notes/b" Nothing [] "about notes/a", topic "notes/c" Nothing [] ""]
        shown (related defaultConfig ts "notes/a") @?= [("notes/b", Mentioned)]
        related defaultConfig ts "notes/c" @?= [],
      testCase "equal scores break by name, whatever the order of the topics" $ do
        let ts = [topic "notes/a" Nothing [] "", topic "notes/z" Nothing ["notes/a"] "", topic "notes/y" Nothing ["notes/a"] ""]
        map fst (shown (related defaultConfig ts "notes/a")) @?= ["notes/y", "notes/z"]
        map fst (shown (related defaultConfig (reverse ts) "notes/a")) @?= ["notes/y", "notes/z"]
    ]

-- The name of a topic in a text --------------------------------------------

mentionCases :: TestTree
mentionCases =
  testGroup
    "mentions"
    [ testCase "the whole name counts" $
        mapM_
          (\t -> assertBool (T.unpack t) (mentions oven t))
          [ "see kitchen/oven for heat",
            "kitchen/oven",
            "(kitchen/oven)",
            "It is in kitchen/oven.",
            "kitchen/oven, and more",
            "kitchen/oven's lid",
            "first kitchen/oven2 then kitchen/oven again"
          ],
      testCase "a longer name or path that contains it does not count" $
        mapM_
          (\t -> assertBool (T.unpack t) (not (mentions oven t)))
          [ "kitchen/oven2",
            "kitchen/ovens",
            "home/kitchen/oven",
            "my-kitchen/oven",
            "kitchen/oven/door",
            "kitchen/oven.l1",
            "nothing here",
            ""
          ]
    ]
  where
    oven = name "kitchen/oven"

-- Namespaces of parallel instances ---------------------------------------

-- The population of the cosine cases, with the first two topics under a
-- namespace of projects.
projects :: [Topic]
projects =
  [ topic "p/projects/q" (Just [1, 0]) [] "",
    topic "p/projects/a" (Just [0.95, 0.31]) [] "",
    topic "g/b" (Just [0.5, 0.87]) [] "",
    topic "g/c" (Just [0, 1]) [] "",
    topic "g/d" (Just [-1, 0]) [] ""
  ]

siblingCases :: TestTree
siblingCases =
  testGroup
    "parallel namespaces"
    [ testCase "by default siblings are ranked like any other topics" $
        shown (related defaultConfig projects "p/projects/q")
          @?= [("p/projects/a", SimilarText), ("g/b", SimilarText)],
      testCase "a listed namespace needs evidence for siblings" $
        shown (related parallel projects "p/projects/q") @?= [("g/b", SimilarText)],
      testCase "a high cosine z-score cannot bypass the sibling evidence requirement" $ do
        let basis i = [if i == j then 1 else 0 | j <- [0 .. 8 :: Int]]
            ts =
              [ topic "p/projects/q" (Just (basis 0)) [] "",
                topic "p/projects/a" (Just (basis 0)) [] ""
              ]
                <> [topic ("other/t" <> T.pack (show i)) (Just (basis i)) [] "" | i <- [1 .. 8]]
        shown (related defaultConfig ts "p/projects/q") @?= [("p/projects/a", SimilarText)]
        related parallel ts "p/projects/q" @?= [],
      testCase "a link qualifies a parallel sibling" $
        shown (related parallel (adjust "p/projects/q" (\t -> t {rtLinks = Set.fromList [name "p/projects/a"]}) projects) "p/projects/q")
          @?= [("p/projects/a", Linked), ("g/b", SimilarText)],
      testCase "a mention qualifies a parallel sibling" $
        shown (related parallel (adjust "p/projects/a" (\t -> t {rtText = "builds on p/projects/q"}) projects) "p/projects/q")
          @?= [("p/projects/a", Mentioned), ("g/b", SimilarText)],
      testCase "a namespace that is not listed changes nothing" $
        related (Config ["other/ns"]) projects "p/projects/q" @?= related defaultConfig projects "p/projects/q",
      testCase "a pair from two namespaces is not a pair of siblings" $
        related parallel projects "g/b" @?= related defaultConfig projects "g/b"
    ]
  where
    parallel = Config ["p/projects"]

-- The vector of a topic ---------------------------------------------------

vectorCases :: TestTree
vectorCases =
  testGroup
    "topicVector"
    [ testCase "it is the mean of the unit vectors of the chunks" $
        topicVector [[2, 0], [0, 3]] @?= Just [0.5, 0.5],
      testCase "no chunk gives nothing" $
        topicVector [] @?= Nothing,
      testCase "a chunk of zeros is left out" $ do
        topicVector [[0, 0]] @?= Nothing
        topicVector [[0, 0], [3, 0]] @?= Just [1, 0],
      testCase "a chunk of another length is left out" $
        topicVector [[1, 0], [0, 1, 0]] @?= Just [1, 0]
    ]

-- Properties ------------------------------------------------------------------

-- Two to seven topics, some with a vector, with random links and mentions.
genTopics :: Gen [Topic]
genTopics = do
  n <- choose (2, 7 :: Int)
  let ns = [name ("t/" <> T.pack (show i)) | i <- [1 .. n]]
  forM ns $ \nm -> do
    v <- oneof [pure Nothing, Just <$> vectorOf 3 (choose (-1, 1))]
    links <- Set.fromList <$> sublistOf ns
    said <- sublistOf ns
    pure (Topic nm v links (T.unwords (map nameText said)))

propertyCases :: TestTree
propertyCases =
  testGroup
    "properties"
    [ testProperty "at most relatedLimit topics, never the topic itself, best first, all above zero" $
        forAll genTopics $ \ts ->
          conjoin
            [ let rs = relatedTo defaultConfig (similarityStats ts) Set.empty (nameOf t) ts
               in conjoin
                    [ assertBool' (length rs <= relatedLimit),
                      assertBool' (nameOf t `notElem` map relName rs),
                      assertBool' (all ((> 0) . relScore) rs),
                      assertBool' (and (zipWith (>=) (map relScore rs) (drop 1 (map relScore rs))))
                    ]
            | t <- ts
            ],
      testProperty "the order of the topics does not change the result" $
        forAll genTopics $ \ts ->
          forAll (shuffle ts) $ \ts' ->
            conjoin
              [ shown (relatedTo defaultConfig (similarityStats ts) Set.empty (nameOf t) ts)
                  === shown (relatedTo defaultConfig (similarityStats ts') Set.empty (nameOf t) ts')
              | t <- ts
              ]
    ]
  where
    nameOf = rtName
    assertBool' b = b === True
