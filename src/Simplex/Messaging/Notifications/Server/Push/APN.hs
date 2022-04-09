{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

module Simplex.Messaging.Notifications.Server.Push.APN where

import Crypto.Hash.Algorithms (SHA256 (..))
import qualified Crypto.PubKey.ECC.ECDSA as EC
import qualified Crypto.PubKey.ECC.Types as ECT
import qualified Crypto.Store.PKCS8 as PK
import Data.Aeson (ToJSON)
import qualified Data.Aeson as J
import qualified Data.ByteString.Base64.URL as U
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Lazy.Char8 as LB
import Data.Int (Int64)
import Data.Text (Text)
import Data.Time.Clock.System
import qualified Data.X509 as X
import GHC.Generics

data JWTHeader = JWTHeader
  { alg :: Text, -- key algorithm, ES256 for APN
    kid :: Text -- key ID
  }
  deriving (Generic)

instance ToJSON JWTHeader where toEncoding = J.genericToEncoding J.defaultOptions

data JWTClaims = JWTClaims
  { iss :: Text, -- issuer, team ID for APN
    iat :: Int64 -- issue time, seconds from epoch
  }
  deriving (Generic)

instance ToJSON JWTClaims where toEncoding = J.genericToEncoding J.defaultOptions

jwtEncode :: ToJSON a => a -> ByteString
jwtEncode = U.encodeUnpadded . LB.toStrict . J.encode

data JWTToken = JWTToken JWTHeader JWTClaims

mkJWTToken :: JWTHeader -> Text -> IO JWTToken
mkJWTToken hdr iss = do
  iat <- systemSeconds <$> getSystemTime
  pure $ JWTToken hdr JWTClaims {iss, iat}

-- PrivKeyEC_Named

-- EC.getCurveByName :: CurveName -> Curve

-- EC.sign :: (ByteArrayAccess msg, HashAlgorithm hash, MonadRandom m) => EC.PrivateKey -> hash -> msg -> m Signature

-- PrivateKey
--   private_curve :: Curve
--   private_d :: PrivateNumber

signJWTToken :: EC.PrivateKey -> JWTToken -> IO ByteString
signJWTToken pk (JWTToken hdr claims) = do
  let hc = jwtEncode hdr <> "." <> jwtEncode claims
  sig <- EC.sign pk SHA256 hc
  print sig
  pure $ hc --  <> "." <> sig

readECPrivateKey :: FilePath -> IO EC.PrivateKey
readECPrivateKey f = do
  -- TODO this is very specific to APN key
  [PK.Unprotected (X.PrivKeyEC X.PrivKeyEC_Named {privkeyEC_name, privkeyEC_priv})] <- PK.readKeyFile f
  pure EC.PrivateKey {private_curve = ECT.getCurveByName privkeyEC_name, private_d = privkeyEC_priv}
