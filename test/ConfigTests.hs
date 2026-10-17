{-# LANGUAGE OverloadedStrings #-}

module ConfigTests (configTests) where

import Akyuu.Config (Config (cfgAgent, cfgEmbed, cfgFile, cfgNotes, cfgPolicyRef, cfgRoot, cfgTiersRef), ConfigError (ConfigInvalid, UnknownProfile), EmbedSettings (esArgs, esCommand, esCommandEnv, esKey, esMin, esProfile, esQueryPrefix, esSource, esTimeout), FileConfig (fcProfiles), Profile (prArgs, prKey), Source (Default, FromEnv, FromFile), Sourced (Sourced), expandHome, parseConfigText, parseLegacy, resolve)
import Data.Either (isLeft)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

configTests :: TestTree
configTests = testGroup "Akyuu.Config" [fileCases, resolveCases]

full :: Text
full =
  T.unlines
    [ "root = \"~/notes\"",
      "policy-ref = \"me/policy\"",
      "agent = \"me\"",
      "",
      "[embed]",
      "profile = \"nomic\"",
      "",
      "[embed.profiles.nomic]",
      "command = \"akyuu-embed-llama\"",
      "key = \"llama:nomic\"",
      "query-prefix = \"search_query: \"",
      "min = 0.55",
      "timeout = 60",
      "args = { gguf = \"/m/nomic.gguf\", idle = 120, api-model = \"nomic\" }",
      "",
      "[embed.profiles.gemma]",
      "command = \"akyuu-embed-llama\"",
      "key = \"llama:gemma\""
    ]

parsed :: Text -> IO FileConfig
parsed t = either (assertFailure . show) (pure . fst) (parseConfigText t)

fileCases :: TestTree
fileCases =
  testGroup
    "the file"
    [ testCase "a whole file is read, and args may be numbers" $ do
        fc <- parsed full
        Map.keys (fcProfiles fc) @?= ["gemma", "nomic"]
        fmap prKey (Map.lookup "nomic" (fcProfiles fc)) @?= Just "llama:nomic"
        fmap prArgs (Map.lookup "nomic" (fcProfiles fc)) @?= Just (Map.fromList [("api-model", "nomic"), ("gguf", "/m/nomic.gguf"), ("idle", "120")]),
      testCase "an unknown key is a warning with its line" $
        case parseConfigText "agnet = \"me\"\n" of
          Right (_, [w]) -> assertBool (T.unpack w) ("agnet" `T.isInfixOf` w && "1:" `T.isInfixOf` w)
          other -> assertFailure (show other),
      testCase "TOML that does not parse is an error" $
        assertBool "error" (isLeft (parseConfigText "root = \n")),
      testCase "a value of the wrong type is an error" $
        assertBool "error" (isLeft (parseConfigText "[embed.profiles.a]\ncommand = \"c\"\nkey = \"k\"\ntimeout = \"soon\"\n")),
      testCase "a profile needs a command and a key" $
        assertBool "error" (isLeft (parseConfigText "[embed.profiles.a]\ncommand = \"c\"\n")),
      testCase "an argument that would be a variable of akyuu is an error" $
        assertBool "error" (isLeft (parseConfigText "[embed.profiles.a]\ncommand = \"c\"\nkey = \"k\"\nargs = { role = \"x\" }\n")),
      testCase "a minimum out of range is an error" $
        assertBool "error" (isLeft (parseConfigText "[embed.profiles.a]\ncommand = \"c\"\nkey = \"k\"\nmin = 2\n")),
      testCase "embed.env lines are read as before" $
        parseLegacy "# c\nexport A=1\r\nB = two words\nC='q'\nnot a line\n" @?= [("A", "1"), ("B", " two words"), ("C", "q")],
      testCase "~ is the home directory" $ do
        expandHome (Just "/home/me") "~/notes" @?= "/home/me/notes"
        expandHome Nothing "~/notes" @?= "~/notes"
        expandHome (Just "/home/me") "/abs" @?= "/abs"
    ]

-- Resolve with the file 'full' at /c.toml.
withFull :: [(String, String)] -> IO (Either ConfigError Config)
withFull env = (\fc -> resolve env (Just ("/c.toml", fc)) Nothing) <$> parsed full

ok :: Either ConfigError Config -> IO Config
ok = either (assertFailure . show) pure

resolveCases :: TestTree
resolveCases =
  testGroup
    "resolve"
    [ testCase "with nothing set, the defaults hold and meaning search is off" $ do
        c <- ok (resolve [] Nothing Nothing)
        cfgRoot c @?= Nothing
        cfgPolicyRef c @?= Sourced "policy/memory" Default
        cfgTiersRef c @?= Sourced "policy/tiers" Default
        cfgAgent c @?= Sourced "agent" Default
        cfgEmbed c @?= Nothing
        cfgFile c @?= Nothing,
      testCase "the file sets what the environment does not, and ~ expands" $ do
        c <- ok =<< withFull [("HOME", "/home/me"), ("AKYUU_AGENT", "codex")]
        cfgRoot c @?= Just (Sourced "/home/me/notes" (FromFile "/c.toml"))
        cfgPolicyRef c @?= Sourced "me/policy" (FromFile "/c.toml")
        cfgAgent c @?= Sourced "codex" (FromEnv "AKYUU_AGENT")
        cfgFile c @?= Just "/c.toml",
      testCase "an empty variable is no value" $ do
        c <- ok =<< withFull [("AKYUU_ROOT", ""), ("HOME", "/h")]
        cfgRoot c @?= Just (Sourced "/h/notes" (FromFile "/c.toml")),
      testCase "the profile of the file is used, with its defaults filled in" $ do
        c <- ok =<< withFull []
        e <- maybe (assertFailure "no profile") pure (cfgEmbed c)
        (esProfile e, esKey e, esQueryPrefix e, esMin e, esTimeout e) @?= ("nomic", "llama:nomic", "search_query: ", Just 0.55, 60)
        esSource e @?= FromFile "/c.toml",
      testCase "the arguments go to the command as variables" $ do
        c <- ok =<< withFull [("PATH", "/bin"), ("AKYUU_EMBED_GGUF", "/old.gguf")]
        e <- maybe (assertFailure "no profile") pure (cfgEmbed c)
        lookup "AKYUU_EMBED_GGUF" (esCommandEnv e) @?= Just "/m/nomic.gguf"
        lookup "AKYUU_EMBED_API_MODEL" (esCommandEnv e) @?= Just "nomic"
        lookup "AKYUU_EMBED_IDLE" (esCommandEnv e) @?= Just "120"
        lookup "PATH" (esCommandEnv e) @?= Just "/bin"
        length (filter ((== "AKYUU_EMBED_GGUF") . fst) (esCommandEnv e)) @?= 1
        esArgs e @?= [("api-model", "nomic"), ("gguf", "/m/nomic.gguf"), ("idle", "120")],
      testCase "AKYUU_EMBED_PROFILE picks another profile" $ do
        c <- ok =<< withFull [("AKYUU_EMBED_PROFILE", "gemma")]
        fmap esKey (cfgEmbed c) @?= Just "llama:gemma"
        fmap esSource (cfgEmbed c) @?= Just (FromEnv "AKYUU_EMBED_PROFILE"),
      testCase "a profile that is not there is an error that names the others" $ do
        r <- withFull [("AKYUU_EMBED_PROFILE", "nope")]
        r @?= Left (UnknownProfile "nope" (FromEnv "AKYUU_EMBED_PROFILE") ["gemma", "nomic"]),
      testCase "one profile needs no name; two need embed.profile" $ do
        one <- parsed "[embed.profiles.only]\ncommand = \"c\"\nkey = \"k\"\n"
        fmap esProfile . cfgEmbed <$> resolve [] (Just ("/c.toml", one)) Nothing @?= Right (Just "only")
        two <- parsed "[embed.profiles.a]\ncommand = \"c\"\nkey = \"k\"\n[embed.profiles.b]\ncommand = \"c\"\nkey = \"k\"\n"
        case resolve [] (Just ("/c.toml", two)) Nothing of
          Left (ConfigInvalid _ _) -> pure ()
          other -> assertFailure (show other),
      testCase "the numbers of the environment win over the profile, and bad ones are notes" $ do
        c <- ok =<< withFull [("AKYUU_EMBED_MIN", "0.6"), ("AKYUU_EMBED_TIMEOUT", "soon")]
        fmap esMin (cfgEmbed c) @?= Just (Just 0.6)
        fmap esTimeout (cfgEmbed c) @?= Just 60
        length (cfgNotes c) @?= 1,
      testCase "AKYUU_EMBED_COMMAND makes the environment profile, over the file" $ do
        c <- ok =<< withFull [("AKYUU_EMBED_COMMAND", "cat"), ("AKYUU_EMBED_MODEL", "m"), ("AKYUU_EMBED_QUERY_PREFIX", "q: ")]
        e <- maybe (assertFailure "no profile") pure (cfgEmbed c)
        (esProfile e, esCommand e, esKey e, esQueryPrefix e) @?= ("environment", "cat", "m", "q: "),
      testCase "embed.env is under the environment" $ do
        c <- ok (resolve [("AKYUU_EMBED_MODEL", "env")] Nothing (Just ("/e.env", [("AKYUU_EMBED_COMMAND", "cat"), ("AKYUU_EMBED_MODEL", "file")])))
        fmap (\e -> (esCommand e, esKey e, esSource e)) (cfgEmbed c) @?= Just ("cat", "env", FromFile "/e.env")
        cfgFile c @?= Just "/e.env"
    ]
