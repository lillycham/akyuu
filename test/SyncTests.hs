{-# LANGUAGE OverloadedStrings #-}

module SyncTests (syncTests) where

import Akyuu.Id (Id)
import Akyuu.Id qualified as Id
import Akyuu.Memory (timeFormat)
import Akyuu.Refs (Name, mkName)
import Akyuu.Sync.Event (Event, EventError (EventTooLarge, NonCanonicalEvent, TooManyParents), eventAction, eventId, eventTime, maxEventBytes, maxEventParents, mkEvent, parseEvent, renderEvent)
import Akyuu.Sync.Stamp (formatStamp, parseStamp)
import Akyuu.Sync.State (RefKind (LogKind, TopicKind), ResourceState (LogHeads, PinState, RefTypeConflict, Registered, ReviewState, TopicHeads), State, StateError (IncompatibleStores, InvalidRefTransition, InvalidRegistration, MissingParent, NeedsResolution, ParentResourceMismatch, StaleVersion, UnknownReplica, WrongEventId, WrongParents, WrongStore), applyLocal, empty, events, fromBytes, fromEvents, interpret, merge, resourceHeads, version)
import Akyuu.Sync.State qualified as State
import Akyuu.Sync.Types (Action (AppendLog, ClearPin, ClearReview, RegisterReplica, ResolveLog, ResolveTopic, SetPin, SetReview, SetTopic), EventId (EventId), Identifier, Nonce (Nonce), ReplicaId (ReplicaId), Resource (PinResource, RefResource, RegistryResource, ReviewResource), ReviewValue (ReviewValue), StoreId (StoreId), mkIdentifier, parseIdentifier, renderIdentifier)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.List (permutations)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Text.Encoding (decodeUtf8, encodeUtf8)
import Data.Time (UTCTime (UTCTime, utctDayTime), defaultTimeLocale, formatTime, fromGregorian, parseTimeM, picosecondsToDiffTime, secondsToDiffTime)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))
import Test.Tasty.QuickCheck (Gen, chooseInt, chooseInteger, conjoin, elements, forAll, frequency, shuffle, testProperty, vectorOf, (===))

syncTests :: TestTree
syncTests = testGroup "Akyuu.Sync" [encodingTests, validationTests, topicTests, logTests, removalTests, localTests, lawTests, stampTests]

must :: (Show e) => Either e a -> a
must = either (error . show) id

ident :: Int -> Identifier
ident n = must (mkIdentifier (BS.replicate 16 (fromIntegral n)))

store :: StoreId
store = StoreId (ident 0)

replica, otherReplica :: ReplicaId
replica = ReplicaId (ident 17)
otherReplica = ReplicaId (ident 18)

time :: UTCTime
time = UTCTime (fromGregorian 2026 11 1) 0

name :: Name
name = must (mkName "me/topic")

memory :: Int -> Id
memory n = Id.hashBytes (encodeUtf8 (T.pack (show n)))

event :: Int -> [Event] -> Action -> Event
event n parents action = must (mkEvent store replica (Nonce (ident n)) (Set.fromList (map eventId parents)) action time)

registration :: Event
registration = event 34 [] (RegisterReplica replica "test")

state :: [Event] -> State
state es = must (fromEvents store (registration : es))

root, left, right, resolved :: Event
root = event 1 [] (SetTopic name (memory 1))
left = event 2 [root] (SetTopic name (memory 2))
right = event 3 [root] (SetTopic name (memory 3))
resolved = event 4 [left, right] (ResolveTopic name (memory 4))

golden :: ByteString
golden = "akyuu-sync-event-v1\n[\"00000000000000000000000000000000\",\"11111111111111111111111111111111\",\"22222222222222222222222222222222\",[],[\"register-replica\",\"11111111111111111111111111111111\",\"test\"],\"2026-11-01T00:00:00Z\"]\n"

