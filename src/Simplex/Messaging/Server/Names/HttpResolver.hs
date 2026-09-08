{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StrictData #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TupleSections #-}

-- | HTTP transport for the public-namespace resolver.
--
-- The Python REST resolver (see scripts/resolver/snrc-resolve.py) exposes
--
--   GET /resolve/<name>   -> 200 with a NameRecord JSON document
--                            404 / 410 for names that do not resolve, the body
--                            saying why (reserved, lapsed, never registered)
--                            400 for unknown TLDs, 502 for upstream RPC failures
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
    resolveHttp,
    healthHttp,
  )
where

import qualified Control.Exception as E
import qualified Data.Aeson as J
import Data.Aeson.Key (Key)
import qualified Data.Aeson.KeyMap as JKM
import qualified Data.Aeson.TH as JQ
import qualified Data.Aeson.Types as JT
import Data.Bifunctor (first)
import qualified Data.ByteArray.Encoding as BAE
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import qualified Data.ByteString.Lazy as BL
import Data.Int (Int64)
import Data.Map.Strict (Map)
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
import Simplex.Messaging.Parsers (defaultJSON, dropPrefix)

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

-- | What the resolver says about a name. Only some statuses carry the fields
-- below the status.
data NameStatusResp = NameStatusResp
  { nsStatus :: Text,
    nsExpires :: Maybe Int64,
    nsGraceEnds :: Maybe Int64,
    nsReasonCode :: Maybe Text,
    -- | when the post-grace surcharge decays to nothing
    nsAuctionUntil :: Maybe Int64,
    -- | US cents per year, by label length
    nsRentPrices :: Maybe (Map Int Int64),
    -- | US cents per year for every other length
    nsBasePrice :: Maybe Int64,
    nsMinLabelLength :: Maybe Int
  }
  deriving (Show)

$(JQ.deriveFromJSON defaultJSON {J.fieldLabelModifier = dropPrefix "ns"} ''NameStatusResp)

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

-- | GET <baseUrl>/resolve/<percent-encoded name>, returning the record when the
-- name resolves and what the resolver says about the name either way. The status
-- code cannot tell an unregistered name from a reserved or lapsed one, so on the
-- two codes that carry availability the body is read as well. The name is
-- percent-encoded (every non-unreserved byte per RFC 3986): the resolver expects
-- raw labels, so slashes/punctuation must not alter the path.
resolveHttp :: ResolverEnv -> Text -> IO (Either ResolverError (Maybe NameRecord, Maybe NameStatusResp))
resolveHttp env name =
  (>>= nameResp) <$> httpGet env ("/resolve/" <> B.unpack (urlEncode True (encodeUtf8 name)))
  where
    nameResp (status, bs)
      | status < 400 = (,statusResp bs "status") . Just <$> first InvalidJson (J.eitherDecode bs)
      | status == 404 || status == 410 =
          maybe (Left $ HttpStatusErr status) (Right . (Nothing,) . Just) (statusResp bs "error")
      | otherwise = Left (HttpStatusErr status)

-- | What the resolver says about the name, under "status" on a 200 and "error"
-- on the codes that carry availability. Older resolvers send neither.
statusResp :: BL.ByteString -> Key -> Maybe NameStatusResp
statusResp bs k = case J.decode bs of
  Just (J.Object o) -> do
    v <- JKM.lookup k o
    JT.parseMaybe J.parseJSON (J.Object (JKM.insert "status" v o))
  _ -> Nothing

-- | GET <baseUrl>/health; success = reachable with status < 400. The body is
-- size-capped but NOT decoded — the probe only checks reachability.
healthHttp :: ResolverEnv -> IO (Either ResolverError ())
healthHttp env = (>>= statusOk . fst) <$> httpGet env "/health"
  where
    statusOk status = if status >= 400 then Left (HttpStatusErr status) else Right ()

-- | GET <baseUrl><path>, returning the response status and body bytes within the
-- size cap. Redirects are disabled and Authorization is attached only when
-- configured.
httpGet :: ResolverEnv -> String -> IO (Either ResolverError (Int, BL.ByteString))
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
    bs <- brReadSome (responseBody res) (maxResponseBytes + 1)
    pure $ if BL.length bs > fromIntegral maxResponseBytes then Left BodyTooLarge else Right (status, bs)
  pure (either (Left . HttpFailure) id result)
