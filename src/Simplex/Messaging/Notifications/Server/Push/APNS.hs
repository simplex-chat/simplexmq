{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiWayIf #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

module Simplex.Messaging.Notifications.Server.Push.APNS where

import Control.Monad.Except
import Crypto.Hash.Algorithms (SHA256 (..))
import qualified Crypto.PubKey.ECC.ECDSA as EC
import qualified Crypto.PubKey.ECC.Types as ECT
import Crypto.Random (ChaChaDRG, drgNew)
import qualified Crypto.Store.PKCS8 as PK
import Data.ASN1.BinaryEncoding (DER (..))
import Data.ASN1.Encoding
import Data.ASN1.Types
import Data.Aeson (FromJSON, ToJSON, (.=))
import qualified Data.Aeson as J
import qualified Data.Aeson.Encoding as JE
import Data.Bifunctor (first)
import qualified Data.ByteString.Base64.URL as U
import Data.ByteString.Builder (lazyByteString)
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Lazy.Char8 as LB
import qualified Data.CaseInsensitive as CI
import Data.Int (Int64)
import Data.Map.Strict (Map)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Encoding (decodeUtf8With)
import Data.Time.Clock.System
import qualified Data.X509 as X
import GHC.Generics
import Network.HTTP.Types (HeaderName, Status, hAuthorization, methodPost)
import qualified Network.HTTP.Types as N
import Network.HTTP2.Client (Request)
import qualified Network.HTTP2.Client as H
import Network.Socket (HostName, ServiceName)
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Notifications.Protocol
import Simplex.Messaging.Notifications.Server.Subscriptions (NtfTknData (..))
import Simplex.Messaging.Protocol (NotifierId, SMPServer)
import Simplex.Messaging.Transport.Client.HTTP2
import System.Environment (getEnv)
import UnliftIO.STM

data JWTHeader = JWTHeader
  { alg :: Text, -- key algorithm, ES256 for APNS
    kid :: Text -- key ID
  }
  deriving (Show, Generic)

instance ToJSON JWTHeader where toEncoding = J.genericToEncoding J.defaultOptions

data JWTClaims = JWTClaims
  { iss :: Text, -- issuer, team ID for APNS
    iat :: Int64 -- issue time, seconds from epoch
  }
  deriving (Show, Generic)

instance ToJSON JWTClaims where toEncoding = J.genericToEncoding J.defaultOptions

data JWTToken = JWTToken JWTHeader JWTClaims
  deriving (Show)

mkJWTToken :: JWTHeader -> Text -> IO JWTToken
mkJWTToken hdr iss = do
  iat <- systemSeconds <$> getSystemTime
  pure $ JWTToken hdr JWTClaims {iss, iat}

type SignedJWTToken = ByteString

signedJWTToken :: EC.PrivateKey -> JWTToken -> IO SignedJWTToken
signedJWTToken pk (JWTToken hdr claims) = do
  let hc = jwtEncode hdr <> "." <> jwtEncode claims
  sig <- EC.sign pk SHA256 hc
  pure $ hc <> "." <> serialize sig
  where
    jwtEncode :: ToJSON a => a -> ByteString
    jwtEncode = U.encodeUnpadded . LB.toStrict . J.encode
    serialize sig = U.encodeUnpadded $ encodeASN1' DER [Start Sequence, IntVal (EC.sign_r sig), IntVal (EC.sign_s sig), End Sequence]

readECPrivateKey :: FilePath -> IO EC.PrivateKey
readECPrivateKey f = do
  -- TODO this is specific to APNS key
  [PK.Unprotected (X.PrivKeyEC X.PrivKeyEC_Named {privkeyEC_name, privkeyEC_priv})] <- PK.readKeyFile f
  pure EC.PrivateKey {private_curve = ECT.getCurveByName privkeyEC_name, private_d = privkeyEC_priv}

data PushNotification = PNVerification NtfRegCode | PNMessage SMPServer NotifierId | PNAlert Text | PNPing

data APNSNotification = APNSNotification {aps :: APNSNotificationBody, notificationData :: Maybe J.Value}
  deriving (Show, Generic)

instance ToJSON APNSNotification where
  toJSON = J.genericToJSON J.defaultOptions {J.omitNothingFields = True}
  toEncoding = J.genericToEncoding J.defaultOptions {J.omitNothingFields = True}

data APNSNotificationBody
  = APNSAlert {alert :: APNSAlertBody, badge :: Maybe Int, sound :: Maybe Text, category :: Maybe Text}
  | APNSBackground {contentAvailable :: Int}
  | APNSMutableContent {mutableContent :: Int, alert :: APNSAlertBody, category :: Maybe Text}
  deriving (Show, Generic)

apnsJSONOptions :: J.Options
apnsJSONOptions = J.defaultOptions {J.omitNothingFields = True, J.sumEncoding = J.UntaggedValue, J.constructorTagModifier = J.camelTo2 '-'}

instance ToJSON APNSNotificationBody where
  toJSON = J.genericToJSON apnsJSONOptions
  toEncoding = J.genericToEncoding apnsJSONOptions

type APNSNotificationData = Map Text Text

data APNSAlertBody = APNSAlertObject {title :: Text, subtitle :: Text, body :: Text} | APNSAlertText Text
  deriving (Show)

instance ToJSON APNSAlertBody where
  toEncoding = \case
    APNSAlertObject {title, subtitle, body} -> J.pairs $ "title" .= title <> "subtitle" .= subtitle <> "body" .= body
    APNSAlertText t -> JE.text t
  toJSON = \case
    APNSAlertObject {title, subtitle, body} -> J.object ["title" .= title, "subtitle" .= subtitle, "body" .= body]
    APNSAlertText t -> J.String t

-- APNS notification types
--
-- Visible alerts:
-- {
--    "aps" : {
--       "alert" : {
--          "title" : "Game Request",
--          "subtitle" : "Five Card Draw",
--          "body" : "Bob wants to play poker"
--       },
--       "badge" : 9,
--       "sound" : "bingbong.aiff",
--       "category" : "GAME_INVITATION"
--    },
--    "gameID" : "12345678"
-- }
--
-- Simple text alert:
-- {"aps":{"alert":"you have a new message"}}
--
-- Background notification to fetch content
-- {"aps":{"content-available":1}}
--
-- Mutable content notification that must be shown but can be processed before before being shown (up to 30 sec)
-- {
--    "aps" : {
--       "category" : "SECRET",
--       "mutable-content" : 1,
--       "alert" : {
--          "title" : "Secret Message!",
--          "body"  : "(Encrypted)"
--      },
--    },
--    "ENCRYPTED_DATA" : "Salted__·öîQÊ$UDì_¶Ù∞èΩ^¬%gq∞NÿÒQùw"
-- }

data APNSPushClientConfig = APNSPushClientConfig
  { tokenTTL :: Int64,
    authKeyFileEnv :: String,
    authKeyAlg :: Text,
    authKeyIdEnv :: String,
    paddedNtfLength :: Int,
    appName :: ByteString,
    appTeamId :: Text,
    apnHost :: HostName,
    apnPort :: ServiceName,
    https2cfg :: HTTP2SClientConfig
  }
  deriving (Show)

defaultAPNSPushClientConfig :: APNSPushClientConfig
defaultAPNSPushClientConfig =
  APNSPushClientConfig
    { tokenTTL = 1200, -- 20 minutes
      authKeyFileEnv = "APNS_KEY_FILE", -- the environment variables APNS_KEY_FILE and APNS_KEY_ID must be set, or the server would fail to start
      authKeyAlg = "ES256",
      authKeyIdEnv = "APNS_KEY_ID",
      paddedNtfLength = 512,
      appName = "chat.simplex.app",
      appTeamId = "5NN7GUYB6T",
      apnHost = "api.sandbox.push.apple.com",
      apnPort = "443",
      https2cfg = defaultHTTP2SClientConfig
    }

data APNSPushClient = APNSPushClient
  { https2Client :: TVar (Maybe HTTPS2Client),
    privateKey :: EC.PrivateKey,
    jwtHeader :: JWTHeader,
    jwtToken :: TVar (JWTToken, SignedJWTToken),
    nonceDrg :: TVar ChaChaDRG,
    config :: APNSPushClientConfig
  }

createAPNSPushClient :: APNSPushClientConfig -> IO APNSPushClient
createAPNSPushClient config@APNSPushClientConfig {authKeyFileEnv, authKeyAlg, authKeyIdEnv, appTeamId} = do
  https2Client <- newTVarIO Nothing
  void $ connectHTTPS2 config https2Client
  privateKey <- readECPrivateKey =<< getEnv authKeyFileEnv
  authKeyId <- T.pack <$> getEnv authKeyIdEnv
  let jwtHeader = JWTHeader {alg = authKeyAlg, kid = authKeyId}
  jwtToken <- newTVarIO =<< mkApnsJWTToken appTeamId jwtHeader privateKey
  nonceDrg <- drgNew >>= newTVarIO
  pure APNSPushClient {https2Client, privateKey, jwtHeader, jwtToken, nonceDrg, config}

getApnsJWTToken :: APNSPushClient -> IO SignedJWTToken
getApnsJWTToken APNSPushClient {config = APNSPushClientConfig {appTeamId, tokenTTL}, privateKey, jwtHeader, jwtToken} = do
  (jwt, signedJWT) <- readTVarIO jwtToken
  age <- jwtTokenAge jwt
  if age < tokenTTL
    then pure signedJWT
    else do
      t@(_, signedJWT') <- mkApnsJWTToken appTeamId jwtHeader privateKey
      atomically $ writeTVar jwtToken t
      pure signedJWT'
  where
    jwtTokenAge (JWTToken _ JWTClaims {iat}) = (iat -) . systemSeconds <$> getSystemTime

mkApnsJWTToken :: Text -> JWTHeader -> EC.PrivateKey -> IO (JWTToken, SignedJWTToken)
mkApnsJWTToken appTeamId jwtHeader privateKey = do
  jwt <- mkJWTToken jwtHeader appTeamId
  signedJWT <- signedJWTToken privateKey jwt
  pure (jwt, signedJWT)

connectHTTPS2 :: APNSPushClientConfig -> TVar (Maybe HTTPS2Client) -> IO (Either HTTPS2ClientError HTTPS2Client)
connectHTTPS2 APNSPushClientConfig {apnHost, apnPort, https2cfg} https2Client = do
  r <- getHTTPS2Client apnHost apnPort https2cfg disconnected
  case r of
    Right client -> atomically . writeTVar https2Client $ Just client
    Left e -> putStrLn $ "Error connecting to APNS: " <> show e
  pure r
  where
    disconnected = atomically $ writeTVar https2Client Nothing

getApnsHTTP2Client :: APNSPushClient -> IO (Either HTTPS2ClientError HTTPS2Client)
getApnsHTTP2Client APNSPushClient {https2Client, config} =
  readTVarIO https2Client >>= maybe (connectHTTPS2 config https2Client) (pure . Right)

disconnectApnsHTTP2Client :: APNSPushClient -> IO ()
disconnectApnsHTTP2Client APNSPushClient {https2Client} =
  readTVarIO https2Client >>= mapM_ closeHTTPS2Client >> atomically (writeTVar https2Client Nothing)

apnsNotification :: NtfTknData -> C.CbNonce -> Int -> PushNotification -> Either C.CryptoError APNSNotification
apnsNotification NtfTknData {tknDhSecret} nonce paddedLen = \case
  PNVerification (NtfRegCode code) ->
    encrypt code $ \code' ->
      apn APNSBackground {contentAvailable = 1} . Just $ J.object ["verification" .= code']
  PNMessage srv nId ->
    encrypt (strEncode srv <> "/" <> strEncode nId) $ \ntfQueue ->
      apn apnMutableContent . Just $ J.object ["checkMessage" .= ntfQueue]
  PNAlert text -> Right $ apn (apnAlert $ APNSAlertText text) Nothing
  PNPing -> Right $ apn APNSBackground {contentAvailable = 1} . Just $ J.object ["checkMessages" .= True]
  where
    encrypt :: ByteString -> (Text -> APNSNotification) -> Either C.CryptoError APNSNotification
    encrypt ntfData f = f . safeDecodeUtf8 . U.encode <$> C.cbEncrypt tknDhSecret nonce ntfData paddedLen
    apn aps notificationData = APNSNotification {aps, notificationData}
    apnMutableContent = APNSMutableContent {mutableContent = 1, alert = APNSAlertText "Encrypted message or some other app event", category = Nothing}
    apnAlert alert = APNSAlert {alert, badge = Nothing, sound = Nothing, category = Nothing}
    safeDecodeUtf8 = decodeUtf8With onError where onError _ _ = Just '?'

apnsRequest :: APNSPushClient -> ByteString -> APNSNotification -> IO Request
apnsRequest c tkn ntf@APNSNotification {aps} = do
  signedJWT <- getApnsJWTToken c
  pure $ H.requestBuilder methodPost path (headers signedJWT) (lazyByteString $ J.encode ntf)
  where
    path = "/3/device/" <> tkn
    headers signedJWT =
      [ (hApnsTopic, appName $ config (c :: APNSPushClient)),
        (hApnsPushType, pushType aps),
        (hAuthorization, "bearer " <> signedJWT)
      ]
        <> [(hApnsPriority, "5") | isBackground aps]
    isBackground = \case
      APNSBackground {} -> True
      _ -> False
    pushType = \case
      APNSBackground {} -> "background"
      _ -> "alert"

data APNSPushClientError
  = ACEConnection HTTPS2ClientError
  | ACECryptError C.CryptoError
  | ACEResponseError (Maybe Status) Text
  | ACETokenInvalid
  | ACERetryLater
  | ACEPermanentError
  deriving (Show)

newtype APNSErrorReponse = APNSErrorReponse {reason :: Text}
  deriving (Generic, FromJSON)

apnsSendNotification :: APNSPushClient -> NtfTknData -> PushNotification -> ExceptT APNSPushClientError IO ()
apnsSendNotification c@APNSPushClient {nonceDrg, config} tkn@NtfTknData {token = DeviceToken PPApple tknStr} pn = do
  http2 <- liftHTTPS2 $ getApnsHTTP2Client c
  nonce <- atomically $ C.pseudoRandomCbNonce nonceDrg
  apnsNtf <- liftEither $ first ACECryptError $ apnsNotification tkn nonce (paddedNtfLength config) pn
  req <- liftIO $ apnsRequest c tknStr apnsNtf
  HTTP2Response {response, respBody} <- liftHTTPS2 $ sendRequest http2 req
  let status = H.responseStatus response
      reason = fromMaybe "" $ J.decodeStrict' =<< respBody
  result status reason
  where
    result :: Maybe Status -> Text -> ExceptT APNSPushClientError IO ()
    result status reason
      | status == Just N.ok200 = pure ()
      | status == Just N.badRequest400 =
        case reason of
          "BadDeviceToken" -> throwError ACETokenInvalid
          "DeviceTokenNotForTopic" -> throwError ACETokenInvalid
          "TopicDisallowed" -> throwError ACEPermanentError
          _ -> err status reason
      | status == Just N.forbidden403 = case reason of
        "ExpiredProviderToken" -> throwError ACEPermanentError -- there should be no point retrying it as the token was refreshed
        "InvalidProviderToken" -> throwError ACEPermanentError
        _ -> err status reason
      | status == Just N.gone410 = throwError ACETokenInvalid
      | status == Just N.serviceUnavailable503 = liftIO (disconnectApnsHTTP2Client c) >> throwError ACERetryLater
      -- Just tooManyRequests429 -> TODO TooManyRequests - too many requests for the same token
      | otherwise = err status reason
    err :: Maybe Status -> Text -> ExceptT APNSPushClientError IO ()
    err s r = throwError $ ACEResponseError s r
    liftHTTPS2 a = ExceptT $ first ACEConnection <$> a

hApnsTopic :: HeaderName
hApnsTopic = CI.mk "apns-topic"

hApnsPushType :: HeaderName
hApnsPushType = CI.mk "apns-push-type"

hApnsPriority :: HeaderName
hApnsPriority = CI.mk "apns-priority"
