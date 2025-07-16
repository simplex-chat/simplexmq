{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}
{-# OPTIONS_GHC -Wno-unrecognised-pragmas #-}

{-# HLINT ignore "Use newtype instead of data" #-}

module Simplex.Messaging.Notifications.Server.Push where

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
import Simplex.Messaging.Notifications.Protocol
import Simplex.Messaging.Parsers (defaultJSON)
import Simplex.Messaging.Transport.HTTP2.Client (HTTP2ClientError)
import qualified Simplex.Messaging.Crypto as C
import Network.HTTP.Types (Status)
import Control.Exception (Exception)
import Simplex.Messaging.Notifications.Server.Store.Types (NtfTknRec)
import Control.Monad.Except (ExceptT)
import GHC.Exception (SomeException)

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
