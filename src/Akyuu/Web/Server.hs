-- | The HTTP server of the web UI: @akyuu serve@.
--
-- = Threat model
--
-- This is a local tool for a person who tests a store. It has no login and
-- no TLS. Its safety comes from these rules:
--
-- * It listens on 127.0.0.1 only, never on all addresses. Another machine
--   cannot connect. 'serve' checks the address of the socket after the bind,
--   and stops if it is not a loopback address.
-- * It only reads. Every endpoint is a @GET@, and any other method gets
--   @405@ (see "Akyuu.Web.Api"). There is no endpoint that writes.
-- * It never serves a file by its path. The page is in the binary
--   ("Akyuu.Web.Page"), and the API returns JSON that it makes itself.
-- * It answers only a request whose @Host@ header is the address of the
--   server ('hostAllowed'). A web page on another site that a browser opens
--   cannot then use DNS rebinding to read the store through this server.
--   The answers send no CORS headers, so a page of another origin cannot
--   read them either.
-- * The page puts the text of a memory into the DOM as text, never as HTML.
--   A memory body is untrusted: an agent wrote it.
--
-- Any program of the same user on the same machine can read the store
-- through the server. It can also read the files of the store, so this adds
-- nothing.
--
-- The server answers one request at a time. The SQLite connection of the
-- cache is shared, and two transactions on one connection cannot run at
-- once.
module Akyuu.Web.Server
  ( defaultPort,
    serve,
    application,
    hostAllowed,
    toWebRequest,
  )
where

import Akyuu.Error (AkyuuError)
import Akyuu.Ops (Env)
import Akyuu.Web.Api (Endpoint, WebRequest (WebRequest, reqMethod, reqPath, reqQuery), WebResponse (WebResponse, resBody, resHeaders, resStatus), route, runEndpoint, securityHeaders)
import Control.Concurrent.MVar (newMVar, withMVar)
import Control.Exception (bracket)
import Data.Aeson (Value, object, (.=))
import Data.Aeson qualified as A
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as BC
import Data.Streaming.Network (bindPortTCP)
import Data.String (fromString)
import Data.Text (Text)
import Network.HTTP.Types (queryToQueryText)
import Network.Socket (SockAddr (SockAddrInet), Socket, close, getSocketName, hostAddressToTuple)
import Network.Wai (Application, Request, pathInfo, queryString, requestHeaderHost, requestMethod, responseLBS)
import Network.Wai.Handler.Warp qualified as Warp

-- | The port of @akyuu serve@ when no @--port@ is given.
defaultPort :: Int
defaultPort = 7420

-- | Serve the UI of a store on 127.0.0.1, until the program is stopped.
--
-- Port 0 means a free port that the OS chooses. The last argument gets the
-- real port, after the bind and before the first request, so the caller can
-- print the address.
serve :: Env -> Int -> (Int -> IO ()) -> IO ()
serve env port ready = do
  lock <- newMVar ()
  let run e = withMVar lock (\_ -> runEndpoint env e)
  bracket (bindPortTCP port "127.0.0.1") close $ \sock -> do
    p <- loopbackPort sock
    let settings =
          Warp.setHost "127.0.0.1"
            . Warp.setPort p
            . Warp.setServerName ""
            . Warp.setBeforeMainLoop (ready p)
            $ Warp.defaultSettings
    Warp.runSettingsSocket settings sock (application p run)

-- | The port of a socket that is bound to 127.0.0.1. Any other address is
-- an error: the server must not listen where another machine can reach it.
loopbackPort :: Socket -> IO Int
loopbackPort sock = do
  addr <- getSocketName sock
  case addr of
    SockAddrInet p h | hostAddressToTuple h == (127, 0, 0, 1) -> pure (fromIntegral p)
    other -> ioError (userError ("akyuu serve: the socket is not on 127.0.0.1: " <> show other))

-- | Is this @Host@ header the address of the server on this port? The
-- header must be @127.0.0.1:PORT@ or @localhost:PORT@. A request with no
-- @Host@ header is refused too. This function is pure.
hostAllowed :: Int -> Maybe ByteString -> Bool
hostAllowed port h = h `elem` map Just [BC.pack ("127.0.0.1:" <> show port), BC.pack ("localhost:" <> show port)]

-- | The parts of a WAI request that "Akyuu.Web.Api" needs.
toWebRequest :: Request -> WebRequest
toWebRequest r =
  WebRequest
    { reqMethod = requestMethod r,
      reqPath = pathInfo r,
      reqQuery = queryToQueryText (queryString r)
    }

-- | The WAI application of the server on this port, with this runner of the
-- endpoints. A request with a wrong @Host@ gets @403@ and runs nothing.
application :: Int -> (Endpoint -> IO (Either AkyuuError Value)) -> Application
application port run req respond
  | not (hostAllowed port (requestHeaderHost req)) = respond (toWai refused)
  | otherwise = route run (toWebRequest req) >>= respond . toWai
  where
    refused =
      WebResponse
        403
        (("Content-Type", "application/json; charset=utf-8") : securityHeaders)
        (A.encode (object ["error" .= ("The Host header must be 127.0.0.1 or localhost with the port of this server." :: Text)]))
    toWai r =
      responseLBS
        (toEnum (resStatus r))
        [(fromString (BC.unpack k), v) | (k, v) <- resHeaders r]
        (resBody r)