encodingTests :: TestTree
encodingTests =
  testGroup
    "canonical encoding"
    [ testCase "fixed wire vector" $ do
        renderEvent registration @?= golden
        parseEvent golden @?= Right registration,
      testCase "domain-separated hash is over exact wire bytes" $
        eventId registration @?= EventId (Id.hashBytes golden),
      testCase "identifiers have exactly 128 bits" $ do
        assertBool "short accepted" (isLeft (mkIdentifier (BS.replicate 15 0)))
        assertBool "long accepted" (isLeft (mkIdentifier (BS.replicate 17 0)))
        parseIdentifier (renderIdentifier (ident 171)) @?= Right (ident 171)
        assertBool "upper case accepted" (isLeft (parseIdentifier (T.replicate 32 "A"))),
      testCase "rejects alternate whitespace" $
        parseEvent ("akyuu-sync-event-v1\n " <> BS.drop 20 golden) @?= Left NonCanonicalEvent,
      testCase "rejects missing final newline" $
        parseEvent (BS.init golden) @?= Left NonCanonicalEvent,
      testCase "rejects extra final newline" $
        parseEvent (golden <> "\n") @?= Left NonCanonicalEvent,
      testCase "rejects unknown protocol" $
        assertBool "unknown header accepted" (isLeft (parseEvent ("akyuu-sync-event-v2\n" <> BS.drop 20 golden))),
      testCase "rejects duplicate parents" $ do
        let bytes = renderEvent left
            parent = Id.render (let EventId digest = eventId root in digest)
            malformed = T.replace ("[\"" <> parent <> "\"]") ("[\"" <> parent <> "\",\"" <> parent <> "\"]") (decodeUtf8 bytes)
        parseEvent (encodeUtf8 malformed) @?= Left NonCanonicalEvent,
      testCase "rejects unknown action and extra fields" $ do
        assertBool "unknown action" (isLeft (parseEvent (encodeUtf8 (T.replace "register-replica" "unknown" (decodeUtf8 golden)))))
        assertBool "extra field" (isLeft (parseEvent (BS.init (BS.init golden) <> ",null]\n"))),
      testCase "size limits apply before JSON decoding" $
        parseEvent (BS.replicate (maxEventBytes + 1) 32) @?= Left EventTooLarge,
      testCase "parent limit applies to construction" $
        mkEvent store replica (Nonce (ident 1)) (Set.fromList [EventId (memory n) | n <- [0 .. maxEventParents]]) (SetTopic name (memory 0)) time @?= Left TooManyParents,
      testCase "rejects fractional time instead of truncating it" $
        assertBool "fractional time accepted" (isLeft (mkEvent store replica (Nonce (ident 1)) Set.empty (SetPin (memory 1)) time {utctDayTime = 0.5})),
      testCase "escaped unicode and multiline review reason round-trip" $ do
        let review = event 12 [] (SetReview (memory 2) (memory 1) (ReviewValue "agent" "line\n\"quoted\" \\ 雪"))
        parseEvent (renderEvent review) @?= Right review,
      testCase "all action variants round-trip" $
        mapM_ (\action -> let e = event 20 [] action in parseEvent (renderEvent e) @?= Right e) actions,
      testCase "distinct action nonce produces a distinct event ID" $
        assertBool "nonce ignored" (eventId root /= eventId (event 22 [] (eventAction root))),
      testCase "blank review author and multiline replica label fail" $ do
        assertBool "blank author" (isLeft (mkEvent store replica (Nonce (ident 1)) Set.empty (SetReview (memory 1) (memory 2) (ReviewValue " " "reason")) time))
        assertBool "multiline label" (isLeft (mkEvent store replica (Nonce (ident 1)) Set.empty (RegisterReplica replica "two\nlines") time))
    ]
  where
    actions = [SetTopic name (memory 1), AppendLog name (memory 1), ResolveTopic name (memory 1), ResolveLog name (memory 1), SetPin (memory 1), ClearPin (memory 1), SetReview (memory 2) (memory 1) (ReviewValue "agent" "reason"), ClearReview (memory 2) (memory 1), RegisterReplica replica "replica"]

