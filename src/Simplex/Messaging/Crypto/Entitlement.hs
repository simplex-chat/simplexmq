{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingVia #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}

-- | A generic entitlement, proven with a BBS proof over the SHA-256 suite.
-- The holder secret (the master key) is the undisclosed message; the name, the
-- expiration, and the extra string are disclosed. The protocol and the server
-- reference the entitlement, never a badge; chat maps its own badge to an
-- entitlement.
module Simplex.Messaging.Crypto.Entitlement
  ( Entitlement (..),
    EntitlementCredential (..),
    EntitlementProof (..),
    MasterKey (..),
    entitlementIssuerKeys,
    signEntitlement,
    verifyCredential,
    generateEntitlementProof,
    verifyEntitlement,
  )
where

import Control.Monad (forM)
import Data.Aeson (FromJSON (..), ToJSON (..))
import qualified Data.Aeson.TH as JQ
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.Either (fromRight)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import Data.Text (Text)
import Data.Text.Encoding (encodeUtf8)
import Data.Time.Clock (UTCTime)
import Data.Word (Word16)
import Simplex.Messaging.Crypto.BBS
import Simplex.Messaging.Encoding
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Parsers (defaultJSON)

newtype MasterKey = MasterKey ByteString
  deriving newtype (Eq, Show, StrEncoding)
  deriving (ToJSON, FromJSON) via (StrJSON "MasterKey" MasterKey)

-- | The disclosed content of an entitlement proof.
data Entitlement = Entitlement
  { entitlementName :: Text,
    expiresAt :: UTCTime,
    extraInfo :: Text
  }
  deriving (Eq, Show)

-- | The signing form, held by the entitlement holder; never transmitted.
data EntitlementCredential = EntitlementCredential
  { issuerKeyIdx :: Int,
    masterKey :: MasterKey,
    issuerSignature :: BBSSignature,
    entitlement :: Entitlement
  }
  deriving (Eq, Show)

-- | The proof form. The presentation header is not part of the proof: the
-- verifier supplies it, so a proof cannot claim its own binding.
data EntitlementProof = EntitlementProof
  { issuerKeyIdx :: Int,
    proof :: BBSProof,
    entitlement :: Entitlement
  }
  deriving (Eq, Show)

instance Encoding Entitlement where
  smpEncode Entitlement {entitlementName, expiresAt, extraInfo} =
    smpEncode (entitlementName, strEncode expiresAt, extraInfo)
  smpP = do
    (name, expBs, extra) <- smpP
    expiresAt <- either fail pure $ strDecode (expBs :: ByteString)
    pure Entitlement {entitlementName = name, expiresAt, extraInfo = extra}

instance Encoding EntitlementProof where
  smpEncode EntitlementProof {issuerKeyIdx, proof, entitlement} =
    smpEncode (fromIntegral issuerKeyIdx :: Word16, proof, entitlement)
  smpP = do
    (idx, proof, entitlement) <- smpP
    pure EntitlementProof {issuerKeyIdx = fromIntegral (idx :: Word16), proof, entitlement}

entitlementBBSHeader :: BBSHeader
entitlementBBSHeader = BBSHeader "SimpleX entitlement v1"

entitlementMessageCount :: Int
entitlementMessageCount = 4

entitlementDisclosedIndexes :: [Int]
entitlementDisclosedIndexes = [1, 2, 3]

entitlementMessages :: MasterKey -> Entitlement -> [ByteString]
entitlementMessages (MasterKey mk) ent = mk : disclosedMessages ent

disclosedMessages :: Entitlement -> [ByteString]
disclosedMessages Entitlement {entitlementName, expiresAt, extraInfo} =
  [strEncode expiresAt, encodeUtf8 entitlementName, encodeUtf8 extraInfo]

-- | Issuer side: sign an entitlement for a holder master key.
signEntitlement :: BBSSecretKey -> Int -> MasterKey -> Entitlement -> IO (Either String EntitlementCredential)
signEntitlement sk keyIdx mk ent =
  fmap (\sig -> EntitlementCredential keyIdx mk sig ent) <$> bbsSign sk entitlementBBSHeader (entitlementMessages mk ent)

-- | Holder side: verify the credential received from the issuer.
verifyCredential :: BBSPublicKey -> EntitlementCredential -> IO Bool
verifyCredential pk EntitlementCredential {masterKey, issuerSignature, entitlement} =
  bbsVerify pk issuerSignature entitlementBBSHeader (entitlementMessages masterKey entitlement)

-- | Holder side: generate a proof bound to the presentation header.
generateEntitlementProof :: BBSPublicKey -> EntitlementCredential -> BBSPresHeader -> IO (Either String EntitlementProof)
generateEntitlementProof pk EntitlementCredential {issuerKeyIdx, masterKey, issuerSignature, entitlement} ph =
  fmap (\p -> EntitlementProof issuerKeyIdx p entitlement) <$> bbsProofGen pk issuerSignature entitlementBBSHeader ph entitlementDisclosedIndexes (entitlementMessages masterKey entitlement)

-- | Verifier side: verify the proof with the configured key its index points to,
-- against the supplied presentation header. Nothing means the key index is not
-- among the configured keys.
verifyEntitlement :: Map Int BBSPublicKey -> BBSPresHeader -> EntitlementProof -> IO (Maybe Bool)
verifyEntitlement keys ph EntitlementProof {issuerKeyIdx, proof, entitlement} =
  forM (M.lookup issuerKeyIdx keys) $ \pk ->
    bbsProofVerify pk proof entitlementBBSHeader ph entitlementDisclosedIndexes entitlementMessageCount (disclosedMessages entitlement)

entitlementIssuerKeys :: Map Int BBSPublicKey
entitlementIssuerKeys =
  M.fromList
    [ (1, key "mW_5Zp1wHnXDF56wOZwFcRjGrf0GLLsfyymIQDqYoWfjfvS7oQWSfi7hH65N8JhuE9x8wbKXHidnQLO4GnOSMP_bRKUMH1qIzv5SQKFHNM8G4PaWcTcri8iZLc-3xhSI"),
      (2, key "odGCB7uVDXTURsHgSvSciByV4Q3-3ZvEB8myDsDJqm-PwOYc5-At36uc7n_pyUDxEQEHr9i4RJgFih2FSArPW-EQBXNPNf4wTtA0znn74qLEGc4fh9pVYPEIm_ZGbnsJ"),
      (3, key "txkT2003WMjc43KvYvPKEcR970NLmw5UZY51eUqgk91sgp53idt1HTlKYvnrEttJDFMlctYf1-bpri0e9DhBQ-xk1J4WoLN2uif_1OcA1pGCobpk9lwtsq1Idek4biy0"),
      (4, key "q_YzegihaLYrEm9z3cAghsfDGNZfXuEpQGMJERJQS4M0Szl4gvSC_fV_muKc3NIMA_8iYuBN8qyvb5U55RctCRn3kleFQ4sqf-WBgoydX6UVo7BsYcUbXWWEFZXlOGIH"),
      (5, key "oqymHASH_okefShrnz4HnTooUNlE1WoDRnSrgd0bTCpOacgJWBsMpwZpdmYlX-vQAKAC_zmI4VdKoOznnhW-sdUXZw6bthCi5JYjGxCR1Co27i1tix5UXCTbR5Jp901-"),
      (6, key "kDqaB6zKSRp_97QPFj5JPDlo0vzfSTLSp9goFx1qajv4q4H6dR6BbkmWZ4xx_9Q2AxmcpqcV0ethz1OH-Jk_Sz2J1mIz1PUVM9LkdLhi_PNtqhezzO5dbVs-HJ1fNqe6"),
      (7, key "rl36D5mg2N3NmmEybxE_RBeU9YZ_zeXNPfp7ZMLtUEuf2Mo4OQM_Up1v5rX_IqICD-AIJcuyptEBsELx_PJQzpmiNuG5I4cWO6HkRKtc6fVFvgZMrDJjaascPd1CIyxX"),
      (8, key "joM3Bnt7JPt5JiwQwERHGjro2iVZ0mPD_clUh4hzkhxvbjuFrWuTmfSNA8PWBqGKEGNl13aRi1pMf6yY14E27c5C71JxWm7T-rZaBrGPEUWifhD-qidWuf3PU7KJCCWd")
    ]
  where
    key = fromRight (error "bad base64 in entitlement issuer key") . strDecode . B.pack

$(JQ.deriveJSON defaultJSON ''Entitlement)

$(JQ.deriveJSON defaultJSON ''EntitlementCredential)

$(JQ.deriveJSON defaultJSON ''EntitlementProof)
