{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiWayIf #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

module Simplex.Messaging.Notifications.Server.Push.APNS where

import Control.Concurrent.STM
import Control.Monad.Except
import Crypto.Hash.Algorithms (SHA256 (..))
import qualified Crypto.PubKey.ECC.ECDSA as EC
import qualified Crypto.PubKey.ECC.Types as ECT
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
import Data.Text.Encoding (decodeUtf8With)
import Data.Time.Clock.System
import qualified Data.X509 as X
import GHC.Generics
import Network.HTTP.Types (HeaderName, Status, hAuthorization, methodPost)
import qualified Network.HTTP.Types as N
import Network.HTTP2.Client (Request)
import qualified Network.HTTP2.Client as H
import Network.Socket (HostName, ServiceName)
import Simplex.Messaging.Notifications.Protocol
import Simplex.Messaging.Notifications.Server.Subscriptions (NtfTknData (..))
import Simplex.Messaging.Protocol (NotifierId, SMPServer)
import Simplex.Messaging.Transport.Client.HTTP2

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

-- {"aps":{"alert":"you have a new message"}}

-- {"aps":{"content-available":1}}

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
    authKeyFile :: FilePath,
    authKeyAlg :: Text,
    authKeyId :: Text,
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
    { tokenTTL = 900, -- 15 minutes
      authKeyFile = "", -- make it env
      authKeyAlg = "ES256",
      authKeyId = "", -- make it env
      paddedNtfLength = 2000,
      appName = "chat.simplex.app", -- make it env
      appTeamId = "5NN7GUYB6T", -- make it env
      apnHost = "api.sandbox.push.apple.com",
      apnPort = "443",
      https2cfg = defaultHTTP2SClientConfig
    }

data APNSPushClient = APNSPushClient
  { https2Client :: TVar (Maybe HTTPS2Client),
    privateKey :: EC.PrivateKey,
    jwtHeader :: JWTHeader,
    jwtToken :: TVar (JWTToken, SignedJWTToken),
    config :: APNSPushClientConfig
  }

createAPNSPushClient :: APNSPushClientConfig -> IO APNSPushClient
createAPNSPushClient config@APNSPushClientConfig {authKeyFile, authKeyAlg, authKeyId, appTeamId} = do
  https2Client <- newTVarIO Nothing
  void $ connectHTTPS2 config https2Client
  privateKey <- readECPrivateKey authKeyFile
  let jwtHeader = JWTHeader {alg = authKeyAlg, kid = authKeyId}
  -- jwt <- mkJWTToken jwtHeader appTeamId
  -- signedJWT <- signedJWTToken privateKey jwt
  -- jwtToken <- newTVarIO (jwt, signedJWT)
  jwtToken <- newTVarIO =<< mkApnsJWTToken appTeamId jwtHeader privateKey
  pure APNSPushClient {https2Client, privateKey, jwtHeader, jwtToken, config}

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

-- apnsNotification :: NtfTknData -> C.CbNonce -> Int -> PushNotification -> APNSNotification
apnsNotification :: PushNotification -> APNSNotification
apnsNotification = \case
  PNVerification code -> apn APNSBackground {contentAvailable = 1} . Just $ J.object ["verification" .= code]
  PNMessage smpServer notifierId -> apn apnMutableContent . Just $ J.object ["smpServer" .= smpServer, "notifierId" .= safeDecodeUtf8 notifierId]
  PNAlert text -> apn (apnAlert $ APNSAlertText text) Nothing
  PNPing -> apn APNSBackground {contentAvailable = 1} . Just $ J.object ["checkMessages" .= True]
  where
    -- TODO ecrypt notification data
    apn aps notificationData = APNSNotification {aps, notificationData}
    -- encrypt :: J.Value -> Text
    -- encrypt ntfData = safeUtf8Decode . LB.toStrict $ J.encode ntfData
    -- encrypt ntfData = C.cbEncrypt tknDhSecret nonce (LB.toStrict $ J.encode ntfData) paddedLen
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

data APNSPushClientError = ACEConnection HTTPS2ClientError | ACEResponseError (Maybe Status) Text | ACETokenInvalid | ACERetryLater | ACEStopServer
  deriving (Show)

newtype APNSErrorReponse = APNSErrorReponse {reason :: Text}
  deriving (Generic, FromJSON)

apnsSendNotification :: APNSPushClient -> ByteString -> PushNotification -> ExceptT APNSPushClientError IO ()
apnsSendNotification c tkn pn = do
  http2 <- liftHTTPS2 $ getApnsHTTP2Client c
  req <- liftIO . apnsRequest c tkn $ apnsNotification pn
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
          "TopicDisallowed" -> throwError ACEStopServer
          _ -> err status reason
      | status == Just N.forbidden403 = case reason of
        "ExpiredProviderToken" -> throwError ACEStopServer
        "InvalidProviderToken" -> throwError ACEStopServer
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