validationTests :: TestTree
validationTests =
  testGroup
    "state validation"
    [ testCase "empty state is valid" $ fromEvents store [] @?= Right (empty store),
      testCase "missing parent is explicit" $
        fromEvents store [registration, left] @?= Left (MissingParent (eventId left) (eventId root)),
      testCase "unknown replica is explicit" $
        fromEvents store [root] @?= Left (UnknownReplica (eventId root) replica),
      testCase "registration must name its issuer" $ do
        let bad = event 2 [] (RegisterReplica otherReplica "other")
        fromEvents store [bad] @?= Left (InvalidRegistration (eventId bad)),
      testCase "another store is rejected" $ do
        let foreignEvent = must (mkEvent (StoreId (ident 9)) replica (Nonce (ident 1)) Set.empty (RegisterReplica replica "test") time)
        fromEvents store [foreignEvent] @?= Left (WrongStore (eventId foreignEvent))
        merge (empty store) (empty (StoreId (ident 9))) @?= Left IncompatibleStores,
      testCase "parent must belong to the same resource" $ do
        let bad = event 7 [root] (SetPin (memory 1))
        fromEvents store [registration, root, bad] @?= Left (ParentResourceMismatch (eventId bad) (eventId root)),
      testCase "ordinary topic write cannot consume concurrent heads" $ do
        let bad = event 8 [left, right] (SetTopic name (memory 8))
        fromEvents store [registration, root, left, right, bad] @?= Left (InvalidRefTransition (eventId bad)),
      testCase "ordinary action cannot change a ref type" $ do
        let bad = event 8 [root] (AppendLog name (memory 8))
        fromEvents store [registration, root, bad] @?= Left (InvalidRefTransition (eventId bad)),
      testCase "resolution requires a parent" $ do
        let bad = event 8 [] (ResolveTopic name (memory 8))
        fromEvents store [registration, bad] @?= Left (InvalidRefTransition (eventId bad)),
      testCase "raw import verifies claimed IDs" $
        fromBytes store [(eventId root, renderEvent registration)] @?= Left (WrongEventId (eventId root) (eventId registration)),
      testCase "raw import verifies format" $
        assertBool "bad format accepted" (isLeft (fromBytes store [(eventId registration, "not an event")])),
      testCase "duplicate delivery is harmless" $
        fromEvents store [registration, root, root] @?= Right (state [root]),
      testCase "registration survives newer registry heads" $ do
        let second = must (mkEvent store otherReplica (Nonce (ident 2)) (Set.singleton (eventId registration)) (RegisterReplica otherReplica "second") time)
        interpret (state [second, root]) RegistryResource @?= Registered (Map.fromList [(replica, Set.singleton "test"), (otherReplica, Set.singleton "second")])
    ]

