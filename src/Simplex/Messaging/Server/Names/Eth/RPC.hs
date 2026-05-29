{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
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
    EthRpcEnv (..),
    EthRpcError (..),
    newEthRpcEnv,
    closeEthRpcEnv,
    ethCallReal,
    fromHex,
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
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Encoding (encodeUtf8)
import Network.HTTP.Client
  ( HttpException,
    Manager,
    Request,
    RequestBody (..),
    brReadSome,
    closeManager,
    method,
    parseRequest,
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
  deriving (Show)

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
  deriving (Show)

-- | Build a Request from a (validated) ethereum_endpoint URL.
buildRequest :: Text -> Maybe RpcAuth -> IO Request
buildRequest endpoint auth_ = do
  req <- parseRequest (T.unpack endpoint)
  pure $
    req
      { method = "POST",
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
  manager <- HC.newManager tlsManagerSettings
  request <- buildRequest endpoint auth_
  sem <- newQSem maxConcurrency
  pure EthRpcEnv {manager, request, sem, maxResponseBytes}

closeEthRpcEnv :: EthRpcEnv -> IO ()
closeEthRpcEnv EthRpcEnv {manager} = closeManager manager

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
          case fromHex (encodeUtf8 result) of
            Right b -> pure (Right b)
            Left e -> pure (Left (InvalidJson e))

toHex :: ByteString -> Text
toHex bs = T.pack $ "0x" <> concatMap byte (B.unpack bs)
  where
    byte c =
      let n = fromEnum c
          (h, l) = quotRem n 16
       in [hexChar h, hexChar l]
    hexChar n
      | n < 10 = toEnum (fromEnum '0' + n)
      | otherwise = toEnum (fromEnum 'a' + n - 10)

fromHex :: ByteString -> Either String ByteString
fromHex bs0 =
  let bs = case B.stripPrefix "0x" bs0 of
        Just rest -> rest
        Nothing -> case B.stripPrefix "0X" bs0 of
          Just rest -> rest
          Nothing -> bs0
   in if B.null bs
        then Right B.empty
        else
          if odd (B.length bs) || not (B.all isHex bs)
            then Left "invalid hex"
            else Right (decodeHex bs)
  where
    isHex c = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')

decodeHex :: ByteString -> ByteString
decodeHex = B.pack . go
  where
    go s
      | B.null s = []
      | otherwise =
          let hi = digit (B.head s)
              lo = digit (B.index s 1)
           in toEnum (16 * hi + lo) : go (B.drop 2 s)
    digit c
      | c >= '0' && c <= '9' = fromEnum c - fromEnum '0'
      | c >= 'a' && c <= 'f' = 10 + fromEnum c - fromEnum 'a'
      | otherwise = 10 + fromEnum c - fromEnum 'A'

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
