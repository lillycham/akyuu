{-# LANGUAGE OverloadedStrings #-}

module MemoryTests (memoryTests, genMemory, shrinkMemory) where

import Akyuu.Graph (Edge (Edge, kind, target), EdgeType (About, DerivedFrom, Refines, Supersedes))
import Akyuu.Graph qualified as Graph
import Akyuu.Id (Id, IdParseError (BadLength, BadPrefix), fromDigest, hashBytes)
import Akyuu.Id qualified as Id
import Akyuu.Memory (Memory (memBody, memCreated, memEdges), MemoryError (InvalidField), MemoryParseError (BadEncoding, BadHeaderValue, BadLink, DuplicateHeader, MalformedHeader, MissingBlankLine, MissingHeader, NotCanonical, UnknownHeader), memoryGraph, memoryId, mkMemory, parseMemory, renderMemory, validField)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Maybe (fromMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (UTCTime)
import Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import Support (testMemory)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))
import Test.Tasty.QuickCheck (Arbitrary (arbitrary, shrink), Gen, Property, Testable, choose, conjoin, elements, forAll, forAllShrink, listOf, listOf1, oneof, shrinkList, shuffle, testProperty, (=/=), (===), (==>))

memoryTests :: TestTree
memoryTests =
  testGroup
    "Akyuu.Memory"
    [ renderTests,
      parseTests,
      errorTests,
      identityTests,
      properties
    ]

-- Six Ids, as in the graph tests, so that edges often share a target.
nid :: Int -> Id
nid n = fromMaybe (error "nid: not 32 bytes") (fromDigest (BS.replicate 32 (fromIntegral n)))

idText :: Int -> Text
idText = Id.render . nid

-- 2026-10-05T12:00:00Z
noon :: UTCTime
noon = posixSecondsToUTCTime 1791201600

-- The memory of the examples. It has edges of two kinds, and nothing else.
fixture :: Memory
fixture =
  testMemory "fact" noon "claude" (Set.fromList [Edge About (nid 2), Edge Supersedes (nid 1)]) "Lilly prefers worktrees.\n"

-- The canonical form of 'fixture', written by hand.
fixtureFile :: Text
fixtureFile =
  T.unlines
    [ "kind: fact",
      "created: 2026-10-05T12:00:00Z",
      "agent: claude",
      "supersedes: " <> idText 1,
      "about: " <> idText 2,
      ""
    ]
    <> "Lilly prefers worktrees.\n"

bytes :: Text -> ByteString
bytes = TE.encodeUtf8

-- A file with the headers of 'fixtureFile', and a line list for each test.
file :: [Text] -> ByteString
file hs = bytes (T.unlines hs <> "\nbody\n")

-- The three required headers.
required :: [Text]
required = ["kind: fact", "created: 2026-10-05T12:00:00Z", "agent: claude"]

renderTests :: TestTree
renderTests =
  testGroup
    "renderMemory"
    [ testCase "writes the canonical form of a memory" $
        renderMemory fixture @?= bytes fixtureFile,
      testCase "writes the edge headers in the order of the edge kinds" $
        let m =
              fixture
                { memEdges =
                    Set.fromList
                      [ Edge Refines (nid 0),
                        Edge DerivedFrom (nid 0),
                        Edge About (nid 0),
                        Edge Supersedes (nid 0)
                      ]
                }
         in map (T.takeWhile (/= ':')) (take 4 (drop 3 (T.lines (TE.decodeUtf8 (renderMemory m)))))
              @?= ["supersedes", "about", "derived-from", "refines"],
      testCase "writes the Ids of one kind in ascending order" $
        let m = fixture {memEdges = Set.fromList [Edge About (nid 3), Edge About (nid 1), Edge About (nid 2)]}
         in drop 3 (take 6 (T.lines (TE.decodeUtf8 (renderMemory m))))
              @?= ["about: " <> idText n | n <- [1, 2, 3]],
      testCase "writes the blank line when there are no edges" $
        renderMemory fixture {memEdges = Set.empty, memBody = "b"}
          @?= bytes "kind: fact\ncreated: 2026-10-05T12:00:00Z\nagent: claude\n\nb",
      testCase "writes an empty body as nothing after the blank line" $
        renderMemory fixture {memEdges = Set.empty, memBody = ""}
          @?= bytes "kind: fact\ncreated: 2026-10-05T12:00:00Z\nagent: claude\n\n",
      testCase "does not add a line feed to the body" $
        BS.takeEnd 4 (renderMemory fixture {memBody = "end"}) @?= "\nend",
      testCase "keeps whole seconds only" $
        renderMemory fixture {memCreated = posixSecondsToUTCTime 1791201600.75}
          @?= renderMemory fixture,
      testCase "writes the body as UTF-8" $
        BS.isSuffixOf (TE.encodeUtf8 "caf\233 \9731\n") (renderMemory fixture {memBody = "caf\233 \9731\n"})
          @?= True
    ]

