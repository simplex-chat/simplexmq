{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StrictData #-}

-- | Ethereum JSON-RPC HTTP transport for the resolver.
--
-- Boundary properties:
--   * Response body read with `brReadSome rpcMaxResponseBytes` — adversarial
--     endpoints cannot exhaust memory with multi-GB bodies.
--   * Concurrency cap via QSem — bursts of cache-miss traffic cannot exhaust
--     the http-client connection pool.
--   * Authorization header attached only when configured.
module Simplex.Messaging.Server.Names.Eth.RPC
  ( RpcAuth (..),
    EthRpcEnv,
    EthRpcError (..),
    newEthRpcEnv,
    closeEthRpcEnv,
    ethCallReal,
    scrubUrl,
  )
where

import Control.Applicative ((<|>))
import Control.Concurrent.QSem (QSem, newQSem, signalQSem, waitQSem)
import qualified Control.Exception as E
import Control.Exception (bracket_)
import qualified Data.Aeson as J
import qualified Data.Aeson.Types as J
import qualified Data.ByteArray.Encoding as BAE
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import qualified Data.ByteString.Lazy as BL
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Encoding (decodeLatin1, encodeUtf8)
import Network.HTTP.Client
  ( HttpException,
    Manager,
    ManagerSettings (..),
    Request,
    RequestBody (..),
    brReadSome,
    method,
    parseRequest,
    redirectCount,
    requestBody,
    requestHeaders,
    responseBody,
    responseStatus,
    withResponse,
  )
import qualified Network.HTTP.Client as HC
import Network.HTTP.Client.TLS (tlsManagerSettings)
import qualified Network.HTTP.Types as HT

data RpcAuth = AuthBearer Text | AuthBasic Text Text

-- | Redacts the bearer token / basic-auth password so an accidental
-- `show` / `tshow` on NamesConfig never lands secrets in logs.
instance Show RpcAuth where
  show (AuthBearer _) = "AuthBearer <redacted>"
  show (AuthBasic u _) = "AuthBasic " <> show u <> " <redacted>"

data EthRpcEnv = EthRpcEnv
  { manager :: Manager,
    request :: Request,
    sem :: QSem,
    maxResponseBytes :: Int
  }

data EthRpcError
  = HttpFailure HttpException
  | HttpStatusErr Int
  | BodyTooLarge
  | InvalidJson String
  | JsonRpcErr Int Text
  | ProbeTimedOut -- startup-probe timeout; resolveName uses its own Timeout
  deriving (Show)

-- | Build a Request from a (validated) ethereum_endpoint URL. Redirects are
-- disabled: an RPC endpoint that responds 3xx is a misconfiguration, and a
-- compromised endpoint could otherwise redirect a credential-bearing POST
-- to a private-IP target (SSRF amplification on top of the host validation
-- performed at config load — DNS rebinding and chained redirects bypass it).
buildRequest :: Text -> Maybe RpcAuth -> IO Request
buildRequest endpoint auth_ = do
  req <- parseRequest (T.unpack endpoint)
  pure $
    req
      { method = "POST",
        redirectCount = 0,
        requestHeaders =
          ("Content-Type", "application/json")
            : maybe [] (pure . authHeader) auth_
      }

authHeader :: RpcAuth -> HT.Header
authHeader = \case
  AuthBearer tok -> ("Authorization", "Bearer " <> encodeUtf8 tok)
  AuthBasic u p ->
    let encoded = BAE.convertToBase BAE.Base64 (encodeUtf8 u <> ":" <> encodeUtf8 p) :: ByteString
     in ("Authorization", "Basic " <> encoded)

newEthRpcEnv :: Text -> Maybe RpcAuth -> Int -> Int -> IO EthRpcEnv
newEthRpcEnv endpoint auth_ maxResponseBytes maxConcurrency = do
  -- managerConnCount defaults to 10; without raising it the configured
  -- rpcMaxConcurrency is silently capped to 10 by http-client's pool.
  manager <- HC.newManager tlsManagerSettings {managerConnCount = max 10 maxConcurrency}
  request <- buildRequest endpoint auth_
  sem <- newQSem maxConcurrency
  pure EthRpcEnv {manager, request, sem, maxResponseBytes}

-- | http-client's `closeManager` is a deprecated no-op since 0.5; the manager
-- is released by the GC finalizer attached to its internal state. We retain
-- the close-env entry point as a hook for any future deterministic cleanup
-- (e.g. draining the QSem) but do nothing here.
closeEthRpcEnv :: EthRpcEnv -> IO ()
closeEthRpcEnv _ = pure ()

-- | Make a single eth_call. `to` is the contract address (20 raw bytes);
-- `dat` is the ABI-encoded call data. Returns the contract return bytes.
ethCallReal :: EthRpcEnv -> ByteString -> ByteString -> IO (Either EthRpcError ByteString)
ethCallReal EthRpcEnv {manager, request, sem, maxResponseBytes} to dat =
  bracket_ (waitQSem sem) (signalQSem sem) $ do
    let body = J.encode (rpcEnvelope to dat)
        req = request {requestBody = RequestBodyLBS body}
    result <- E.try $ withResponse req manager $ \res -> do
      let status = responseStatus res
      if HT.statusCode status >= 400
        then pure (Left (HttpStatusErr (HT.statusCode status)))
        else do
          bs <- brReadSome (responseBody res) (maxResponseBytes + 1)
          if BL.length bs > fromIntegral maxResponseBytes
            then pure (Left BodyTooLarge)
            else pure (parseResult (BL.toStrict bs))
    pure (either (Left . HttpFailure) id result)

rpcEnvelope :: ByteString -> ByteString -> J.Value
rpcEnvelope to dat =
  J.object
    [ "jsonrpc" J..= ("2.0" :: Text),
      "id" J..= (1 :: Int),
      "method" J..= ("eth_call" :: Text),
      "params"
        J..= [ J.object
                 [ "to" J..= toHex to,
                   "data" J..= toHex dat
                 ],
               J.String "latest"
             ]
    ]

parseResult :: ByteString -> Either EthRpcError ByteString
parseResult bs = case J.eitherDecodeStrict bs of
  Left e -> Left (InvalidJson e)
  Right (v :: J.Value) -> case J.parseEither parser v of
    Left e -> Left (InvalidJson e)
    Right r -> r
  where
    parser :: J.Value -> J.Parser (Either EthRpcError ByteString)
    parser = J.withObject "rpc" $ \o -> do
      mErr :: Maybe J.Value <- o J..:? "error"
      case mErr of
        Just (J.Object eo) -> do
          code <- (eo J..: "code") <|> pure (-1 :: Int)
          msg <- (eo J..: "message") <|> pure ("rpc error" :: Text)
          pure (Left (JsonRpcErr code msg))
        _ -> do
          result :: Text <- o J..: "result"
          case decodeHexResult (encodeUtf8 result) of
            Right b -> pure (Right b)
            Left e -> pure (Left (InvalidJson e))

-- | Encode raw bytes as "0x"-prefixed lowercase hex.
toHex :: ByteString -> Text
toHex bs = "0x" <> decodeLatin1 (BAE.convertToBase BAE.Base16 bs)

-- | Decode a "0x"/"0X"-prefixed hex string (the JSON-RPC result shape).
decodeHexResult :: ByteString -> Either String ByteString
decodeHexResult bs =
  BAE.convertFromBase BAE.Base16 $
    fromMaybe bs (B.stripPrefix "0x" bs <|> B.stripPrefix "0X" bs)

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