topicTests :: TestTree
topicTests =
  testGroup
    "topics"
    [ testCase "one-sided replacement advances" $
        interpret (state [root, left]) (RefResource name) @?= TopicHeads (Map.singleton (eventId left) (memory 2)),
      testCase "divergent updates survive" $
        interpret (must (merge (state [root, left]) (state [root, right]))) (RefResource name) @?= TopicHeads (Map.fromList [(eventId left, memory 2), (eventId right, memory 3)]),
      testCase "concurrent creations need no common memory ancestor" $ do
        let other = event 8 [] (SetTopic name (memory 8))
        Map.keysSet (resourceHeads (state [root, other]) (RefResource name)) @?= Set.fromList [eventId root, eventId other],
      testCase "identical payloads remain distinct causal heads" $ do
        let other = event 8 [] (eventAction root)
        Map.size (resourceHeads (state [root, other]) (RefResource name)) @?= 2,
      testCase "explicit resolution consumes both heads" $
        interpret (state [root, left, right, resolved]) (RefResource name) @?= TopicHeads (Map.singleton (eventId resolved) (memory 4)),
      testCase "a late branch conflicts with a prior resolution" $ do
        let late = event 9 [root] (SetTopic name (memory 9))
        Map.keysSet (resourceHeads (state [root, left, right, resolved, late]) (RefResource name)) @?= Set.fromList [eventId resolved, eventId late],
      testCase "rollback is a new action" $ do
        let rollback = event 9 [left] (SetTopic name (memory 1))
        interpret (state [root, left, rollback]) (RefResource name) @?= TopicHeads (Map.singleton (eventId rollback) (memory 1))
        assertBool "memory ID reused as version" (version (state [root]) (RefResource name) /= version (state [root, left, rollback]) (RefResource name)),
      testCase "concurrent topic and log declarations conflict" $ do
        let logRoot = event 9 [] (AppendLog name (memory 9))
        interpret (state [root, logRoot]) (RefResource name) @?= RefTypeConflict (Map.fromList [(eventId root, (TopicKind, memory 1)), (eventId logRoot, (LogKind, memory 9))]),
      testCase "explicit type resolution can select existing content" $ do
        let logRoot = event 9 [] (AppendLog name (memory 9))
            choice = event 10 [root, logRoot] (ResolveTopic name (memory 1))
        interpret (state [root, logRoot, choice]) (RefResource name) @?= TopicHeads (Map.singleton (eventId choice) (memory 1)),
      testCase "timestamps do not select topic winners" $ do
        let future = must (mkEvent store replica (Nonce (ident 9)) (Set.singleton (eventId root)) (SetTopic name (memory 9)) time {utctDayTime = secondsToDiffTime 3600})
        Map.size (resourceHeads (state [root, left, future]) (RefResource name)) @?= 2
    ]

logTests :: TestTree
logTests =
  testGroup
    "log frontiers"
    [ testCase "diamond heads join without discarding events" $ do
        let a = event 1 [] (AppendLog name (memory 1))
            b = event 2 [a] (AppendLog name (memory 2))
            c = event 3 [a] (AppendLog name (memory 3))
            d = event 4 [b, c] (AppendLog name (memory 4))
            joined = state [a, b, c, d]
        interpret (state [a, b, c]) (RefResource name) @?= LogHeads (Map.fromList [(eventId b, memory 2), (eventId c, memory 3)])
        interpret joined (RefResource name) @?= LogHeads (Map.singleton (eventId d) (memory 4))
        Map.size (events joined) @?= 5
    ]

removalTests :: TestTree
removalTests =
  testGroup
    "pins and reviews"
    [ testCase "observed pin removal clears the pin" $ do
        let a = event 1 [] (SetPin (memory 1)); b = event 2 [a] (ClearPin (memory 1))
        interpret (state [a, b]) (PinResource (memory 1)) @?= PinState False,
      testCase "unseen concurrent pin survives removal" $ do
        let a = event 1 [] (SetPin (memory 1)); b = event 2 [a] (ClearPin (memory 1)); c = event 3 [a] (SetPin (memory 1))
        interpret (state [a, b, c]) (PinResource (memory 1)) @?= PinState True,
      testCase "later removal observes every pin head" $ do
        let a = event 1 [] (SetPin (memory 1)); b = event 2 [a] (ClearPin (memory 1)); c = event 3 [a] (SetPin (memory 1)); d = event 4 [b, c] (ClearPin (memory 1))
        interpret (state [a, b, c, d]) (PinResource (memory 1)) @?= PinState False,
      testCase "concurrent review reasons both survive" $ do
        let a = event 1 [] (SetReview (memory 1) (memory 2) (ReviewValue "a" "first"))
            b = event 2 [] (SetReview (memory 2) (memory 1) (ReviewValue "b" "second"))
        interpret (state [a, b]) (ReviewResource (memory 2) (memory 1)) @?= ReviewState (Map.fromList [(eventId a, ReviewValue "a" "first"), (eventId b, ReviewValue "b" "second")]),
      testCase "unreview does not remove an unseen review" $ do
        let a = event 1 [] (SetReview (memory 1) (memory 2) (ReviewValue "a" "first"))
            b = event 2 [a] (ClearReview (memory 1) (memory 2))
            c = event 3 [] (SetReview (memory 1) (memory 2) (ReviewValue "b" "second"))
        interpret (state [a, b, c]) (ReviewResource (memory 1) (memory 2)) @?= ReviewState (Map.singleton (eventId c) (ReviewValue "b" "second"))
    ]

