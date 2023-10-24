{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}
{-# OPTIONS_GHC -Wno-unrecognised-pragmas #-}

{-# HLINT ignore "Use newtype instead of data" #-}

module Simplex.Messaging.Notifications.Server.Push.APNS where

import Control.Exception (Exception)
import Control.Logger.Simple
import Control.Monad
import Control.Monad.Except
import Control.Monad.IO.Class
import Crypto.Hash.Algorithms (SHA256 (..))
import qualified Crypto.PubKey.ECC.ECDSA as EC
import qualified Crypto.PubKey.ECC.Types as ECT
import Crypto.Random (ChaChaDRG, drgNew)
import qualified Crypto.Store.PKCS8 as PK
import Data.ASN1.BinaryEncoding (DER (..))
import Data.ASN1.Encoding
import Data.ASN1.Types
import Data.Aeson (ToJSON, (.=))
import qualified Data.Aeson as J
import qualified Data.Aeson.Encoding as JE
import qualified Data.Aeson.TH as JQ
import Data.Bifunctor (first)
import qualified Data.ByteString.Base64.URL as U
import Data.ByteString.Builder (lazyByteString)
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Lazy.Char8 as LB
import Data.Int (Int64)
import Data.Map.Strict (Map)
import Data.Maybe (isNothing)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock.System
import qualified Data.X509 as X
import qualified Data.X509.CertificateStore as XS
import Network.HTTP.Types (Status)
import qualified Network.HTTP.Types as N
import Network.HTTP2.Client (Request)
import qualified Network.HTTP2.Client as H
import Network.Socket (HostName, ServiceName)
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Notifications.Protocol
import Simplex.Messaging.Notifications.Server.Push.APNS.Internal
import Simplex.Messaging.Notifications.Server.Store (NtfTknData (..))
import Simplex.Messaging.Parsers (defaultJSON)
import Simplex.Messaging.Protocol (EncNMsgMeta)
import Simplex.Messaging.Transport.HTTP2 (HTTP2Body (..))
import Simplex.Messaging.Transport.HTTP2.Client
import Simplex.Messaging.Util (safeDecodeUtf8)
import System.Environment (getEnv)
import UnliftIO.STM

data JWTHeader = JWTHeader
  { alg :: Text, -- key algorithm, ES256 for APNS
    kid :: Text -- key ID
  }
  deriving (Show)

data JWTClaims = JWTClaims
  { iss :: Text, -- issuer, team ID for APNS
    iat :: Int64 -- issue time, seconds from epoch
  }
  deriving (Show)

data JWTToken = JWTToken JWTHeader JWTClaims
  deriving (Show)

mkJWTToken :: JWTHeader -> Text -> IO JWTToken
mkJWTToken hdr iss = do
  iat <- systemSeconds <$> getSystemTime
  pure $ JWTToken hdr JWTClaims {iss, iat}

type SignedJWTToken = ByteString

$(JQ.deriveToJSON defaultJSON ''JWTHeader)

$(JQ.deriveToJSON defaultJSON ''JWTClaims)

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
  -- this pattern match is specific to APNS key type, it may need to be extended for other push providers
  [PK.Unprotected (X.PrivKeyEC X.PrivKeyEC_Named {privkeyEC_name, privkeyEC_priv})] <- PK.readKeyFile f
  pure EC.PrivateKey {private_curve = ECT.getCurveByName privkeyEC_name, private_d = privkeyEC_priv}

data PushNotification
  = PNVerification NtfRegCode
  | PNMessage PNMessageData
  | -- | PNAlert Text
    PNCheckMessages
  deriving (Show)

data PNMessageData = PNMessageData
  { smpQueue :: SMPQueueNtf,
    ntfTs :: SystemTime,
    nmsgNonce :: C.CbNonce,
    encNMsgMeta :: EncNMsgMeta
  }
  deriving (Show)

instance StrEncoding PNMessageData where
  strEncode PNMessageData {smpQueue, ntfTs, nmsgNonce, encNMsgMeta} =
    strEncode (smpQueue, ntfTs, nmsgNonce, encNMsgMeta)
  strP = do
    (smpQueue, ntfTs, nmsgNonce, encNMsgMeta) <- strP
    pure PNMessageData {smpQueue, ntfTs, nmsgNonce, encNMsgMeta}

data APNSNotification = APNSNotification {aps :: APNSNotificationBody, notificationData :: Maybe J.Value}
  deriving (Show)

data APNSNotificationBody
  = APNSBackground {contentAvailable :: Int}
  | APNSMutableContent {mutableContent :: Int, alert :: APNSAlertBody, category :: Maybe Text}
  | APNSAlert {alert :: APNSAlertBody, badge :: Maybe Int, sound :: Maybe Text, category :: Maybe Text}
  deriving (Show)

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
    apnsPort :: ServiceName,
    http2cfg :: HTTP2ClientConfig,
    caStoreFile :: FilePath
  }

apnsProviderHost :: PushProvider -> HostName
apnsProviderHost = \case
  PPApnsTest -> "localhost"
  PPApnsDev -> "api.sandbox.push.apple.com"
  PPApnsProd -> "api.push.apple.com"

defaultAPNSPushClientConfig :: APNSPushClientConfig
defaultAPNSPushClientConfig =
  APNSPushClientConfig
    { tokenTTL = 1800, -- 30 minutes
      authKeyFileEnv = "APNS_KEY_FILE", -- the environment variables APNS_KEY_FILE and APNS_KEY_ID must be set, or the server would fail to start
      authKeyAlg = "ES256",
      authKeyIdEnv = "APNS_KEY_ID",
      paddedNtfLength = 512,
      appName = "chat.simplex.app",
      appTeamId = "5NN7GUYB6T",
      apnsPort = "443",
      http2cfg = defaultHTTP2ClientConfig {bufferSize = 16384},
      caStoreFile = "/etc/ssl/cert.pem"
    }

data APNSPushClient = APNSPushClient
  { https2Client :: TVar (Maybe HTTP2Client),
    privateKey :: EC.PrivateKey,
    jwtHeader :: JWTHeader,
    jwtToken :: TVar (JWTToken, SignedJWTToken),
    nonceDrg :: TVar ChaChaDRG,
    apnsHost :: HostName,
    apnsCfg :: APNSPushClientConfig
  }

createAPNSPushClient :: HostName -> APNSPushClientConfig -> IO APNSPushClient
createAPNSPushClient apnsHost apnsCfg@APNSPushClientConfig {authKeyFileEnv, authKeyAlg, authKeyIdEnv, appTeamId} = do
  https2Client <- newTVarIO Nothing
  void $ connectHTTPS2 apnsHost apnsCfg https2Client
  privateKey <- readECPrivateKey =<< getEnv authKeyFileEnv
  authKeyId <- T.pack <$> getEnv authKeyIdEnv
  let jwtHeader = JWTHeader {alg = authKeyAlg, kid = authKeyId}
  jwtToken <- newTVarIO =<< mkApnsJWTToken appTeamId jwtHeader privateKey
  nonceDrg <- drgNew >>= newTVarIO
  pure APNSPushClient {https2Client, privateKey, jwtHeader, jwtToken, nonceDrg, apnsHost, apnsCfg}

getApnsJWTToken :: APNSPushClient -> IO SignedJWTToken
getApnsJWTToken APNSPushClient {apnsCfg = APNSPushClientConfig {appTeamId, tokenTTL}, privateKey, jwtHeader, jwtToken} = do
  (jwt, signedJWT) <- readTVarIO jwtToken
  age <- jwtTokenAge jwt
  if age < tokenTTL
    then pure signedJWT
    else do
      t@(_, signedJWT') <- mkApnsJWTToken appTeamId jwtHeader privateKey
      atomically $ writeTVar jwtToken t
      pure signedJWT'
  where
    jwtTokenAge (JWTToken _ JWTClaims {iat}) = subtract iat . systemSeconds <$> getSystemTime

mkApnsJWTToken :: Text -> JWTHeader -> EC.PrivateKey -> IO (JWTToken, SignedJWTToken)
mkApnsJWTToken appTeamId jwtHeader privateKey = do
  jwt <- mkJWTToken jwtHeader appTeamId
  signedJWT <- signedJWTToken privateKey jwt
  pure (jwt, signedJWT)

connectHTTPS2 :: HostName -> APNSPushClientConfig -> TVar (Maybe HTTP2Client) -> IO (Either HTTP2ClientError HTTP2Client)
connectHTTPS2 apnsHost APNSPushClientConfig {apnsPort, http2cfg, caStoreFile} https2Client = do
  caStore_ <- XS.readCertificateStore caStoreFile
  when (isNothing caStore_) $ putStrLn $ "Error loading CertificateStore from " <> caStoreFile
  r <- getHTTP2Client apnsHost apnsPort caStore_ http2cfg disconnected
  case r of
    Right client -> atomically . writeTVar https2Client $ Just client
    Left e -> putStrLn $ "Error connecting to APNS: " <> show e
  pure r
  where
    disconnected = atomically $ writeTVar https2Client Nothing

getApnsHTTP2Client :: APNSPushClient -> IO (Either HTTP2ClientError HTTP2Client)
getApnsHTTP2Client APNSPushClient {https2Client, apnsHost, apnsCfg} =
  readTVarIO https2Client >>= maybe (connectHTTPS2 apnsHost apnsCfg https2Client) (pure . Right)

disconnectApnsHTTP2Client :: APNSPushClient -> IO ()
disconnectApnsHTTP2Client APNSPushClient {https2Client} =
  readTVarIO https2Client >>= mapM_ closeHTTP2Client >> atomically (writeTVar https2Client Nothing)

ntfCategoryCheckMessage :: Text
ntfCategoryCheckMessage = "NTF_CAT_CHECK_MESSAGE"

apnsNotification :: NtfTknData -> C.CbNonce -> Int -> PushNotification -> Either C.CryptoError APNSNotification
apnsNotification NtfTknData {tknDhSecret} nonce paddedLen = \case
  PNVerification (NtfRegCode code) ->
    encrypt code $ \code' ->
      apn APNSBackground {contentAvailable = 1} . Just $ J.object ["nonce" .= nonce, "verification" .= code']
  PNMessage pnMessageData ->
    encrypt (strEncode pnMessageData) $ \ntfData ->
      apn apnMutableContent . Just $ J.object ["nonce" .= nonce, "message" .= ntfData]
  -- PNAlert text -> Right $ apn (apnAlert $ APNSAlertText text) Nothing
  PNCheckMessages -> Right $ apn APNSBackground {contentAvailable = 1} . Just $ J.object ["checkMessages" .= True]
  where
    encrypt :: ByteString -> (Text -> APNSNotification) -> Either C.CryptoError APNSNotification
    encrypt ntfData f = f . safeDecodeUtf8 . U.encode <$> C.cbEncrypt tknDhSecret nonce ntfData paddedLen
    apn aps notificationData = APNSNotification {aps, notificationData}
    apnMutableContent = APNSMutableContent {mutableContent = 1, alert = APNSAlertText "Encrypted message or another app event", category = Just ntfCategoryCheckMessage}

-- apnAlert alert = APNSAlert {alert, badge = Nothing, sound = Nothing, category = Nothing}

$(JQ.deriveToJSON apnsJSONOptions ''APNSNotificationBody)

$(JQ.deriveToJSON defaultJSON ''APNSNotification)

apnsRequest :: APNSPushClient -> ByteString -> APNSNotification -> IO Request
apnsRequest c tkn ntf@APNSNotification {aps} = do
  signedJWT <- getApnsJWTToken c
  pure $ H.requestBuilder N.methodPost path (headers signedJWT) (lazyByteString $ J.encode ntf)
  where
    path = "/3/device/" <> tkn
    headers signedJWT =
      [ (hApnsTopic, appName $ apnsCfg (c :: APNSPushClient)),
        (hApnsPushType, pushType aps),
        (N.hAuthorization, "bearer " <> signedJWT)
      ]
        <> [(hApnsPriority, "5") | isBackground aps]
    isBackground = \case
      APNSBackground {} -> True
      _ -> False
    pushType = \case
      APNSBackground {} -> "background"
      _ -> "alert"

data PushProviderError
  = PPConnection HTTP2ClientError
  | PPCryptoError C.CryptoError
  | PPResponseError (Maybe Status) Text
  | PPTokenInvalid
  | PPRetryLater
  | PPPermanentError
  deriving (Show, Exception)

type PushProviderClient = NtfTknData -> PushNotification -> ExceptT PushProviderError IO ()

-- this is not a newtype on purpose to have a correct JSON encoding as a record
data APNSErrorResponse = APNSErrorResponse {reason :: Text}

$(JQ.deriveFromJSON defaultJSON ''APNSErrorResponse)

apnsPushProviderClient :: APNSPushClient -> PushProviderClient
apnsPushProviderClient c@APNSPushClient {nonceDrg, apnsCfg} tkn@NtfTknData {token = DeviceToken _ tknStr} pn = do
  http2 <- liftHTTPS2 $ getApnsHTTP2Client c
  nonce <- atomically $ C.pseudoRandomCbNonce nonceDrg
  apnsNtf <- liftEither $ first PPCryptoError $ apnsNotification tkn nonce (paddedNtfLength apnsCfg) pn
  req <- liftIO $ apnsRequest c tknStr apnsNtf
  -- TODO when HTTP2 client is thread-safe, we can use sendRequestDirect
  HTTP2Response {response, respBody = HTTP2Body {bodyHead}} <- liftHTTPS2 $ sendRequest http2 req Nothing
  let status = H.responseStatus response
      reason' = maybe "" reason $ J.decodeStrict' bodyHead
  logDebug $ "APNS response: " <> T.pack (show status) <> " " <> reason'
  result status reason'
  where
    result :: Maybe Status -> Text -> ExceptT PushProviderError IO ()
    result status reason'
      | status == Just N.ok200 = pure ()
      | status == Just N.badRequest400 =
          case reason' of
            "BadDeviceToken" -> throwError PPTokenInvalid
            "DeviceTokenNotForTopic" -> throwError PPTokenInvalid
            "TopicDisallowed" -> throwError PPPermanentError
            _ -> err status reason'
      | status == Just N.forbidden403 = case reason' of
          "ExpiredProviderToken" -> throwError PPPermanentError -- there should be no point retrying it as the token was refreshed
          "InvalidProviderToken" -> throwError PPPermanentError
          _ -> err status reason'
      | status == Just N.gone410 = throwError PPTokenInvalid
      | status == Just N.serviceUnavailable503 = liftIO (disconnectApnsHTTP2Client c) >> throwError PPRetryLater
      -- Just tooManyRequests429 -> TooManyRequests - too many requests for the same token
      | otherwise = err status reason'
    err :: Maybe Status -> Text -> ExceptT PushProviderError IO ()
    err s r = throwError $ PPResponseError s r
    liftHTTPS2 a = ExceptT $ first PPConnection <$> a
