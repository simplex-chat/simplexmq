{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}
{-# OPTIONS_GHC -Wno-unrecognised-pragmas #-}

{-# HLINT ignore "Use newtype instead of data" #-}

module Simplex.Messaging.Notifications.Server.Push where

import Control.Exception (Exception)
import Control.Monad.Except (ExceptT)
import Crypto.Hash.Algorithms (SHA256 (..))
import qualified Crypto.PubKey.ECC.ECDSA as EC
import qualified Crypto.PubKey.ECC.Types as ECT
import qualified Crypto.Store.PKCS8 as PK
import Data.ASN1.BinaryEncoding (DER (..))
import Data.ASN1.Encoding
import Data.ASN1.Types
import Data.Aeson (ToJSON)
import qualified Data.Aeson as J
import qualified Data.Aeson.TH as JQ
import qualified Data.ByteString.Base64.URL as U
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Lazy.Char8 as LB
import Data.Int (Int64)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Time.Clock.System
import qualified Data.X509 as X
import GHC.Exception (SomeException)
import Network.HTTP.Types (Status)
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Notifications.Protocol
import Simplex.Messaging.Notifications.Server.Store.Types (NtfTknRec)
import Simplex.Messaging.Parsers (defaultJSON)
import Simplex.Messaging.Transport.HTTP2.Client (HTTP2ClientError)

data JWTHeader = JWTHeader
  { typ :: Text, -- "JWT"
    alg :: Text, -- key algorithm, ES256 for APNS
    kid :: Maybe Text -- key ID
  }
  deriving (Show)

mkJWTHeader :: Text -> Maybe Text -> JWTHeader
mkJWTHeader alg kid = JWTHeader {typ = "JWT", alg, kid}

data JWTClaims = JWTClaims
  { iss :: Maybe Text, -- issuer, team ID for APNS
    iat :: Maybe Int64, -- issue time, seconds from epoch for APNS
    exp :: Maybe Int64, -- expired time, seconds from epoch for web push
    aud :: Maybe Text, -- audience, for web push
    sub :: Maybe Text -- subject, to be inform if there is an issue, for web push
  }
  deriving (Show)

data JWTToken = JWTToken JWTHeader JWTClaims
  deriving (Show)

mkJWTToken :: JWTHeader -> Text -> IO JWTToken
mkJWTToken hdr iss = do
  iat <- systemSeconds <$> getSystemTime
  pure $ JWTToken hdr $ jwtClaims iat
  where
    jwtClaims iat =
      JWTClaims
        { iss = Just iss,
          iat = Just iat,
          exp = Nothing,
          aud = Nothing,
          sub = Nothing
        }

type SignedJWTToken = ByteString

$(JQ.deriveToJSON defaultJSON ''JWTHeader)

$(JQ.deriveToJSON defaultJSON ''JWTClaims)

signedJWTToken_ :: (EC.Signature -> ByteString) -> EC.PrivateKey -> JWTToken -> IO SignedJWTToken
signedJWTToken_ serialize pk (JWTToken hdr claims) = do
  let hc = jwtEncode hdr <> "." <> jwtEncode claims
  sig <- EC.sign pk SHA256 hc
  pure $ hc <> "." <> U.encodeUnpadded (serialize sig)
  where
    jwtEncode :: ToJSON a => a -> ByteString
    jwtEncode = U.encodeUnpadded . LB.toStrict . J.encode

signedJWTToken :: EC.PrivateKey -> JWTToken -> IO SignedJWTToken
signedJWTToken = signedJWTToken_ $ \sig ->
  encodeASN1' DER [Start Sequence, IntVal (EC.sign_r sig), IntVal (EC.sign_s sig), End Sequence]

-- | Does it work with APNS ?
signedJWTTokenRaw :: EC.PrivateKey -> JWTToken -> IO SignedJWTToken
signedJWTTokenRaw = signedJWTToken_ $ \sig ->
  C.encodeBigInt (EC.sign_r sig) <> C.encodeBigInt (EC.sign_s sig)

readECPrivateKey :: FilePath -> IO EC.PrivateKey
readECPrivateKey f = do
  -- this pattern match is specific to APNS key type, it may need to be extended for other push providers
  [PK.Unprotected (X.PrivKeyEC X.PrivKeyEC_Named {privkeyEC_name, privkeyEC_priv})] <- PK.readKeyFile f
  pure EC.PrivateKey {private_curve = ECT.getCurveByName privkeyEC_name, private_d = privkeyEC_priv}

data PushNotification
  = PNVerification NtfRegCode
  | PNMessage (NonEmpty PNMessageData)
  | -- | PNAlert Text
    PNCheckMessages
  deriving (Show)

data PushProviderError
  = PPConnection HTTP2ClientError
  | PPCryptoError C.CryptoError
  | PPResponseError (Maybe Status) Text
  | PPTokenInvalid NTInvalidReason
  | PPRetryLater
  | PPPermanentError
  | PPInvalidPusher
  | PPWPInvalidUrl
  | PPWPRemovedEndpoint
  | PPWPRequestTooLong
  | PPWPOtherError SomeException
  deriving (Show, Exception)

type PushProviderClient = NtfTknRec -> PushNotification -> ExceptT PushProviderError IO ()
