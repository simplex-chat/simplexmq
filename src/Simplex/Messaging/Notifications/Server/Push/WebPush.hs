{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# OPTIONS_GHC -Wno-unrecognised-pragmas #-}
{-# HLINT ignore "Use newtype instead of data" #-}

module Simplex.Messaging.Notifications.Server.Push.WebPush where

import Network.HTTP.Client
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Notifications.Protocol (DeviceToken (..), WPAuth (..), WPKey (..), WPTokenParams (..), WPP256dh (..), uncompressEncodePoint, wpRequest)
import Simplex.Messaging.Notifications.Server.Store.Types
import Simplex.Messaging.Notifications.Server.Push
import Control.Monad.Except
import Control.Logger.Simple (logDebug)
import Simplex.Messaging.Util (tshow)
import qualified Data.ByteString.Char8 as B
import Control.Monad.IO.Class (liftIO)
import Control.Exception ( fromException, SomeException, try )
import qualified Network.HTTP.Types as N
import qualified Data.Aeson as J
import Data.Aeson ((.=))
import qualified Data.Binary as Bin
import qualified Data.ByteArray as BA
import qualified Data.ByteString.Lazy as BL
import Control.Monad.Trans.Except (throwE)
import Crypto.Hash.Algorithms (SHA256)
import Crypto.Random (MonadRandom(getRandomBytes))
import qualified Crypto.Cipher.Types as CT
import qualified Crypto.MAC.HMAC as HMAC
import qualified Crypto.PubKey.ECC.DH as ECDH
import qualified Crypto.PubKey.ECC.Types as ECC

wpPushProviderClient :: Manager -> PushProviderClient
wpPushProviderClient _ NtfTknRec {token = APNSDeviceToken _ _} _ = throwE PPInvalidPusher
wpPushProviderClient mg NtfTknRec {token = token@(WPDeviceToken _ param)} pn = do
  -- TODO [webpush] this function should accept type that is restricted to WP token (so, possibly WPProvider and WPTokenParams)
  -- parsing will happen in DeviceToken parser, so it won't fail here
  r <- wpRequest token
  logDebug $ "Request to " <> tshow (host r)
  encBody <- body
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
  _ <- liftPPWPError $ httpNoBody req mg
  pure ()
  where
    body :: ExceptT PushProviderError IO B.ByteString
    body = withExceptT PPCryptoError $ wpEncrypt (wpKey param) (BL.toStrict $ encodeWPN pn)

-- | encrypt :: UA key -> clear -> cipher
-- | https://www.rfc-editor.org/rfc/rfc8291#section-3.4
wpEncrypt :: WPKey -> B.ByteString -> ExceptT C.CryptoError IO B.ByteString
wpEncrypt wpKey clearT = do
  salt :: B.ByteString <- liftIO $ getRandomBytes 16
  asPrivK <- liftIO $ ECDH.generatePrivate $ ECC.getCurveByName ECC.SEC_p256r1
  wpEncrypt' wpKey asPrivK salt clearT

-- | encrypt :: UA key -> AS key -> salt -> clear -> cipher
-- | https://www.rfc-editor.org/rfc/rfc8291#section-3.4
wpEncrypt' :: WPKey -> ECC.PrivateNumber -> B.ByteString -> B.ByteString -> ExceptT C.CryptoError IO B.ByteString
wpEncrypt' WPKey {wpAuth, wpP256dh = WPP256dh uaPubK} asPrivK salt clearT = do
  let uaPubKS = BL.toStrict . uncompressEncodePoint $ uaPubK
  let asPubKS = BL.toStrict . uncompressEncodePoint . ECDH.calculatePublic (ECC.getCurveByName ECC.SEC_p256r1) $ asPrivK
      ecdhSecret = ECDH.getShared (ECC.getCurveByName ECC.SEC_p256r1) asPrivK uaPubK
      prkKey = hmac (unWPAuth wpAuth) ecdhSecret
      keyInfo = "WebPush: info\0" <> uaPubKS <> asPubKS
      ikm = hmac prkKey (keyInfo <> "\x01")
      prk = hmac salt ikm
      cekInfo = "Content-Encoding: aes128gcm\0" :: B.ByteString
      cek = takeHM 16 $ hmac prk (cekInfo <> "\x01")
      nonceInfo = "Content-Encoding: nonce\0" :: B.ByteString
      nonce = takeHM 12 $ hmac prk (nonceInfo <> "\x01")
      rs = BL.toStrict $ Bin.encode (4096 :: Bin.Word32) -- with RFC8291, it's ok to always use 4096 because there is only one single record and the final record can be smaller than rs (RFC8188)
      idlen = BL.toStrict $ Bin.encode (65 :: Bin.Word8) -- with RFC8291, keyid is the pubkey, so always 65 bytes
      header = salt <> rs <> idlen <> asPubKS
  iv <- ivFrom nonce
  -- The last record uses a padding delimiter octet set to the value 0x02
  (C.AuthTag (CT.AuthTag tag), cipherT) <- C.encryptAES128NoPad (C.Key cek) iv $ clearT <> "\x02"
  -- Uncomment to see intermediate values, to compare with RFC8291 example
  -- liftIO . print $ strEncode (BA.convert ecdhSecret :: B.ByteString)
  -- liftIO . print . strEncode $ takeHM 32 prkKey
  -- liftIO . print $ strEncode cek
  -- liftIO . print $ strEncode cipherT
  pure $ header <> cipherT <> BA.convert tag
  where
    hmac k v = HMAC.hmac k v :: HMAC.HMAC SHA256
    takeHM :: Int -> HMAC.HMAC SHA256 -> B.ByteString
    takeHM n v = BL.toStrict $ BL.pack $ take n $ BA.unpack v
    ivFrom :: B.ByteString -> ExceptT C.CryptoError IO C.GCMIV
    ivFrom s = case C.gcmIV s of
      Left e -> throwE e
      Right iv -> pure iv

encodeWPN :: PushNotification -> BL.ByteString
encodeWPN pn = J.encode $ case pn of
  PNVerification code -> J.object ["verification" .= code]
  -- This hack prevents sending unencrypted message metadata in notifications, as we do not use it in the client - it simply receives all messages on each notification.
  -- If we decide to change it to pull model as used in iOS, we can change JSON key to "message" with any payload, as the current clients would interpret it as "checkMessages".
  -- In this case an additional encryption layer would need to be added here, in the same way as with APNS notifications.
  PNMessage _ -> J.object ["checkMessages" .= True]
  PNCheckMessages -> J.object ["checkMessages" .= True]

liftPPWPError :: IO a -> ExceptT PushProviderError IO a
liftPPWPError = liftPPWPError' toPPWPError

liftPPWPError' :: (SomeException -> PushProviderError) -> IO a -> ExceptT PushProviderError IO a
liftPPWPError' err a = liftIO (try @SomeException a) >>= either (throwError . err) return

toPPWPError :: SomeException -> PushProviderError
toPPWPError e = case fromException e of
    Just (InvalidUrlException _ _) -> PPWPInvalidUrl
    Just (HttpExceptionRequest _ (StatusCodeException resp _)) -> fromStatusCode (responseStatus resp) ("" :: String)
    _ -> PPWPOtherError e
  where
    fromStatusCode status reason
      | status == N.status200 = PPWPRemovedEndpoint
      | status == N.status410 = PPWPRemovedEndpoint
      | status == N.status413 = PPWPRequestTooLong
      | status == N.status429 = PPRetryLater
      | status >= N.status500 = PPRetryLater
      | otherwise = PPResponseError (Just status) (tshow reason)
