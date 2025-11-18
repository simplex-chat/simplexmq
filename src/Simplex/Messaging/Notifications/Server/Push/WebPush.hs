{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# OPTIONS_GHC -Wno-unrecognised-pragmas #-}

{-# HLINT ignore "Use newtype instead of data" #-}

module Simplex.Messaging.Notifications.Server.Push.WebPush where

import Control.Exception (SomeException, fromException, try)
import Control.Logger.Simple (logDebug)
import Control.Monad
import Control.Monad.Except
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Trans.Except (throwE)
import qualified Crypto.Cipher.Types as CT
import Crypto.Hash.Algorithms (SHA256)
import qualified Crypto.MAC.HMAC as HMAC
import qualified Crypto.PubKey.ECC.DH as ECDH
import qualified Crypto.PubKey.ECC.ECDSA as ECDSA
import qualified Crypto.PubKey.ECC.Types as ECC
import Crypto.Random (ChaChaDRG, getRandomBytes)
import Data.Aeson ((.=))
import qualified Data.Aeson as J
import qualified Data.Binary as Bin
import qualified Data.ByteArray as BA
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import qualified Data.ByteString.Base64.URL as B64
import qualified Data.ByteString.Lazy as LB
import Data.IORef
import Data.Int (Int64)
import Data.Text (Text)
import qualified Data.Text.Encoding as T
import Data.Time.Clock.System (getSystemTime, systemSeconds)
import Network.HTTP.Client
import qualified Network.HTTP.Types as N
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Notifications.Protocol (DeviceToken (..), NtfRegCode (..), WPAuth (..), WPKey (..), WPP256dh (..), WPTokenParams (..), WPProvider (..), encodePNMessages, wpAud, wpRequest)
import Simplex.Messaging.Notifications.Server.Push
import Simplex.Messaging.Notifications.Server.Store.Types
import Simplex.Messaging.Util (liftError', safeDecodeUtf8, tshow)
import Simplex.Messaging.Transport.HTTP2.Client (HTTP2Client, getHTTP2Client, defaultHTTP2ClientConfig, HTTP2ClientError, sendRequest, HTTP2Response (..))
import Network.Socket (ServiceName, HostName)
import System.X509.Unix
import qualified Network.HTTP2.Client as H2
import Data.ByteString.Builder (lazyByteString)
import Simplex.Messaging.Encoding.String (StrEncoding(..))
import Data.Bifunctor (first)
import UnliftIO.STM

-- | Vapid
-- | fp: fingerprint, base64url encoded without padding
-- | key: privkey
data VapidKey = VapidKey
  { key :: ECDSA.PrivateKey,
    fp :: ByteString
  }
  deriving (Eq, Show)

mkVapid :: ECDSA.PrivateKey -> VapidKey
mkVapid key = VapidKey {key, fp}
  where
    fp = B64.encodeUnpadded $ C.uncompressEncodePoint $ ECDH.calculatePublic (ECC.getCurveByName ECC.SEC_p256r1) $ ECDSA.private_d key

data WebPushClient = WebPushClient
  { wpConfig :: WebPushConfig,
    cache :: IORef (Maybe WPCache),
    random :: TVar ChaChaDRG
  }

data WebPushConfig = WebPushConfig
  { vapidKey :: VapidKey,
    paddedNtfLength :: Int
  }

data WPCache = WPCache
  { vapidHeader :: ByteString,
    expire :: Int64
  }

getVapidHeader :: VapidKey -> IORef (Maybe WPCache) -> ByteString -> IO ByteString
getVapidHeader vapidK cache uriAuthority = do
  h <- readIORef cache
  now <- systemSeconds <$> getSystemTime
  case h of
    Nothing -> newCacheEntry now
    -- if it expires in 1 min, then we renew - for safety
    Just entry ->
      if expire entry > now + 60
        then pure $ vapidHeader entry
        else newCacheEntry now
  where
    newCacheEntry :: Int64 -> IO ByteString
    newCacheEntry now = do
      -- The new entry expires in one hour
      let expire = now + 3600
      vapidHeader <- mkVapidHeader vapidK uriAuthority expire
      let entry = Just WPCache {vapidHeader, expire}
      atomicWriteIORef cache entry
      pure vapidHeader

-- | With time in input for the tests
getVapidHeader' :: Int64 -> VapidKey -> IORef (Maybe WPCache) -> ByteString -> IO ByteString
getVapidHeader' now vapidK cache uriAuthority = do
  h <- readIORef cache
  case h of
    Nothing -> newCacheEntry
    Just entry ->
      if expire entry > now
        then pure $ vapidHeader entry
        else newCacheEntry
  where
    newCacheEntry :: IO ByteString
    newCacheEntry = do
      -- The new entry expires in one hour
      let expire = now + 3600
      vapidHeader <- mkVapidHeader vapidK uriAuthority expire
      let entry = Just WPCache {vapidHeader, expire}
      atomicWriteIORef cache entry
      pure vapidHeader

-- | mkVapidHeader -> vapid -> endpoint -> expire -> vapid header
mkVapidHeader :: VapidKey -> ByteString -> Int64 -> IO ByteString
mkVapidHeader VapidKey {key, fp} uriAuthority expire = do
  let jwtHeader = mkJWTHeader "ES256" Nothing
      jwtClaims =
        JWTClaims
          { iss = Nothing,
            iat = Nothing,
            exp = Just expire,
            aud = Just $ T.decodeUtf8 $ "https://" <> uriAuthority,
            sub = Just "https://github.com/simplex-chat/simplexmq/"
          }
      jwt = JWTToken jwtHeader jwtClaims
  signedToken <- signedJWTTokenRaw key jwt
  pure $ "vapid t=" <> signedToken <> ",k=" <> fp

wpHTTP2Client :: HostName -> ServiceName -> IO (Either HTTP2ClientError HTTP2Client)
wpHTTP2Client h p = do
  caStore <- Just <$> getSystemCertificateStore
  let config = defaultHTTP2ClientConfig
  getHTTP2Client h p caStore config nop
  where
    nop = pure ()

wpHeaders :: B.ByteString -> [N.Header]
wpHeaders vapidH = [
  -- Why http2-client doesn't accept TTL AND Urgency?
  -- Keeping Urgency for now, the TTL should be around 30 days by default on the push servers
  -- ("TTL", "2592000"), -- 30 days
  ("Urgency", "high"),
  ("Content-Encoding", "aes128gcm"),
  ("Authorization", vapidH)
  -- TODO: topic for pings and interval
  ]

wpHTTP2Req :: B.ByteString -> [(N.HeaderName, B.ByteString)] -> LB.ByteString -> H2.Request
wpHTTP2Req path headers s =  H2.requestBuilder N.methodPost path headers (lazyByteString s)

wpPushProviderClientH2 :: WebPushClient -> HTTP2Client -> PushProviderClient
wpPushProviderClientH2 _ _ NtfTknRec {token = APNSDeviceToken _ _} _ = throwE PPInvalidPusher
wpPushProviderClientH2 c@WebPushClient {wpConfig, cache} http2 tkn@NtfTknRec {token = (WPDeviceToken pp@(WPP p) params)} pn = do
  -- TODO [webpush] this function should accept type that is restricted to WP token (so, possibly WPProvider and WPTokenParams)
  -- parsing will happen in DeviceToken parser, so it won't fail here
  encBody <- body
  vapidH <- liftError' toPPWPError $ try $ getVapidHeader (vapidKey wpConfig) cache $ wpAud pp
  let req = wpHTTP2Req (wpPath params) (wpHeaders vapidH) $ LB.fromStrict encBody
  logDebug $ "HTTP/2 Request to " <> tshow (strEncode p)
  HTTP2Response {response} <- liftHTTPS2 $ sendRequest http2 req Nothing
  let status = H2.responseStatus response
  if status >= Just N.ok200 && status < Just N.status300
  then pure ()
  else throwError $ fromStatusCode status
  where
    body :: ExceptT PushProviderError IO B.ByteString
    body = withExceptT PPCryptoError $ wpEncrypt c tkn params pn
    liftHTTPS2 a = ExceptT $ first PPConnection <$> a

wpPushProviderClientH1 :: WebPushClient -> Manager -> PushProviderClient
wpPushProviderClientH1 _ _ NtfTknRec {token = APNSDeviceToken _ _} _ = throwE PPInvalidPusher
wpPushProviderClientH1 c@WebPushClient {wpConfig, cache} manager tkn@NtfTknRec {token = token@(WPDeviceToken pp params)} pn = do
  -- TODO [webpush] this function should accept type that is restricted to WP token (so, possibly WPProvider and WPTokenParams)
  -- parsing will happen in DeviceToken parser, so it won't fail here
  r <- wpRequest token
  vapidH <- liftError' toPPWPError $ try $ getVapidHeader (vapidKey wpConfig) cache $ wpAud pp
  logDebug $ "Web Push request to " <> tshow (host r)
  encBody <- withExceptT PPCryptoError $ wpEncrypt c tkn params pn
  let req =
        r
          { method = "POST",
            requestHeaders = wpHeaders vapidH,
            requestBody = RequestBodyBS encBody,
            redirectCount = 0
          }
  void $ liftError' toPPWPError $ try $ httpNoBody req manager

-- | encrypt :: UA key -> clear -> cipher
-- | https://www.rfc-editor.org/rfc/rfc8291#section-3.4
wpEncrypt :: WebPushClient -> NtfTknRec -> WPTokenParams -> PushNotification -> ExceptT C.CryptoError IO ByteString
wpEncrypt WebPushClient {wpConfig, random} NtfTknRec {tknDhSecret} params pn = do
  salt <- liftIO $ getRandomBytes 16
  asPrivK <- liftIO $ ECDH.generatePrivate $ ECC.getCurveByName ECC.SEC_p256r1
  pn' <-
    LB.toStrict . J.encode <$> case pn of
      PNVerification (NtfRegCode code) -> do
        (nonce, code') <- encrypt code
        pure $ J.object ["nonce" .= nonce, "verification" .= code']
      PNMessage msgData -> do
        (nonce, msgData') <- encrypt $ encodePNMessages msgData
        pure $ J.object ["nonce" .= nonce, "message" .= msgData']
      PNCheckMessages -> pure $ J.object ["checkMessages" .= True]
  wpEncrypt' (wpKey params) asPrivK salt pn'
  where
    encrypt :: ByteString -> ExceptT C.CryptoError IO (C.CbNonce, Text)
    encrypt ntfData = do
      nonce <- atomically $ C.randomCbNonce random
      encData <- liftEither $ C.cbEncrypt tknDhSecret nonce ntfData $ paddedNtfLength wpConfig
      pure (nonce, safeDecodeUtf8 $ B64.encode encData)

-- | encrypt :: UA key -> AS key -> salt -> clear -> cipher
-- | https://www.rfc-editor.org/rfc/rfc8291#section-3.4
wpEncrypt' :: WPKey -> ECC.PrivateNumber -> ByteString -> ByteString -> ExceptT C.CryptoError IO ByteString
wpEncrypt' WPKey {wpAuth, wpP256dh = WPP256dh uaPubK} asPrivK salt clearT = do
  let uaPubKS = C.uncompressEncodePoint uaPubK
  let asPubKS = C.uncompressEncodePoint $ ECDH.calculatePublic (ECC.getCurveByName ECC.SEC_p256r1) asPrivK
      ecdhSecret = ECDH.getShared (ECC.getCurveByName ECC.SEC_p256r1) asPrivK uaPubK
      prkKey = hmac (unWPAuth wpAuth) ecdhSecret
      keyInfo = "WebPush: info\0" <> uaPubKS <> asPubKS
      ikm = hmac prkKey (keyInfo <> "\x01")
      prk = hmac salt ikm
      cekInfo = "Content-Encoding: aes128gcm\0" :: ByteString
      cek = B.take 16 $ BA.convert $ hmac prk (cekInfo <> "\x01")
      nonceInfo = "Content-Encoding: nonce\0" :: ByteString
      nonce = B.take 12 $ BA.convert $ hmac prk (nonceInfo <> "\x01")
      rs = LB.toStrict $ Bin.encode (4096 :: Bin.Word32) -- with RFC8291, it's ok to always use 4096 because there is only one single record and the final record can be smaller than rs (RFC8188)
      idlen = LB.toStrict $ Bin.encode (65 :: Bin.Word8) -- with RFC8291, keyid is the pubkey, so always 65 bytes
      header = salt <> rs <> idlen <> asPubKS
  iv <- liftEither $ C.gcmIV nonce
  -- The last record uses a padding delimiter octet set to the value 0x02
  (C.AuthTag (CT.AuthTag tag), cipherT) <- C.encryptAES128NoPad (C.Key cek) iv $ clearT <> "\x02"
  -- Uncomment to see intermediate values, to compare with RFC8291 example
  -- liftIO . print $ strEncode (BA.convert ecdhSecret :: ByteString)
  -- liftIO . print . strEncode $ B.take 32 $ BA.convert prkKey
  -- liftIO . print $ strEncode cek
  -- liftIO . print $ strEncode cipherT
  pure $ header <> cipherT <> BA.convert tag
  where
    hmac k v = HMAC.hmac k v :: HMAC.HMAC SHA256

toPPWPError :: SomeException -> PushProviderError
toPPWPError e = case fromException e of
  Just (InvalidUrlException _ _) -> PPWPInvalidUrl
  Just (HttpExceptionRequest _ (StatusCodeException resp _)) -> fromStatusCode (Just $ responseStatus resp)
  _ -> PPWPOtherError e

fromStatusCode :: Maybe N.Status -> PushProviderError
fromStatusCode status
  | status == Just N.status404 = PPWPRemovedEndpoint
  | status == Just N.status410 = PPWPRemovedEndpoint
  | status == Just N.status413 = PPWPRequestTooLong
  | status == Just N.status429 = PPRetryLater
  | status >= Just N.status500 = PPRetryLater
  | otherwise = PPResponseError status "Invalid response"