parseTests :: TestTree
parseTests =
  testGroup
    "parseMemory"
    [ testCase "reads the canonical form of a memory" $
        parseMemory (bytes fixtureFile) @?= Right fixture,
      testCase "rejects the headers in another order" $
        parseMemory
          ( file
              [ "agent: claude",
                "about: " <> idText 2,
                "created: 2026-10-05T12:00:00Z",
                "supersedes: " <> idText 1,
                "kind: fact"
              ]
          )
          @?= Left NotCanonical,
      testCase "collects the lines of a repeated edge header" $
        fmap memEdges (parseMemory (file (required ++ ["about: " <> idText 1, "about: " <> idText 2])))
          @?= Right (Set.fromList [Edge About (nid 1), Edge About (nid 2)]),
      testCase "rejects two equal edge lines, because the canonical form has one" $
        parseMemory (file (required ++ ["about: " <> idText 1, "about: " <> idText 1]))
          @?= Left NotCanonical,
      testCase "rejects edge lines that are not in order" $
        parseMemory (file (required ++ ["about: " <> idText 2, "about: " <> idText 1]))
          @?= Left NotCanonical,
      testCase "mkMemory accepts a valid memory" $
        mkMemory "fact" noon "claude" Set.empty "b" @?= Right (testMemory "fact" noon "claude" Set.empty "b"),
      testCase "mkMemory refuses an empty, padded or multi-line kind or agent" $ do
        mkMemory "" noon "claude" Set.empty "" @?= Left (InvalidField "kind" "")
        mkMemory " fact" noon "claude" Set.empty "" @?= Left (InvalidField "kind" " fact")
        mkMemory "fact" noon "a\nb" Set.empty "" @?= Left (InvalidField "agent" "a\nb")
        mkMemory "fact" noon "claude " Set.empty "" @?= Left (InvalidField "agent" "claude ")
        mkMemory "fact" noon "a\rb" Set.empty "" @?= Left (InvalidField "agent" "a\rb"),
      testCase "mkMemory cuts the time to whole seconds" $
        fmap memCreated (mkMemory "fact" (posixSecondsToUTCTime 1791201600.75) "claude" Set.empty "")
          @?= Right noon,
      testCase "a value that has a space inside is valid" $
        (validField "a b", validField "", validField " a", validField "a ") @?= (True, False, False, False),
      testCase "parseMemory refuses a kind with a space at the start" $
        parseMemory (file ["kind:  fact", "created: 2026-10-05T12:00:00Z", "agent: claude"])
          @?= Left (BadHeaderValue "kind" " fact"),
      testCase "reads the four kinds of edge" $
        fmap
          memEdges
          ( parseMemory
              ( file
                  ( required
                      ++ [ "supersedes: " <> idText 0,
                           "about: " <> idText 1,
                           "derived-from: " <> idText 2,
                           "refines: " <> idText 3
                         ]
                  )
              )
          )
          @?= Right (Set.fromList [Edge Supersedes (nid 0), Edge About (nid 1), Edge DerivedFrom (nid 2), Edge Refines (nid 3)]),
      testCase "reads an empty body" $
        fmap memBody (parseMemory (bytes (T.unlines required <> "\n"))) @?= Right "",
      testCase "ends the headers at the first blank line only" $
        fmap memBody (parseMemory (bytes (T.unlines required <> "\nfirst\n\nkind: not a header\n\nlast")))
          @?= Right "first\n\nkind: not a header\n\nlast",
      testCase "does not change the body" $
        fmap memBody (parseMemory (bytes (T.unlines required <> "\n  indented \n\n\n")))
          @?= Right "  indented \n\n\n",
      testCase "reads a body in UTF-8" $
        fmap memBody (parseMemory (bytes (T.unlines required <> "\ncaf\233 \9731")))
          @?= Right "caf\233 \9731"
    ]

errorTests :: TestTree
errorTests =
  testGroup
    "parse errors"
    [ testCase "a file that is not UTF-8" $
        parseMemory (BS.pack [0xff, 0xfe, 0x0a, 0x0a]) @?= Left BadEncoding,
      testCase "no blank line after the headers" $
        parseMemory (bytes (T.unlines required)) @?= Left MissingBlankLine,
      testCase "no kind header" $
        parseMemory (file (drop 1 required)) @?= Left (MissingHeader "kind"),
      testCase "no created header" $
        parseMemory (file (take 1 required ++ drop 2 required)) @?= Left (MissingHeader "created"),
      testCase "no agent header" $
        parseMemory (file (take 2 required)) @?= Left (MissingHeader "agent"),
      testCase "a repeated required header" $
        parseMemory (file (required ++ ["kind: fact"])) @?= Left (DuplicateHeader "kind"),
      testCase "an unknown header" $
        parseMemory (file (required ++ ["colour: red"])) @?= Left (UnknownHeader "colour"),
      testCase "a header line with no colon" $
        parseMemory (file (required ++ ["no colon here"])) @?= Left (MalformedHeader "no colon here"),
      testCase "a time that is not a time" $
        parseMemory (file ["kind: fact", "created: yesterday", "agent: claude"])
          @?= Left (BadHeaderValue "created" "yesterday"),
      testCase "a time with a fraction of a second" $
        parseMemory (file ["kind: fact", "created: 2026-10-05T12:00:00.5Z", "agent: claude"])
          @?= Left (BadHeaderValue "created" "2026-10-05T12:00:00.5Z"),
      testCase "a time that is not in UTC" $
        parseMemory (file ["kind: fact", "created: 2026-10-05T12:00:00+01:00", "agent: claude"])
          @?= Left (BadHeaderValue "created" "2026-10-05T12:00:00+01:00"),
      testCase "an edge with a digest that is too short" $
        parseMemory (file (required ++ ["supersedes: sha256-abcd"]))
          @?= Left (BadLink "supersedes" (BadLength 2)),
      testCase "an edge with a wrong prefix" $
        parseMemory (file (required ++ ["about: md5-abcd"]))
          @?= Left (BadLink "about" (BadPrefix "md5-abcd"))
    ]

