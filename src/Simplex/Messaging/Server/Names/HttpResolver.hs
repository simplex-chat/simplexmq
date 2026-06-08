{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StrictData #-}

-- | HTTP transport for the public-namespace resolver.
--
-- The Python REST resolver (see scripts/resolver/snrc-resolve.py) exposes
--
--   GET /resolve/<name>   -> 200 with a NameRecord JSON document
--                            404 / 400 for unknown names / TLDs
--                            502 for upstream RPC failures
--   GET /health           -> 200 when the resolver process is ready
--
-- Boundary properties:
--   * Response body read with `brReadSome maxResponseBytes` — adversarial
--     endpoints cannot exhaust memory with multi-GB bodies.
--   * `redirectCount = 0` — a compromised resolver cannot bounce credentials
--     to a private-IP target (SSRF amplification on top of the URL validation
--     performed at config load in Server.Main.validateUrl).
--   * Authorization header attached only when configured.
module Simplex.Messaging.Server.Names.HttpResolver
  ( RpcAuth (..),
    ResolverEnv,
    ResolverError (..),
    newResolverEnv,
    closeResolverEnv,
    resolveHttp,
    healthHttp,
    scrubUrl,
  )
where

import qualified Control.Exception as E
import qualified Data.Aeson as J
import qualified Data.ByteArray.Encoding as BAE
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Lazy as BL
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Encoding (decodeLatin1, encodeUtf8)
import Network.HTTP.Client
  ( HttpException,
    Manager,
    ManagerSettings (..),
    Request,
    brReadSome,
    parseRequest,
    redirectCount,
    requestHeaders,
    responseBody,
    responseStatus,
    responseTimeoutMicro,
    withResponse,
  )
import qualified Network.HTTP.Client as HC
import Network.HTTP.Client.TLS (tlsManagerSettings)
import qualified Network.HTTP.Types as HT
import Network.HTTP.Types.URI (urlEncode)

data RpcAuth = AuthBearer Text | AuthBasic Text Text

-- | Redacts the bearer token / basic-auth password so an accidental
-- `show` / `tshow` on NamesConfig never lands secrets in logs.
instance Show RpcAuth where
  show (AuthBearer _) = "AuthBearer <redacted>"
  show (AuthBasic u _) = "AuthBasic " <> show u <> " <redacted>"

data ResolverEnv = ResolverEnv
  { manager :: Manager,
    baseUrl :: Text,
    authHdr :: [HT.Header],
    timeoutMicro :: Int,
    maxResponseBytes :: Int
  }

data ResolverError
  = HttpFailure HttpException
  | HttpStatusErr Int
  | BodyTooLarge
  | InvalidJson String
  deriving (Show)

newResolverEnv :: Text -> Maybe RpcAuth -> Int -> Int -> IO ResolverEnv
newResolverEnv baseUrl auth_ timeoutMs maxResponseBytes = do
  manager <- HC.newManager tlsManagerSettings {managerConnCount = 10}
  pure
    ResolverEnv
      { manager,
        baseUrl = stripTrailingSlash baseUrl,
        authHdr = maybe [] (pure . authHeader) auth_,
        timeoutMicro = timeoutMs * 1000,
        maxResponseBytes
      }

-- | http-client's `closeManager` is a deprecated no-op since 0.5; the
-- manager is released by the GC finalizer on its internal state. Hook kept
-- as a future-cleanup seam.
closeResolverEnv :: ResolverEnv -> IO ()
closeResolverEnv _ = pure ()

authHeader :: RpcAuth -> HT.Header
authHeader = \case
  AuthBearer tok -> ("Authorization", "Bearer " <> encodeUtf8 tok)
  AuthBasic u p ->
    let encoded = BAE.convertToBase BAE.Base64 (encodeUtf8 u <> ":" <> encodeUtf8 p) :: ByteString
     in ("Authorization", "Basic " <> encoded)

-- | GET <baseUrl>/resolve/<percent-encoded name>, return the JSON body on 200.
resolveHttp :: ResolverEnv -> Text -> IO (Either ResolverError J.Value)
resolveHttp env name = doGet env ("/resolve/" <> percentEncode name)

-- | GET <baseUrl>/health, return the JSON body on 200.
healthHttp :: ResolverEnv -> IO (Either ResolverError J.Value)
healthHttp env = doGet env "/health"

doGet :: ResolverEnv -> Text -> IO (Either ResolverError J.Value)
doGet ResolverEnv {manager, baseUrl, authHdr, timeoutMicro, maxResponseBytes} path = do
  req0 <- parseRequest (T.unpack (baseUrl <> path))
  let req =
        req0
          { redirectCount = 0,
            requestHeaders = ("Accept", "application/json") : authHdr,
            HC.responseTimeout = responseTimeoutMicro timeoutMicro
          }
  result <- E.try $ withResponse req manager $ \res -> do
    let status = HT.statusCode (responseStatus res)
    if status >= 400
      then pure (Left (HttpStatusErr status))
      else do
        bs <- brReadSome (responseBody res) (maxResponseBytes + 1)
        if BL.length bs > fromIntegral maxResponseBytes
          then pure (Left BodyTooLarge)
          else case J.eitherDecodeStrict (BL.toStrict bs) of
            Left e -> pure (Left (InvalidJson e))
            Right v -> pure (Right v)
  pure (either (Left . HttpFailure) id result)

-- | Percent-encode a name component (path-safe). Aggressive: encode every
-- byte that isn't an unreserved character per RFC 3986. The resolver expects
-- raw labels (e.g., `alice.simplex`); slashes and other ASCII punctuation
-- would change the request path semantics if passed through verbatim.
percentEncode :: Text -> Text
percentEncode = decodeLatin1 . urlEncode True . encodeUtf8

stripTrailingSlash :: Text -> Text
stripTrailingSlash t = case T.unsnoc t of
  Just (rest, '/') -> rest
  _ -> t

-- | Strip userinfo from a URL so log lines never leak credentials.
scrubUrl :: Text -> Text
scrubUrl url =
  let (scheme, rest) = T.breakOn "://" url
   in if T.null rest
        then url
        else
          let body = T.drop 3 rest
              (host, query) = T.breakOn "/" body
           in case T.breakOn "@" host of
                (_userinfo, atRest)
                  | not (T.null atRest) -> scheme <> "://" <> T.drop 1 atRest <> query
                _ -> url
