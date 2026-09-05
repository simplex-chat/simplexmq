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
    NameStatusResp (..),
    newResolverEnv,
    closeResolverEnv,
    availabilityHttp,
    resolveHttp,
    healthHttp,
  )
where

import qualified Control.Exception as E
import qualified Data.Aeson as J
import Data.Aeson.Key (Key)
import qualified Data.Aeson.KeyMap as JKM
import Data.Bifunctor (first)
import qualified Data.ByteArray.Encoding as BAE
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import qualified Data.ByteString.Lazy as BL
import Data.Int (Int64)
import Data.Text (Text)
import Data.Text.Encoding (encodeUtf8)
import Network.HTTP.Client
  ( HttpException,
    Manager,
    ManagerSettings (..),
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
import Simplex.Messaging.Names.Record (NameRecord)

data RpcAuth = AuthBearer Text | AuthBasic Text Text

-- | Redacts the bearer token / basic-auth password so an accidental
-- `show` / `tshow` on NamesConfig never lands secrets in logs.
instance Show RpcAuth where
  show (AuthBearer _) = "AuthBearer <redacted>"
  show (AuthBasic u _) = "AuthBasic " <> show u <> " <redacted>"

data ResolverEnv = ResolverEnv
  { manager :: Manager,
    baseUrl :: String,
    authHdr :: [HT.Header],
    timeoutMicro :: Int,
    maxResponseBytes :: Int
  }

-- | What the resolver says about a name's registrability. Only some statuses
-- carry the fields below the status, so each is read as optional.
data NameStatusResp = NameStatusResp
  { nsStatus :: Text,
    nsExpires :: Maybe Int64,
    nsGraceEnds :: Maybe Int64,
    nsAuctionEnds :: Maybe Int64,
    nsPremium :: Maybe Text,
    nsReasonCode :: Maybe Text
  }
  deriving (Show)

data ResolverError
  = HttpFailure HttpException
  | HttpStatusErr Int
  | BodyTooLarge
  | InvalidJson String
  | ResolverTimeout
  deriving (Show)

newResolverEnv :: String -> Maybe RpcAuth -> Int -> Int -> IO ResolverEnv
newResolverEnv baseUrl auth_ timeoutMs maxResponseBytes = do
  manager <- HC.newManager tlsManagerSettings {managerConnCount = 10}
  pure
    ResolverEnv
      { manager,
        baseUrl,
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

-- | GET <baseUrl>/resolve/<percent-encoded name>, decoding the 200 body
-- directly into a NameRecord in one pass (no intermediate Aeson Value). The
-- name is percent-encoded (every non-unreserved byte per RFC 3986): the
-- resolver expects raw labels, so slashes/punctuation must not alter the path.
resolveHttp :: ResolverEnv -> Text -> IO (Either ResolverError NameRecord)
resolveHttp env name =
  (>>= first InvalidJson . J.eitherDecodeStrict . BL.toStrict)
    <$> httpGet env ("/resolve/" <> B.unpack (urlEncode True (encodeUtf8 name)))

-- | GET <baseUrl>/resolve/<name>, reading what the resolver says about the name
-- rather than only whether it answered. The status code alone cannot separate a
-- name nobody has taken from one held back, nor a lapsed name still renewable by
-- its owner from one anyone may take - that is in the body, under "status" on a
-- 200 and "error" otherwise, alongside the deadline or price that status
-- carries.
availabilityHttp :: ResolverEnv -> Text -> IO (Either ResolverError NameStatusResp)
availabilityHttp ResolverEnv {manager, baseUrl, authHdr, timeoutMicro} name = do
  req0 <- parseRequest (baseUrl <> "/resolve/" <> B.unpack (urlEncode True (encodeUtf8 name)))
  let req =
        req0
          { redirectCount = 0,
            requestHeaders = ("Accept", "application/json") : authHdr,
            HC.responseTimeout = responseTimeoutMicro timeoutMicro
          }
  result <- E.try $ withResponse req manager $ \res -> do
    let status = HT.statusCode (responseStatus res)
        field = if status < 400 then "status" else "error"
    bs <- brReadSome (responseBody res) statusBodyBytes
    pure $ case J.decode bs of
      Just (J.Object o)
        | Just (J.String t) <- JKM.lookup field o ->
            Right
              NameStatusResp
                { nsStatus = t,
                  nsExpires = jsonField o "expires",
                  nsGraceEnds = jsonField o "graceEnds",
                  nsAuctionEnds = jsonField o "auctionEnds",
                  nsPremium = jsonField o "premium",
                  nsReasonCode = jsonField o "reasonCode"
                }
      _ -> Left (HttpStatusErr status)
  pure (either (Left . HttpFailure) id result)

-- | A field the resolver omits, or sends as null, for the statuses that do not
-- carry it.
jsonField :: J.FromJSON a => J.Object -> Key -> Maybe a
jsonField o k = case J.fromJSON <$> JKM.lookup k o of
  Just (J.Success v) -> Just v
  _ -> Nothing

-- | Enough of a body to reach the status field; the rest is not read.
statusBodyBytes :: Int
statusBodyBytes = 4096

-- | GET <baseUrl>/health; success = reachable with status < 400. The body is
-- size-capped but NOT decoded — the probe only checks reachability.
healthHttp :: ResolverEnv -> IO (Either ResolverError ())
healthHttp env = (() <$) <$> httpGet env "/health"

-- | GET <baseUrl><path>, returning the response body bytes on status < 400
-- within the size cap. Redirects are disabled and Authorization is attached
-- only when configured.
httpGet :: ResolverEnv -> String -> IO (Either ResolverError BL.ByteString)
httpGet ResolverEnv {manager, baseUrl, authHdr, timeoutMicro, maxResponseBytes} path = do
  req0 <- parseRequest (baseUrl <> path)
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
        pure $ if BL.length bs > fromIntegral maxResponseBytes then Left BodyTooLarge else Right bs
  pure (either (Left . HttpFailure) id result)
