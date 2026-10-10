-- | The HTTP API of the web UI, as pure functions.
--
-- This module does not know the HTTP server. A request is a 'WebRequest'
-- (the method, the parts of the path and the query), and the answer is a
-- 'WebResponse' (the status, the headers and the body). "Akyuu.Web.Server"
-- turns the requests of the server into these types and back.
--
-- 'route' takes the function that answers an 'Endpoint' as an argument, like
-- 'Akyuu.MCP.handleMessage' takes the runner of a tool. A test can pass a
-- pure function, and check the routes, the parameters and the error codes
-- without a store. 'runEndpoint' is the real function.
--
-- Every endpoint is a @GET@ and only reads (see "Akyuu.Web.Read"). Any
-- other method gets @405@. The endpoints:
--
-- > /                       the page
-- > /api/stats              counts and the newest file time, to poll
-- > /api/graph              ?focus=ID &hops=N &limit=N &all=1
-- > /api/memory/ID          ID can be the start of an id
-- > /api/refs
-- > /api/search             ?q=WORDS &limit=N &hops=N
-- > /api/gc/plan
-- > /api/gc/explain/ID
-- > /api/trash              the trash, the tombstones and the pins
-- > /api/verify             the verify report and the cache drift
module Akyuu.Web.Api
  ( -- * Requests and responses
    WebRequest (..),
    WebResponse (..),
    getRequest,

    -- * Endpoints
    Endpoint (..),
    RouteError (..),
    parseEndpoint,
    statusOf,

    -- * Answers
    route,
    runEndpoint,
    securityHeaders,
  )
where

import Akyuu.Error (AkyuuError (..), describe)
import Akyuu.Id (Id)
import Akyuu.Id qualified as Id
import Akyuu.Ops (Env, IdSpec, parseIdSpec)
import Akyuu.Query (SearchOptions (..), defaultSearchOptions)
import Akyuu.Store (StoreError (NotFound))
import Akyuu.Web.Model (Window (..), defaultWindow, statsJSON)
import Akyuu.Web.Page (indexPage)
import Akyuu.Web.Read
import Data.Aeson (Value, object, (.=))
import Data.Aeson qualified as A
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as BL
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Read qualified as TR

-- Requests and responses -------------------------------------------------

-- | A request, as the server gives it.
data WebRequest = WebRequest
  { -- | The method, for example @GET@.
    reqMethod :: ByteString,
    -- | The parts of the path, decoded. @/api/stats@ is @["api", "stats"]@.
    reqPath :: [Text],
    -- | The query parameters, decoded, in order. A name with no @=@ has
    -- 'Nothing'.
    reqQuery :: [(Text, Maybe Text)]
  }
  deriving (Eq, Show)

-- | A @GET@ request for a path with no query.
getRequest :: [Text] -> WebRequest
getRequest p = WebRequest "GET" p []

-- | An answer.
data WebResponse = WebResponse
  { resStatus :: Int,
    resHeaders :: [(ByteString, ByteString)],
    resBody :: BL.ByteString
  }
  deriving (Eq, Show)

-- Endpoints ----------------------------------------------------------------

-- | What a request asks for, with its parameters checked.
data Endpoint
  = PageEndpoint
  | StatsEndpoint
  | GraphEndpoint Window
  | MemoryEndpoint IdSpec
  | RefsEndpoint
  | SearchEndpoint SearchOptions Text
  | PlanEndpoint
  | ExplainEndpoint Id
  | TrashEndpoint
  | VerifyEndpoint
  deriving (Eq, Show)

-- | Why a request has no endpoint.
data RouteError
  = -- | The method is not @GET@.
    WrongMethod
  | -- | No endpoint has this path.
    NoRoute
  | -- | A parameter is wrong. The text says why.
    BadParam Text
  deriving (Eq, Show)