localTests :: TestTree
localTests =
  testGroup
    "local optimistic writes"
    [ testCase "current version permits an ordinary replacement" $
        applyLocal (version (state [root]) (RefResource name)) left (state [root]) @?= Right (state [root, left]),
      testCase "stale token is rejected" $
        applyLocal (version (state [root]) (RefResource name)) right (state [root, left]) @?= Left StaleVersion,
      testCase "token is scoped to its resource" $
        applyLocal (version (state [root]) RegistryResource) left (state [root]) @?= Left StaleVersion,
      testCase "parents must cover the current frontier" $ do
        let staleParents = event 8 [root] (SetTopic name (memory 8))
        applyLocal (version (state [root, left]) (RefResource name)) staleParents (state [root, left]) @?= Left WrongParents,
      testCase "ordinary replacement of a conflict needs resolution" $ do
        let conflicted = state [root, left, right]
            ordinary = event 9 [left, right] (SetTopic name (memory 9))
        applyLocal (version conflicted (RefResource name)) ordinary conflicted @?= Left NeedsResolution,
      testCase "resolution accepts the complete current token" $ do
        let conflicted = state [root, left, right]
        applyLocal (version conflicted (RefResource name)) resolved conflicted @?= Right (state [root, left, right, resolved]),
      testCase "unrelated resource versions remain stable" $
        version (state [root]) (PinResource (memory 1)) @?= version (state [root, left]) (PinResource (memory 1)),
      testCase "empty resource token includes store identity" $
        assertBool "cross-store token reused" (version (empty store) (RefResource name) /= version (empty (StoreId (ident 9))) (RefResource name))
    ]

-- Every prefix is valid. A generated branch can extend any earlier event,
-- which produces forks, repeated values and chains rather than only linear histories.
genHistory :: Gen [Event]
genHistory = do
  count <- chooseInt (0, 24)
  choices <- vectorOf count ((,) <$> chooseInt (0, 24) <*> chooseInt (0, 5))
  pure (foldl add [] (zip [1 ..] choices))
  where
    add prior (n, (choice, value)) =
      let parent = if null prior || choice == 0 then [] else [prior !! (choice `mod` length prior)]
       in prior <> [event n parent (SetTopic name (memory value))]

