{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# OPTIONS_GHC -Wno-unrecognised-pragmas #-}

{-# HLINT ignore "Use newtype instead of data" #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE ScopedTypeVariables #-}

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
import qualified Data.ByteArray as BA
import qualified Data.ByteString.Lazy as BL
import Data.List.NonEmpty (NonEmpty)
import qualified Data.Text.Encoding as T
import qualified Data.Text as T
import Control.Monad.Trans.Except (throwE)
import Crypto.Hash.Algorithms (SHA256)
import Crypto.Random (MonadRandom(getRandomBytes))
import qualified Crypto.Cipher.Types as CT
import qualified Crypto.MAC.HMAC as HMAC
import qualified Crypto.PubKey.ECC.DH as ECDH
import qualified Crypto.PubKey.ECC.Types as ECC
import qualified Crypto.PubKey.ECC.ECDSA as ECDSA
import qualified Data.ByteString.Base64.URL as B64
import Simplex.Messaging.TMap (TMap)
import qualified Simplex.Messaging.TMap as TM
import UnliftIO.STM (atomically)
import Data.Time.Clock.System (getSystemTime, systemSeconds)
import Data.Int (Int64)
import Network.URI (URI (..), uriAuthToString)

-- | Vapid
-- | fp: fingerprint, base64url encoded without padding
-- | key: privkey
data VapidKey = VapidKey
  { key::ECDSA.PrivateKey,
    fp::B.ByteString
  }
  deriving (Eq, Show)

mkVapid :: ECDSA.PrivateKey -> VapidKey
mkVapid key = VapidKey { key, fp }
  where
    fp = B64.encodeUnpadded . B.toStrict . C.uncompressEncode . ECDH.calculatePublic (ECC.getCurveByName ECC.SEC_p256r1) . ECDSA.private_d $ key

data WebPushConfig = WebPushConfig
  { vapidKey :: VapidKey
  }

data WPCacheEntry = WPCacheEntry
  { vapidHeader :: B.ByteString,
    expire :: Int64
  }

type WPCache = TMap WPEndpoint WPCacheEntry

getVapidHeader :: VapidKey -> WPEndpoint -> WPCache -> IO B.ByteString
getVapidHeader vapidK e cache = do
  h <- TM.lookupIO e cache
  now <- systemSeconds <$> getSystemTime
  case h of
    Nothing -> newCacheEntry now
    Just entry -> if expire entry > now then pure $ vapidHeader entry
      else newCacheEntry now
  where
    newCacheEntry :: Int64 -> IO B.ByteString
    newCacheEntry now = do
      -- The new entry expires in one hour
      let expire = now + 3600
      vapidHeader <- mkVapidHeader vapidK (endpoint e) expire
      let entry = WPCacheEntry{ vapidHeader, expire }
      atomically $ TM.insert e entry cache
      pure vapidHeader

-- | mkVapidHeader -> vapid -> endpoint -> expire -> vapid header
mkVapidHeader :: VapidKey -> B.ByteString -> Int64 -> IO B.ByteString
mkVapidHeader VapidKey {key, fp} endpoint expire = do
  aud <- Just <$> audience
  let jwtHeader = mkJWTHeader "ES256" Nothing
      jwtClaims = JWTClaims
        { iss = Nothing,
          iat = Nothing,
          exp = Just expire,
          aud,
          sub = Just "https://github.com/simplex-chat/simplexmq/"
        }
      jwt = JWTToken jwtHeader jwtClaims
  signedToken <- signedJWTToken key jwt
  pure $ "vapid t=" <> signedToken <> ",k=" <> fp
  where
    audience :: IO T.Text
    audience = do
      r <- parseUrlThrow . T.unpack . T.decodeUtf8 $ endpoint
      let uri = getUri r
      pure . T.pack $ uri.uriScheme <> uriAuthToString id uri.uriAuthority ""

wpPushProviderClient :: WebPushConfig -> WPCache -> Manager -> PushProviderClient
wpPushProviderClient conf cache mg tkn pn = do
      e <- endpoint tkn
      vapidH <- liftPPWPError $ getVapidHeader (vapidKey conf) e cache
      r <- liftPPWPError $ parseUrlThrow $ B.unpack e.endpoint
      logDebug $ "Request to " <> tshow r.host
      encBody <- body e
      let requestHeaders = [
            ("TTL", "2592000") -- 30 days
            , ("Urgency", "High")
            , ("Content-Encoding", "aes128gcm")
            , ("Authorization", vapidH)
        -- TODO: topic for pings and interval
            ]
          req = r {
        method = "POST"
        , requestHeaders
        , requestBody = RequestBodyBS encBody
        , redirectCount = 0
      }
      _ <- liftPPWPError $ httpNoBody req mg
      pure ()
  where
    endpoint :: NtfTknRec -> ExceptT PushProviderError IO WPEndpoint
    endpoint NtfTknRec {token} = do
      case token of
        WPDeviceToken e -> pure e
        _ -> fail "Wrong device token"
    -- TODO: move to PPIndalidPusher ? WPEndpoint should be invalidated and removed if the key is invalid, but the validation key is never sent
    body :: WPEndpoint -> ExceptT PushProviderError IO B.ByteString
    body e = withExceptT PPCryptoError $ wpEncrypt e.auth e.p256dh (BL.toStrict $ encodePN pn)

-- | encrypt :: auth -> key -> clear -> cipher
-- | https://www.rfc-editor.org/rfc/rfc8291#section-3.4
wpEncrypt :: B.ByteString -> B.ByteString -> B.ByteString -> ExceptT C.CryptoError IO B.ByteString
wpEncrypt auth uaPubKS clearT = do
  salt :: B.ByteString <- liftIO $ getRandomBytes 16
  asPrivK <- liftIO $ ECDH.generatePrivate $ ECC.getCurveByName ECC.SEC_p256r1
  uaPubK <- point uaPubKS
  let asPubK = BL.toStrict . C.uncompressEncode . ECDH.calculatePublic (ECC.getCurveByName ECC.SEC_p256r1) $ asPrivK
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
    point s = withExceptT C.CryptoInvalidECCKey $ C.uncompressDecode $ BL.fromStrict s
    hmac k v = HMAC.hmac k v :: HMAC.HMAC SHA256
    takeHM :: Int -> HMAC.HMAC SHA256 -> B.ByteString
    takeHM n v = BL.toStrict $ BL.pack $ take n $ BA.unpack v
    ivFrom :: B.ByteString -> ExceptT C.CryptoError IO C.GCMIV
    ivFrom s = case C.gcmIV s of
      Left e -> throwE e
      Right iv -> pure iv

encodePN :: PushNotification -> BL.ByteString
encodePN pn = J.encode $ case pn of
    PNVerification code -> J.object [ "verification" .= code ]
    PNMessage d -> J.object [ "message" .= encodeData d ]
    PNCheckMessages -> J.object [ "checkMessages" .= True ]
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
