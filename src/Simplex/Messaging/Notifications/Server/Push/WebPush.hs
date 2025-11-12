{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE GADTs #-}
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
import Crypto.Hash.Algorithms (SHA256)
import qualified Crypto.MAC.HMAC as HMAC
import qualified Crypto.PubKey.ECC.DH as ECDH
import qualified Crypto.PubKey.ECC.Types as ECC
import Crypto.Random (MonadRandom(getRandomBytes))
import Data.Aeson ((.=))
import qualified Data.Aeson as J
import qualified Data.Binary as Bin
import qualified Data.ByteArray as BA
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import qualified Data.ByteString.Lazy as BL
import Network.HTTP.Client
import qualified Network.HTTP.Types as N
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Notifications.Protocol (DeviceToken (..), PushType (..), WPAuth (..), WPKey (..), WPTokenParams (..), WPP256dh (..), uncompressEncodePoint, wpRequest)
import Simplex.Messaging.Notifications.Server.Push
import Simplex.Messaging.Util (liftError', tshow)

wpPushProviderClient :: Manager -> PushProviderClient 'WebPush
wpPushProviderClient mg _ t@(WPDeviceToken _ params) pn = do
  -- TODO [webpush] this function should accept type that is restricted to WP token (so, possibly WPProvider and WPTokenParams)
  -- parsing will happen in DeviceToken parser, so it won't fail here
  r <- wpRequest t
  logDebug $ "Web Push request to " <> tshow (host r)
  encBody <- withExceptT PPCryptoError $ wpEncrypt (wpKey params) (BL.toStrict $ encodeWPN pn)
  let requestHeaders =
        [ ("TTL", "2592000"), -- 30 days
          ("Urgency", "high"),
          ("Content-Encoding", "aes128gcm")
    -- TODO: topic for pings and interval
        ]
      req =
        r
          { method = "POST",
            requestHeaders,
            requestBody = RequestBodyBS encBody,
            redirectCount = 0
          }
  void $ liftError' toPPWPError $ try $ httpNoBody req mg

-- | encrypt :: UA key -> clear -> cipher
-- | https://www.rfc-editor.org/rfc/rfc8291#section-3.4
wpEncrypt :: WPKey -> ByteString -> ExceptT C.CryptoError IO ByteString
wpEncrypt wpKey clearT = do
  salt :: ByteString <- liftIO $ getRandomBytes 16
  asPrivK <- liftIO $ ECDH.generatePrivate $ ECC.getCurveByName ECC.SEC_p256r1
  wpEncrypt' wpKey asPrivK salt clearT

-- | encrypt :: UA key -> AS key -> salt -> clear -> cipher
-- | https://www.rfc-editor.org/rfc/rfc8291#section-3.4
wpEncrypt' :: WPKey -> ECC.PrivateNumber -> ByteString -> ByteString -> ExceptT C.CryptoError IO ByteString
wpEncrypt' WPKey {wpAuth, wpP256dh = WPP256dh uaPubK} asPrivK salt clearT = do
  let uaPubKS = uncompressEncodePoint $ uaPubK
  let asPubKS = uncompressEncodePoint . ECDH.calculatePublic (ECC.getCurveByName ECC.SEC_p256r1) $ asPrivK
      ecdhSecret = ECDH.getShared (ECC.getCurveByName ECC.SEC_p256r1) asPrivK uaPubK
      prkKey = hmac (unWPAuth wpAuth) ecdhSecret
      keyInfo = "WebPush: info\0" <> uaPubKS <> asPubKS
      ikm = hmac prkKey (keyInfo <> "\x01")
      prk = hmac salt ikm
      cekInfo = "Content-Encoding: aes128gcm\0" :: ByteString
      cek = B.take 16 $ BA.convert $ hmac prk (cekInfo <> "\x01")
      nonceInfo = "Content-Encoding: nonce\0" :: ByteString
      nonce = B.take 12 $ BA.convert $ hmac prk (nonceInfo <> "\x01")
      rs = BL.toStrict $ Bin.encode (4096 :: Bin.Word32) -- with RFC8291, it's ok to always use 4096 because there is only one single record and the final record can be smaller than rs (RFC8188)
      idlen = BL.toStrict $ Bin.encode (65 :: Bin.Word8) -- with RFC8291, keyid is the pubkey, so always 65 bytes
      header = salt <> rs <> idlen <> asPubKS
  iv <- ivFrom nonce
  -- The last record uses a padding delimiter octet set to the value 0x02
  (C.AuthTag tag, cipherT) <- C.encryptAES128NoPad (C.Key cek) iv $ clearT <> "\x02"
  -- Uncomment to see intermediate values, to compare with RFC8291 example
  -- liftIO . print $ strEncode (BA.convert ecdhSecret :: ByteString)
  -- liftIO . print . strEncode $ takeHM 32 prkKey
  -- liftIO . print $ strEncode cek
  -- liftIO . print $ strEncode cipherT
  pure $ header <> cipherT <> BA.convert tag
  where
    hmac k v = HMAC.hmac k v :: HMAC.HMAC SHA256
    ivFrom :: ByteString -> ExceptT C.CryptoError IO C.GCMIV
    ivFrom s = liftEither $ C.gcmIV s

encodeWPN :: PushNotification -> BL.ByteString
encodeWPN pn = J.encode $ case pn of
  PNVerification code -> J.object ["verification" .= code]
  -- This hack prevents sending unencrypted message metadata in notifications, as we do not use it in the client - it simply receives all messages on each notification.
  -- If we decide to change it to pull model as used in iOS, we can change JSON key to "message" with any payload, as the current clients would interpret it as "checkMessages".
  -- In this case an additional encryption layer would need to be added here, in the same way as with APNS notifications.
  PNMessage _ -> J.object ["checkMessages" .= True]
  PNCheckMessages -> J.object ["checkMessages" .= True]

toPPWPError :: SomeException -> PushProviderError
toPPWPError e = case fromException e of
    Just (InvalidUrlException _ _) -> PPWPInvalidUrl
    Just (HttpExceptionRequest _ (StatusCodeException resp _)) -> fromStatusCode (responseStatus resp) ("" :: String)
    _ -> PPWPOtherError $ tshow e
  where
    fromStatusCode status reason
      | status == N.status200 = PPWPRemovedEndpoint
      | status == N.status410 = PPWPRemovedEndpoint
      | status == N.status413 = PPWPRequestTooLong
      | status == N.status429 = PPRetryLater
      | status >= N.status500 = PPRetryLater
      | otherwise = PPResponseError (Just status) (tshow reason)