-- The direct paths must agree with the general time functions on every input.
stampTests :: TestTree
stampTests =
  testGroup
    "time stamps"
    [ testProperty "format matches formatTime" $ forAll genTime $ \time ->
        formatStamp time === formatTime defaultTimeLocale timeFormat time,
      testProperty "parse matches parseTimeM on formatted times" $ forAll genTime $ \time ->
        let text = formatTime defaultTimeLocale timeFormat time
         in parseStamp text === slowParse text,
      testProperty "parse matches parseTimeM on changed text" $ forAll genTime $ \time -> forAll (genChanged (formatTime defaultTimeLocale timeFormat time)) $ \text ->
        parseStamp text === slowParse text
    ]
  where
    slowParse text = parseTimeM True defaultTimeLocale timeFormat text :: Maybe UTCTime
    genTime = do
      year <- frequency [(6, chooseInteger (1000, 9999)), (2, chooseInteger (1, 999)), (1, chooseInteger (-50, 0)), (1, chooseInteger (10000, 12000))]
      month <- chooseInt (1, 12)
      day <- chooseInt (1, 31)
      pico <- frequency [(3, (* 1000000000000) <$> chooseInteger (0, 86400)), (1, chooseInteger (0, 86401 * 1000000000000))]
      pure (UTCTime (fromGregorian year month day) (picosecondsToDiffTime pico))
    genChanged :: String -> Gen String
    genChanged text = do
      edits <- chooseInt (1, 3)
      changed <- foldr (=<<) (pure text) (replicate edits change)
      padding <- elements ["", " ", "\n"]
      elements [changed, padding <> changed, changed <> padding]
    change text = do
      position <- chooseInt (0, max 0 (length text - 1))
      char <- elements "0123456789-T:Z 6"
      kind <- chooseInt (0, 2 :: Int)
      let (before, after) = splitAt position text
      pure $ case kind of
        0 -> before <> [char] <> drop 1 after
        1 -> before <> [char] <> after
        _ -> before <> drop 1 after

lawTests :: TestTree
lawTests =
  testGroup
    "merge laws"
    [ testProperty "merge matches complete construction" $ forAll genHistory $ \a -> forAll genHistory $ \b ->
        merge (state a) (state b) === fromEvents store (registration : a <> b),
      testProperty "incremental wire validation matches complete construction" $ forAll genHistory $ \history ->
        forAll (chooseInt (0, length history)) $ \split ->
          let (prefix, suffix) = splitAt split history
              bytes = [(eventId e, renderEvent e) | e <- suffix]
           in State.extendBytes (state prefix) bytes === Right (state history),
      testCase "incremental wire validation rejects missing parents" $
        State.extendBytes (state []) [(eventId left, renderEvent left)] @?= Left (MissingParent (eventId left) (eventId root)),
      testCase "incremental wire validation checks claimed IDs" $
        State.extendBytes (state [root]) [(eventId left, renderEvent right)] @?= Left (WrongEventId (eventId left) (eventId right)),
      testProperty "idempotent" $ forAll genHistory $ \history ->
        let a = state history in merge a a === Right a,
      testProperty "commutative for independently edited replicas" $ forAll genHistory $ \firstHistory -> forAll genHistory $ \secondHistory ->
        let a = state firstHistory
            b = state secondHistory
         in merge a b === merge b a,
      testProperty "associative across independent snapshots" $ forAll genHistory $ \firstHistory -> forAll genHistory $ \secondHistory -> forAll genHistory $ \thirdHistory ->
        let a = state firstHistory
            b = state secondHistory
            c = state thirdHistory
         in (merge a b >>= (`merge` c)) === (merge b c >>= merge a),
      testProperty "arrival order and duplicate delivery do not change state" $ forAll genHistory $ \history ->
        forAll (shuffle (registration : history <> history)) $ \arrival ->
          fromEvents store arrival === Right (state history),
      testProperty "valid events round-trip" $ forAll genHistory $ \history ->
        conjoin [parseEvent (renderEvent e) === Right e | e <- registration : history],
      testCase "every partition exchange order preserves all branches" $ do
        let snapshots = [state [root, left], state [root, right], state [event 9 [] (SetTopic name (memory 9))]]
            expected = state [root, left, right, event 9 [] (SetTopic name (memory 9))]
        mapM_ (\order -> foldl (\acc next -> acc >>= (`merge` next)) (Right (empty store)) order @?= Right expected) (permutations snapshots),
      testCase "complete raw archive import matches typed construction" $ do
        let snapshot = state [root, left, right, resolved]
        fromBytes store [(key, renderEvent e) | (key, e) <- Map.toAscList (events snapshot)] @?= Right snapshot
    ]

isLeft :: Either a b -> Bool
isLeft (Left _) = True
isLeft _ = False