identityTests :: TestTree
identityTests =
  testGroup
    "memoryId and memoryGraph"
    [ testCase "the Id is the hash of the canonical form" $
        memoryId fixture @?= hashBytes (bytes fixtureFile),
      testCase "memoryGraph has the memory as a node" $
        Graph.nodes (memoryGraph fixture) @?= Set.singleton (memoryId fixture),
      testCase "memoryGraph has the edges of the memory" $ do
        let g = memoryGraph fixture
            i = memoryId fixture
        Graph.successors Supersedes i g @?= Set.singleton (nid 1)
        Graph.successors About i g @?= Set.singleton (nid 2)
        Graph.successors Refines i g @?= Set.empty,
      testCase "the targets of the edges are dangling until their memories join" $
        Graph.dangling (memoryGraph fixture) @?= Set.fromList [nid 1, nid 2]
    ]

-- Values that follow the rules of 'Memory'.
genWord :: Gen Text
genWord = T.pack <$> listOf1 (elements (['a' .. 'z'] ++ ['0' .. '9'] ++ "-_"))

-- Whole seconds, from 1970 to 2100.
genTime :: Gen UTCTime
genTime = posixSecondsToUTCTime . fromIntegral <$> choose (0 :: Int, 4102444800)

genEdge :: Gen Edge
genEdge = Edge <$> elements [minBound .. maxBound] <*> (nid <$> choose (0, 5))

-- Bodies that try to look like the parts around them.
genBody :: Gen Text
genBody = T.intercalate "\n" <$> listOf (oneof [elements tricky, T.pack <$> arbitrary])
  where
    tricky =
      [ "",
        "kind: fact",
        "about: " <> idText 0,
        "  ",
        "\r",
        "caf\233 \9731"
      ]

genMemory :: Gen Memory
genMemory =
  testMemory
    <$> genWord
    <*> genTime
    <*> genWord
    <*> (Set.fromList <$> listOf genEdge)
    <*> genBody

shrinkMemory :: Memory -> [Memory]
shrinkMemory m =
  [m {memEdges = Set.fromList es} | es <- shrinkList (const []) (Set.toList (memEdges m))]
    ++ [m {memBody = T.pack b} | b <- shrink (T.unpack (memBody m))]

forMemory :: (Testable p) => (Memory -> p) -> Property
forMemory = forAllShrink genMemory shrinkMemory

properties :: TestTree
properties =
  testGroup
    "properties"
    [ testProperty "parseMemory (renderMemory m) == Right m" $ forMemory $ \m ->
        parseMemory (renderMemory m) === Right m,
      testProperty "headers in another order are refused, and the same order is accepted" $ forMemory $ \m ->
        let (headers, rest) = splitFile (renderMemory m)
         in forAll (shuffle headers) $ \headers' ->
              parseMemory (BS.intercalate "\n" (headers' ++ [BS.empty]) <> "\n" <> rest)
                === (if headers' == headers then Right m else Left NotCanonical),
      testProperty "a file that parses is its own canonical form" $ forMemory $ \m ->
        forAll (shuffle (fst (splitFile (renderMemory m)))) $ \headers' ->
          let bs = BS.intercalate "\n" (headers' ++ [BS.empty]) <> "\n" <> snd (splitFile (renderMemory m))
           in either (const True) (\p -> renderMemory p == bs) (parseMemory bs),
      testProperty "two memories that differ have different files" $ forMemory $ \m1 ->
        forMemory $ \m2 ->
          m1 /= m2 ==> renderMemory m1 =/= renderMemory m2,
      testProperty "the Id is the hash of the file" $ forMemory $ \m ->
        memoryId m === hashBytes (renderMemory m),
      testProperty "the graph of a memory has one edge for each edge of the memory" $ forMemory $ \m ->
        let g = memoryGraph m
            i = memoryId m
         in conjoin
              [ Graph.successors k i g === Set.fromList [target e | e <- Set.toList (memEdges m), kind e == k]
              | k <- [minBound .. maxBound]
              ]
    ]
  where
    -- The header lines of a file, and the body. The body starts after the
    -- first blank line.
    splitFile f =
      let (h, r) = BS.breakSubstring "\n\n" f
       in (BS.split 0x0a h, BS.drop 2 r)
