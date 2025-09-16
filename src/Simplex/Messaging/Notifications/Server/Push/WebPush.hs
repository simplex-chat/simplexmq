{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeApplications #-}
{-# OPTIONS_GHC -Wno-unrecognised-pragmas #-}
{-# HLINT ignore "Use newtype instead of data" #-}

module Simplex.Messaging.Notifications.Server.Push.WebPush where

import Network.HTTP.Client
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Notifications.Protocol (DeviceToken (WPDeviceToken), WPEndpoint (..), encodePNMessages, PNMessageData)
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
import qualified Data.Bits as Bits
import qualified Data.ByteArray as BA
import qualified Data.ByteString.Lazy as BL
import Data.List.NonEmpty (NonEmpty)
import qualified Data.Text.Encoding as T
import qualified Data.Text as T
import Control.Monad.Trans.Except (throwE)
import Crypto.Hash.Algorithms (SHA256)
import Crypto.Random (MonadRandom(getRandomBytes))
import qualified Crypto.Cipher.Types as CT
import qualified Crypto.Error as CE
import qualified Crypto.MAC.HMAC as HMAC
import qualified Crypto.PubKey.ECC.DH as ECDH
import qualified Crypto.PubKey.ECC.Types as ECC
import GHC.Base (when)

wpPushProviderClient :: Manager -> PushProviderClient
wpPushProviderClient mg tkn pn = do
  -- TODO [webpush] parsing will happen in DeviceToken parser, so it won't fail here
  -- TODO [webpush] this function should accept type that is restricted to WP token (so, possibly WPProvider and WPTokenParams)
  wpe@WPEndpoint {endpoint} <- tokenEndpoint tkn
  r <- liftPPWPError $ parseUrlThrow $ B.unpack endpoint
  logDebug $ "Request to " <> tshow (host r)
  encBody <- body wpe
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
    tokenEndpoint :: NtfTknRec -> ExceptT PushProviderError IO WPEndpoint
    tokenEndpoint NtfTknRec {token} = do
      case token of
        WPDeviceToken _p e -> pure e
        _ -> fail "Wrong device token"
    -- TODO: move to PPIndalidPusher ? WPEndpoint should be invalidated and removed if the key is invalid, but the validation key is never sent
    body :: WPEndpoint -> ExceptT PushProviderError IO B.ByteString
    body WPEndpoint {auth, p256dh} = withExceptT PPCryptoError $ wpEncrypt auth p256dh (BL.toStrict $ encodePN pn)

-- | encrypt :: auth -> key -> clear -> cipher
-- | https://www.rfc-editor.org/rfc/rfc8291#section-3.4
wpEncrypt :: B.ByteString -> B.ByteString -> B.ByteString -> ExceptT C.CryptoError IO B.ByteString
wpEncrypt auth uaPubKS clearT = do
  salt :: B.ByteString <- liftIO $ getRandomBytes 16
  asPrivK <- liftIO $ ECDH.generatePrivate $ ECC.getCurveByName ECC.SEC_p256r1
  -- TODO [webpush] key parsing will happen in DeviceToken parser, so it won't fail here
  uaPubK <- point uaPubKS
  let asPubK = BL.toStrict . uncompressEncode . ECDH.calculatePublic (ECC.getCurveByName ECC.SEC_p256r1) $ asPrivK
      ecdhSecret = ECDH.getShared (ECC.getCurveByName ECC.SEC_p256r1) asPrivK uaPubK
      prkKey = hmac auth ecdhSecret
      keyInfo = "WebPush: info\0" <> uaPubKS <> asPubK
      ikm = hmac prkKey (keyInfo <> "\x01")
      prk = hmac salt ikm
      cekInfo = "Content-Encoding: aes128gcm\0" :: B.ByteString
      cek = takeHM 16 $ hmac prk (cekInfo <> "\x01")
      nonceInfo = "Content-Encoding: nonce\0" :: B.ByteString
      nonce = takeHM 12 $ hmac prk (nonceInfo <> "\x01")
      rs = BL.toStrict $ Bin.encode (4096 :: Bin.Word32) -- with RFC8291, it's ok to always use 4096 because there is only one single record and the final record can be smaller than rs (RFC8188)
      idlen = BL.toStrict $ Bin.encode (65 :: Bin.Word8) -- with RFC8291, keyid is the pubkey, so always 65 bytes
      header = salt <> rs <> idlen <> asPubK
  iv <- ivFrom nonce
  -- The last record uses a padding delimiter octet set to the value 0x02
  (C.AuthTag (CT.AuthTag tag), cipherT) <- C.encryptAES128NoPad (C.Key cek) iv $ clearT <> "\x02"
  pure $ header <> cipherT <> BA.convert tag
  where
    point :: B.ByteString -> ExceptT C.CryptoError IO ECC.Point
    point s = withExceptT C.CryptoInvalidECCKey $ uncompressDecode $ BL.fromStrict s
    hmac k v = HMAC.hmac k v :: HMAC.HMAC SHA256
    takeHM :: Int -> HMAC.HMAC SHA256 -> B.ByteString
    takeHM n v = BL.toStrict $ BL.pack $ take n $ BA.unpack v
    ivFrom :: B.ByteString -> ExceptT C.CryptoError IO C.GCMIV
    ivFrom s = case C.gcmIV s of
      Left e -> throwE e
      Right iv -> pure iv

-- | Elliptic-Curve-Point-to-Octet-String Conversion without compression
-- | as required by RFC8291
-- | https://www.secg.org/sec1-v2.pdf#subsubsection.2.3.3
-- TODO [webpush] add them to the encoding of WPKey
uncompressEncode :: ECC.Point -> BL.ByteString
uncompressEncode (ECC.Point x y) = "\x04" <> encodeBigInt x <> encodeBigInt y
uncompressEncode ECC.PointO = "\0"

-- TODO [webpush] should be -> Either ... (which it would be in StrEncoding)
uncompressDecode :: BL.ByteString -> ExceptT CE.CryptoError IO ECC.Point
uncompressDecode "\0" = pure ECC.PointO
uncompressDecode s = do
  when (BL.take 1 s /= prefix) $ throwError CE.CryptoError_PointFormatUnsupported
  when (BL.length s /= 65) $ throwError CE.CryptoError_KeySizeInvalid
  let s' = BL.drop 1 s
  x <- decodeBigInt $ BL.take 32 s'
  y <- decodeBigInt $ BL.drop 32 s'
  pure $ ECC.Point x y
  where
    prefix = "\x04" :: BL.ByteString

encodeBigInt :: Integer -> BL.ByteString
encodeBigInt i = do
  let s1 = Bits.shiftR i 64
      s2 = Bits.shiftR s1 64
      s3 = Bits.shiftR s2 64
  Bin.encode (w64 s3, w64 s2, w64 s1, w64 i)
  where
    w64 :: Integer -> Bin.Word64
    w64 = fromIntegral

-- TODO [webpush] should be -> Either ... (which it would be in StrEncoding)
decodeBigInt :: BL.ByteString -> ExceptT CE.CryptoError IO Integer
decodeBigInt s = do
  when (BL.length s /= 32) $ throwError CE.CryptoError_PointSizeInvalid
  let (w3, w2, w1, w0) = Bin.decode s :: (Bin.Word64, Bin.Word64, Bin.Word64, Bin.Word64 )
  pure $ shift 3 w3 + shift 2 w2 + shift 1 w1 + shift 0 w0
  where
    shift i w = Bits.shiftL (fromIntegral w) (64 * i)

-- TODO [webpush] use ToJSON
encodePN :: PushNotification -> BL.ByteString
encodePN pn = J.encode $ case pn of
  PNVerification code -> J.object ["verification" .= code]
  PNMessage d -> J.object ["message" .= encodeData d]
  PNCheckMessages -> J.object ["checkMessages" .= True]
  where
    encodeData :: NonEmpty PNMessageData -> String
    encodeData a = T.unpack . T.decodeUtf8 $ encodePNMessages a

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