-- | Find the endpoint of a request, and check its parameters. This function
-- is pure.
--
-- A trailing @/@ in the path is ignored. A parameter that the endpoint does
-- not know is ignored. If a parameter comes twice, the first one counts.
parseEndpoint :: WebRequest -> Either RouteError Endpoint
parseEndpoint req
  | reqMethod req /= "GET" = Left WrongMethod
  | otherwise = case path of
      [] -> Right PageEndpoint
      ["index.html"] -> Right PageEndpoint
      ["api", "stats"] -> Right StatsEndpoint
      ["api", "graph"] -> GraphEndpoint <$> window
      ["api", "memory", t] -> MemoryEndpoint <$> first (BadParam . describe) (parseIdSpec t)
      ["api", "refs"] -> Right RefsEndpoint
      ["api", "search"] -> search
      ["api", "gc", "plan"] -> Right PlanEndpoint
      ["api", "gc", "explain", t] -> ExplainEndpoint <$> wholeId t
      ["api", "trash"] -> Right TrashEndpoint
      ["api", "verify"] -> Right VerifyEndpoint
      _ -> Left NoRoute
  where
    path = case reverse (reqPath req) of
      "" : rest -> reverse rest
      _ -> reqPath req
    param k = case [v | (n, v) <- reqQuery req, n == k] of
      (v : _) -> Just (maybe "" id v)
      [] -> Nothing
    int k lo hi d = case param k of
      Nothing -> Right d
      Just t -> case TR.decimal t of
        Right (n, "") | n >= lo && n <= hi -> Right n
        _ ->
          Left . BadParam $
            "The parameter '" <> k <> "' must be a whole number from " <> tshow lo <> " to " <> tshow hi <> "."
    flag k = maybe False (`elem` ["1", "true", "yes", ""]) (param k)
    wholeId t = first (\e -> BadParam (describe (BadId t e))) (Id.parse t)
    window = do
      focus <- traverse wholeId (param "focus")
      hops <- int "hops" 0 10 (winHops defaultWindow)
      limit <- int "limit" 1 100000 (winLimit defaultWindow)
      pure Window {winFocus = focus, winHops = hops, winLimit = limit, winAll = flag "all"}
    search = do
      q <- maybe (Left (BadParam "The parameter 'q' is missing.")) Right (param "q")
      if T.null (T.strip q)
        then Left (BadParam "The parameter 'q' must have at least one word.")
        else do
          limit <- int "limit" 1 100 (searchLimit defaultSearchOptions)
          hops <- int "hops" 0 5 (searchHops defaultSearchOptions)
          pure (SearchEndpoint defaultSearchOptions {searchLimit = limit, searchHops = hops} q)
    tshow = T.pack . show

-- | The HTTP status for an error of an operation. A thing that is not there
-- is @404@, a thing that GC deleted is @410@, bad input is @400@, and the
-- rest is @500@.
statusOf :: AkyuuError -> Int
statusOf e = case e of
  StoreFailed (NotFound _) -> 404
  NoSuchPrefix _ -> 404
  Pruned _ _ -> 410
  BadId _ _ -> 400
  BadIdSpec _ -> 400
  AmbiguousPrefix _ _ -> 400
  BadName _ _ -> 400
  BadField _ _ -> 400
  BadInput _ -> 400
  _ -> 500

-- Answers ------------------------------------------------------------------

-- | The headers of every answer.
--
-- The page is a local tool, but a browser also runs other pages. These
-- headers stop the browser from guessing a type, from sending the address
-- to other sites, from putting the page in a frame, and from loading any
-- script, style or connection from another origin. The script and the style
-- are inline in the page, so the policy allows inline code. The page puts
-- data in the DOM only as text, never as HTML.
securityHeaders :: [(ByteString, ByteString)]
securityHeaders =
  [ ("Cache-Control", "no-store"),
    ("X-Content-Type-Options", "nosniff"),
    ("Referrer-Policy", "no-referrer"),
    ("X-Frame-Options", "DENY"),
    ( "Content-Security-Policy",
      "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; \
      \connect-src 'self'; img-src data:; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"
    )
  ]

json :: Int -> Value -> WebResponse
json s v = WebResponse s (("Content-Type", "application/json; charset=utf-8") : securityHeaders) (A.encode v)

errorJSON :: Int -> Text -> WebResponse
errorJSON s t = json s (object ["error" .= t])

-- | Answer one request.
--
-- The first argument answers an endpoint. It is not called for the page, or
-- for a request that has no endpoint:
--
-- * A method other than @GET@ gets @405@, with @Allow: GET@.
-- * A path with no endpoint gets @404@.
-- * A bad parameter gets @400@.
--
-- An error of the operation gets the status of 'statusOf'. Every error has a
-- JSON body @{"error": "…"}@ with the text of 'describe'.
route :: (Monad m) => (Endpoint -> m (Either AkyuuError Value)) -> WebRequest -> m WebResponse
route run req = case parseEndpoint req of
  Left WrongMethod ->
    pure (errorJSON 405 "Only GET is allowed. This server only reads.") {resHeaders = ("Allow", "GET") : resHeaders (errorJSON 405 "")}
  Left NoRoute -> pure (errorJSON 404 "There is nothing at this path.")
  Left (BadParam t) -> pure (errorJSON 400 t)
  Right PageEndpoint ->
    pure (WebResponse 200 (("Content-Type", "text/html; charset=utf-8") : securityHeaders) (BL.fromStrict indexPage))
  Right e -> either (\err -> errorJSON (statusOf err) (describe err)) (json 200) <$> run e

-- | Answer an endpoint from an open store. See "Akyuu.Web.Read".
runEndpoint :: Env -> Endpoint -> IO (Either AkyuuError Value)
runEndpoint env e = case e of
  PageEndpoint -> pure (Right (object []))
  StatsEndpoint -> fmap statsJSON <$> readStats env
  GraphEndpoint w -> readGraph env w
  MemoryEndpoint spec -> readMemory env spec
  RefsEndpoint -> readRefs env
  SearchEndpoint o q -> readSearch env o q
  PlanEndpoint -> readPlan env
  ExplainEndpoint i -> readExplain env i
  TrashEndpoint -> readTrash env
  VerifyEndpoint -> readVerify env
