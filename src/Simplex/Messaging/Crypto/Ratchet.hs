{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE StrictData #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
-- {-# LANGUAGE TypeOperators #-}
{-# OPTIONS_GHC -fno-warn-redundant-constraints #-}

module Simplex.Messaging.Crypto.Ratchet where

import Control.Monad.Except
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Trans.Except
import Crypto.Cipher.AES (AES256)
import Crypto.Hash (SHA512)
import qualified Crypto.KDF.HKDF as H
import Crypto.Random (ChaChaDRG)
import Data.Aeson (FromJSON (..), ToJSON (..))
import qualified Data.Aeson as J
import qualified Data.Aeson.TH as JQ
import Data.Attoparsec.ByteString (Parser)
import qualified Data.Attoparsec.ByteString.Char8 as A
import qualified Data.ByteArray as BA
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import qualified Data.ByteString.Lazy as LB
import Data.Composition ((.:), (.:.))
import qualified Data.List.NonEmpty as L
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import Data.Maybe (fromMaybe, isJust)
import Data.Type.Equality
import Data.Typeable (Typeable)
import Data.Word (Word32)
import Database.SQLite.Simple.FromField (FromField (..))
import Database.SQLite.Simple.ToField (ToField (..))
import Simplex.Messaging.Agent.QueryString
import Simplex.Messaging.Crypto
import Simplex.Messaging.Crypto.SNTRUP761.Bindings
import Simplex.Messaging.Encoding
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Parsers (blobFieldDecoder, defaultJSON, parseE, parseE')
import Simplex.Messaging.Util ((<$?>), ($>>=))
import Simplex.Messaging.Version
import UnliftIO.STM

-- e2e encryption headers version history:
-- 1 - binary protocol encoding (1/1/2022)
-- 2 - use KDF in x3dh (10/20/2022)

kdfX3DHE2EEncryptVersion :: Version
kdfX3DHE2EEncryptVersion = 2

pqRatchetVersion :: Version
pqRatchetVersion = 3

currentE2EEncryptVersion :: Version
currentE2EEncryptVersion = 3

supportedE2EEncryptVRange :: VersionRange
supportedE2EEncryptVRange = mkVersionRange kdfX3DHE2EEncryptVersion currentE2EEncryptVersion

data RatchetKEMState
  = RKSProposed -- only KEM encapsulation key
  | RKSAccepted -- KEM ciphertext and the next encapsulation key

data SRatchetKEMState (s :: RatchetKEMState) where
  SRKSProposed :: SRatchetKEMState 'RKSProposed
  SRKSAccepted :: SRatchetKEMState 'RKSAccepted

deriving instance Show (SRatchetKEMState s)

instance TestEquality SRatchetKEMState where
  testEquality SRKSProposed SRKSProposed = Just Refl
  testEquality SRKSAccepted SRKSAccepted = Just Refl
  testEquality _ _ = Nothing

class RatchetKEMStateI (s :: RatchetKEMState) where sRatchetKEMState :: SRatchetKEMState s

instance RatchetKEMStateI RKSProposed where sRatchetKEMState = SRKSProposed

instance RatchetKEMStateI RKSAccepted where sRatchetKEMState = SRKSAccepted

checkRatchetKEMState :: forall t s s' a. (RatchetKEMStateI s, RatchetKEMStateI s') => t s' a -> Either String (t s a)
checkRatchetKEMState x = case testEquality (sRatchetKEMState @s) (sRatchetKEMState @s') of
  Just Refl -> Right x
  Nothing -> Left "bad ratchet KEM state"

checkRatchetKEMState' :: forall t s s'. (RatchetKEMStateI s, RatchetKEMStateI s') => t s' -> Either String (t s)
checkRatchetKEMState' x = case testEquality (sRatchetKEMState @s) (sRatchetKEMState @s') of
  Just Refl -> Right x
  Nothing -> Left "bad ratchet KEM state"

data RKEMParams (s :: RatchetKEMState) where
  RKParamsProposed :: KEMPublicKey -> RKEMParams 'RKSProposed
  RKParamsAccepted :: KEMCiphertext -> KEMPublicKey -> RKEMParams 'RKSAccepted

deriving instance Show (RKEMParams s)

data ARKEMParams = forall s. RatchetKEMStateI s => ARKP (SRatchetKEMState s) (RKEMParams s)

deriving instance Show ARKEMParams

instance RatchetKEMStateI s => Encoding (RKEMParams s) where
  smpEncode = \case
    RKParamsProposed k -> smpEncode ('P', k)
    RKParamsAccepted ct k -> smpEncode ('A', ct, k)
  smpP = (\(ARKP _ ps) -> checkRatchetKEMState' ps) <$?> smpP

instance Encoding (ARKEMParams) where
  smpEncode (ARKP _ ps) = smpEncode ps
  smpP =
    smpP >>= \case
      'P' -> ARKP SRKSProposed . RKParamsProposed <$> smpP
      'A' -> ARKP SRKSAccepted .: RKParamsAccepted <$> smpP <*> smpP
      _ -> fail "bad ratchet KEM params"

data E2ERatchetParams (s :: RatchetKEMState) (a :: Algorithm)
  = E2ERatchetParams Version (PublicKey a) (PublicKey a) (Maybe (RKEMParams s))
  deriving (Show)

data AE2ERatchetParams (a :: Algorithm)
  = forall s.
    RatchetKEMStateI s =>
    AE2ERatchetParams (SRatchetKEMState s) (E2ERatchetParams s a)

deriving instance Show (AE2ERatchetParams a)

data AnyE2ERatchetParams
  = forall s a.
    (RatchetKEMStateI s, DhAlgorithm a, AlgorithmI a) =>
    AnyE2ERatchetParams (SRatchetKEMState s) (SAlgorithm a) (E2ERatchetParams s a)

deriving instance Show AnyE2ERatchetParams

instance (RatchetKEMStateI s, AlgorithmI a) => Encoding (E2ERatchetParams s a) where
  smpEncode (E2ERatchetParams v k1 k2 kem_)
    | v >= pqRatchetVersion = smpEncode (v, k1, k2, kem_)
    | otherwise = smpEncode (v, k1, k2)
  smpP = toParams <$?> smpP
    where
      toParams :: AE2ERatchetParams a -> Either String (E2ERatchetParams s a)
      toParams = \case
        AE2ERatchetParams _ (E2ERatchetParams v k1 k2 Nothing) -> Right $ E2ERatchetParams v k1 k2 Nothing
        AE2ERatchetParams _ ps -> checkRatchetKEMState ps

instance AlgorithmI a => Encoding (AE2ERatchetParams a) where
  smpEncode (AE2ERatchetParams _ ps) = smpEncode ps
  smpP = (\(AnyE2ERatchetParams s _ ps) -> (AE2ERatchetParams s) <$> checkAlgorithm ps) <$?> smpP

instance Encoding AnyE2ERatchetParams where
  smpEncode (AnyE2ERatchetParams _ _ ps) = smpEncode ps
  smpP = do
    (v :: Version, APublicDhKey a k1, APublicDhKey a' k2) <- smpP
    case testEquality a a' of
      Nothing -> fail "bad e2e params: different key algorithms"
      Just Refl ->
        kemP v >>= \case
          Just (ARKP s kem) -> pure $ AnyE2ERatchetParams s a $ E2ERatchetParams v k1 k2 (Just kem)
          Nothing -> pure $ AnyE2ERatchetParams SRKSProposed a $ E2ERatchetParams v k1 k2 Nothing
    where
      kemP :: Version -> Parser (Maybe (ARKEMParams))
      kemP v
        | v >= pqRatchetVersion = smpP
        | otherwise = pure Nothing

instance VersionI (E2ERatchetParams s a) where
  type VersionRangeT (E2ERatchetParams s a) = E2ERatchetParamsUri s a
  version (E2ERatchetParams v _ _ _) = v
  toVersionRangeT (E2ERatchetParams _ k1 k2 kem_) vr = E2ERatchetParamsUri vr k1 k2 kem_

instance VersionRangeI (E2ERatchetParamsUri s a) where
  type VersionT (E2ERatchetParamsUri s a) = (E2ERatchetParams s a)
  versionRange (E2ERatchetParamsUri vr _ _ _) = vr
  toVersionT (E2ERatchetParamsUri _ k1 k2 kem_) v = E2ERatchetParams v k1 k2 kem_

type RcvE2ERatchetParamsUri a = E2ERatchetParamsUri 'RKSProposed a

data E2ERatchetParamsUri (s :: RatchetKEMState) (a :: Algorithm)
  = E2ERatchetParamsUri VersionRange (PublicKey a) (PublicKey a) (Maybe (RKEMParams s))
  deriving (Show)

data AE2ERatchetParamsUri (a :: Algorithm)
  = forall s.
    RatchetKEMStateI s =>
    AE2ERatchetParamsUri (SRatchetKEMState s) (E2ERatchetParamsUri s a)

deriving instance Show (AE2ERatchetParamsUri a)

data AnyE2ERatchetParamsUri
  = forall s a.
    (RatchetKEMStateI s, DhAlgorithm a, AlgorithmI a) =>
    AnyE2ERatchetParamsUri (SRatchetKEMState s) (SAlgorithm a) (E2ERatchetParamsUri s a)

deriving instance Show AnyE2ERatchetParamsUri

instance (RatchetKEMStateI s, AlgorithmI a) => StrEncoding (E2ERatchetParamsUri s a) where
  strEncode (E2ERatchetParamsUri vs key1 key2 kem_) =
    strEncode . QSP QNoEscaping $
      [("v", strEncode vs), ("x3dh", strEncodeList [key1, key2])]
        <> maybe [] encodeKem kem_
    where
      encodeKem kem
        | maxVersion vs < pqRatchetVersion = []
        | otherwise = case kem of
            RKParamsProposed k -> [("kem_key", strEncode k)]
            RKParamsAccepted ct k -> [("kem_ct", strEncode ct), ("kem_key", strEncode k)]
  strP = toParamsURI <$?> strP
    where
      toParamsURI = \case
        AE2ERatchetParamsUri _ (E2ERatchetParamsUri vr k1 k2 Nothing) -> Right $ E2ERatchetParamsUri vr k1 k2 Nothing
        AE2ERatchetParamsUri _ ps -> checkRatchetKEMState ps

instance AlgorithmI a => StrEncoding (AE2ERatchetParamsUri a) where
  strEncode (AE2ERatchetParamsUri _ ps) = strEncode ps
  strP = (\(AnyE2ERatchetParamsUri s _ ps) -> (AE2ERatchetParamsUri s) <$> checkAlgorithm ps) <$?> strP

instance StrEncoding AnyE2ERatchetParamsUri where
  strEncode (AnyE2ERatchetParamsUri _ _ ps) = strEncode ps
  strP = do
    query <- strP
    vr :: VersionRange <- queryParam "v" query
    keys <- L.toList <$> queryParam "x3dh" query
    case keys of
      [APublicDhKey a k1, APublicDhKey a' k2] -> case testEquality a a' of
        Nothing -> fail "bad e2e params: different key algorithms"
        Just Refl ->
          kemP vr query >>= \case
            Just (ARKP s kem) -> pure $ AnyE2ERatchetParamsUri s a $ E2ERatchetParamsUri vr k1 k2 (Just kem)
            Nothing -> pure $ AnyE2ERatchetParamsUri SRKSProposed a $ E2ERatchetParamsUri vr k1 k2 Nothing
      _ -> fail "bad e2e params"
    where
      kemP vr query
        | maxVersion vr >= pqRatchetVersion =
            queryParam_ "kem_key" query
              $>>= \k -> (Just . kemParams k <$> queryParam_ "kem_ct" query)
        | otherwise = pure Nothing
      kemParams k = \case
        Nothing -> ARKP SRKSProposed $ RKParamsProposed k
        Just ct -> ARKP SRKSAccepted $ RKParamsAccepted ct k

type RcvE2ERatchetParams a = E2ERatchetParams 'RKSProposed a

type SndE2ERatchetParams a = AE2ERatchetParams a

data PrivRKEMParams (s :: RatchetKEMState) where
  PrivateRKParamsProposed :: KEMKeyPair -> PrivRKEMParams 'RKSProposed
  PrivateRKParamsAccepted :: KEMCiphertext -> KEMSharedKey -> KEMKeyPair -> PrivRKEMParams 'RKSAccepted

data APrivRKEMParams = forall s. RatchetKEMStateI s => APRKP (SRatchetKEMState s) (PrivRKEMParams s)

type RcvPrivRKEMParams = PrivRKEMParams 'RKSProposed

instance RatchetKEMStateI s => Encoding (PrivRKEMParams s) where
  smpEncode = \case
    PrivateRKParamsProposed k -> smpEncode ('P', k)
    PrivateRKParamsAccepted ct shared k -> smpEncode ('A', ct, shared, k)
  smpP = (\(APRKP _ ps) -> checkRatchetKEMState' ps) <$?> smpP

instance Encoding (APrivRKEMParams) where
  smpEncode (APRKP _ ps) = smpEncode ps
  smpP =
    smpP >>= \case
      'P' -> APRKP SRKSProposed . PrivateRKParamsProposed <$> smpP
      'A' -> APRKP SRKSAccepted .:. PrivateRKParamsAccepted <$> smpP <*> smpP <*> smpP
      _ -> fail "bad APrivRKEMParams"

instance RatchetKEMStateI s => ToField (PrivRKEMParams s) where toField = toField . smpEncode

instance (Typeable s, RatchetKEMStateI s) => FromField (PrivRKEMParams s) where fromField = blobFieldDecoder smpDecode

data UseKEM (s :: RatchetKEMState) where
  ProposeKEM :: UseKEM 'RKSProposed
  AcceptKEM :: KEMPublicKey -> UseKEM 'RKSAccepted

data AUseKEM = forall s. RatchetKEMStateI s => AUseKEM (SRatchetKEMState s) (UseKEM s)

generateE2EParams :: forall s a. (AlgorithmI a, DhAlgorithm a) => TVar ChaChaDRG -> Version -> Maybe (UseKEM s) -> IO (PrivateKey a, PrivateKey a, Maybe (PrivRKEMParams s), E2ERatchetParams s a)
generateE2EParams g v useKEM_ = do
  (k1, pk1) <- atomically $ generateKeyPair g
  (k2, pk2) <- atomically $ generateKeyPair g
  kems <- kemParams
  pure (pk1, pk2, snd <$> kems, E2ERatchetParams v k1 k2 (fst <$> kems))
  where
    kemParams :: IO (Maybe (RKEMParams s, PrivRKEMParams s))
    kemParams = case useKEM_ of
      Just useKem | v >= pqRatchetVersion -> Just <$> do
        ks@(k, _) <- sntrup761Keypair g
        case useKem of
          ProposeKEM -> pure (RKParamsProposed k, PrivateRKParamsProposed ks)
          AcceptKEM k' -> do
            (ct, shared) <- sntrup761Enc g k'
            pure (RKParamsAccepted ct k, PrivateRKParamsAccepted ct shared ks)
      _ -> pure Nothing

-- used by party initiating connection, Bob in double-ratchet spec
generateRcvE2EParams :: (AlgorithmI a, DhAlgorithm a) => TVar ChaChaDRG -> Version -> Maybe (UseKEM 'RKSProposed) -> IO (PrivateKey a, PrivateKey a, Maybe (PrivRKEMParams 'RKSProposed), E2ERatchetParams 'RKSProposed a)
generateRcvE2EParams = generateE2EParams

-- used by party accepting connection, Alice in double-ratchet spec
generateSndE2EParams :: forall a. (AlgorithmI a, DhAlgorithm a) => TVar ChaChaDRG -> Version -> Maybe AUseKEM -> IO (PrivateKey a, PrivateKey a, Maybe APrivRKEMParams, AE2ERatchetParams a)
generateSndE2EParams g v = \case
  Nothing -> do
    (pk1, pk2, _, e2eParams) <- generateE2EParams g v Nothing
    pure (pk1, pk2, Nothing, AE2ERatchetParams SRKSProposed e2eParams)
  Just (AUseKEM s useKEM) -> do
    (pk1, pk2, pKem, e2eParams) <- generateE2EParams g v (Just useKEM)
    pure (pk1, pk2, APRKP s <$> pKem, AE2ERatchetParams s e2eParams)

data RatchetInitParams = RatchetInitParams
  { assocData :: Str,
    ratchetKey :: RatchetKey,
    sndHK :: HeaderKey,
    rcvNextHK :: HeaderKey,
    kemAccepted :: Maybe RatchetKEMAccepted
  }
  deriving (Show)

-- this is used by the peer joining the connection
pqX3dhSnd :: DhAlgorithm a => PrivateKey a -> PrivateKey a -> Maybe APrivRKEMParams -> E2ERatchetParams 'RKSProposed a -> Either CryptoError (RatchetInitParams, Maybe KEMKeyPair)
--        3. replied       2. received
pqX3dhSnd spk1 spk2 spKem_ (E2ERatchetParams v rk1 rk2 rKem_) = do
  (ks_, kem_) <- sndPq
  let initParams = pqX3dh (publicKey spk1, rk1) (dh' rk1 spk2) (dh' rk2 spk1) (dh' rk2 spk2) kem_
  pure (initParams, ks_)
  where
    sndPq :: Either CryptoError (Maybe KEMKeyPair, Maybe RatchetKEMAccepted)
    sndPq = case spKem_ of
      Just (APRKP _ ps) | v >= pqRatchetVersion -> case (ps, rKem_) of
        (PrivateRKParamsAccepted ct shared ks, Just (RKParamsProposed k)) -> Right (Just ks, Just $ RatchetKEMAccepted k shared ct)
        (PrivateRKParamsProposed ks, _) -> Right (Just ks, Nothing) -- both parties can send "proposal" in case of ratchet renegotiation
        _ -> Left CERatchetKEMState
      _ -> Right (Nothing, Nothing)

-- this is used by the peer that created new connection, after receiving the reply
pqX3dhRcv :: forall s a. (RatchetKEMStateI s, DhAlgorithm a) => PrivateKey a -> PrivateKey a -> Maybe (PrivRKEMParams 'RKSProposed) -> E2ERatchetParams s a -> ExceptT CryptoError IO (RatchetInitParams, Maybe KEMKeyPair)
--        1. sent          4. received in reply
pqX3dhRcv rpk1 rpk2 rpKem_ (E2ERatchetParams v sk1 sk2 sKem_) = do
  kem_ <- rcvPq
  let initParams = pqX3dh (sk1, publicKey rpk1) (dh' sk2 rpk1) (dh' sk1 rpk2) (dh' sk2 rpk2) (snd <$> kem_)
  pure (initParams, fst <$> kem_)
  where
    rcvPq :: ExceptT CryptoError IO (Maybe (KEMKeyPair, RatchetKEMAccepted))
    rcvPq = case sKem_ of
      Just (RKParamsAccepted ct k') | v >= pqRatchetVersion -> case rpKem_ of
        Just (PrivateRKParamsProposed ks@(_, pk)) -> do
          shared <- liftIO $ sntrup761Dec ct pk
          pure $ Just (ks, RatchetKEMAccepted k' shared ct)
        Nothing -> throwError CERatchetKEMState
      _ -> pure Nothing -- both parties can send "proposal" in case of ratchet renegotiation

pqX3dh :: DhAlgorithm a => (PublicKey a, PublicKey a) -> DhSecret a -> DhSecret a -> DhSecret a -> Maybe RatchetKEMAccepted -> RatchetInitParams
pqX3dh (sk1, rk1) dh1 dh2 dh3 kemAccepted =
  RatchetInitParams {assocData, ratchetKey = RatchetKey sk, sndHK = Key hk, rcvNextHK = Key nhk, kemAccepted}
  where
    assocData = Str $ pubKeyBytes sk1 <> pubKeyBytes rk1
    dhs = dhBytes' dh1 <> dhBytes' dh2 <> dhBytes' dh3 <> pq
    pq = maybe "" (\RatchetKEMAccepted {rcPQRss = KEMSharedKey ss} -> BA.convert ss) kemAccepted
    (hk, nhk, sk) =
      let salt = B.replicate 64 '\0'
        in hkdf3 salt dhs "SimpleXX3DH"

type RatchetX448 = Ratchet 'X448

data Ratchet a = Ratchet
  { -- ratchet version range sent in messages (current .. max supported ratchet version)
    rcVersion :: VersionRange,
    -- associated data - must be the same in both parties ratchets
    rcAD :: Str,
    rcDHRs :: PrivateKey a,
    rcKEM :: Maybe RatchetKEM,
    -- TODO make them optional
    rcEnableKEM :: Bool, -- will enable KEM on the next ratchet step
    rcSndKEM :: Bool, -- used KEM hybrid secret for sending ratchet
    rcRcvKEM :: Bool, -- used KEM hybrid secret for receiving ratchet
    rcRK :: RatchetKey,
    rcSnd :: Maybe (SndRatchet a),
    rcRcv :: Maybe RcvRatchet,
    rcNs :: Word32,
    rcNr :: Word32,
    rcPN :: Word32,
    rcNHKs :: HeaderKey,
    rcNHKr :: HeaderKey
  }
  deriving (Show)

data SndRatchet a = SndRatchet
  { rcDHRr :: PublicKey a,
    rcCKs :: RatchetKey,
    rcHKs :: HeaderKey
  }
  deriving (Show)

data RcvRatchet = RcvRatchet
  { rcCKr :: RatchetKey,
    rcHKr :: HeaderKey
  }
  deriving (Show)

data RatchetKEM = RatchetKEM
  { rcPQRs :: KEMKeyPair,
    rcKEMs :: Maybe RatchetKEMAccepted
  }
  deriving (Show)

data RatchetKEMAccepted = RatchetKEMAccepted
  { rcPQRr :: KEMPublicKey, -- received key
    rcPQRss :: KEMSharedKey, -- computed shared secret
    rcPQRct :: KEMCiphertext -- sent encaps(rcPQRr, rcPQRss)
  }
  deriving (Show)

type SkippedMsgKeys = Map HeaderKey SkippedHdrMsgKeys

type SkippedHdrMsgKeys = Map Word32 MessageKey

data SkippedMsgDiff
  = SMDNoChange
  | SMDRemove HeaderKey Word32
  | SMDAdd SkippedMsgKeys

-- | this function is only used in tests to apply changes in skipped messages,
-- in the agent the diff is persisted, and the whole state is loaded for the next message.
applySMDiff :: SkippedMsgKeys -> SkippedMsgDiff -> SkippedMsgKeys
applySMDiff smks = \case
  SMDNoChange -> smks
  SMDRemove hk msgN -> fromMaybe smks $ do
    mks <- M.lookup hk smks
    _ <- M.lookup msgN mks
    let mks' = M.delete msgN mks
    pure $
      if M.null mks'
        then M.delete hk smks
        else M.insert hk mks' smks
  SMDAdd smks' ->
    let merge hk mks = M.alter (Just . maybe mks (M.union mks)) hk
     in M.foldrWithKey merge smks smks'

type HeaderKey = Key

data MessageKey = MessageKey Key IV

instance Encoding MessageKey where
  smpEncode (MessageKey (Key key) (IV iv)) = smpEncode (key, iv)
  smpP = MessageKey <$> (Key <$> smpP) <*> (IV <$> smpP)

-- | Input key material for double ratchet HKDF functions
newtype RatchetKey = RatchetKey ByteString
  deriving (Show)

instance ToJSON RatchetKey where
  toJSON (RatchetKey k) = strToJSON k
  toEncoding (RatchetKey k) = strToJEncoding k

instance FromJSON RatchetKey where
  parseJSON = fmap RatchetKey . strParseJSON "Key"

instance ToField MessageKey where toField = toField . smpEncode

instance FromField MessageKey where fromField = blobFieldDecoder smpDecode

-- | Sending ratchet initialization
--
-- Please note that sPKey is not stored, and its public part together with random salt
-- is sent to the recipient.
-- @
-- RatchetInitAlicePQ2HE(state, SK, bob_dh_public_key, shared_hka, shared_nhkb, bob_pq_kem_encapsulation_key)
-- // below added for post-quantum KEM
-- state.PQRs = GENERATE_PQKEM()
-- state.PQRr = bob_pq_kem_encapsulation_key
-- state.PQRss = random // shared secret for KEM
-- state.PQRct = PQKEM-ENC(state.PQRr, state.PQRss) // encapsulated additional shared secret
-- // above added for KEM
-- @
initSndRatchet ::
  forall a. (AlgorithmI a, DhAlgorithm a) => VersionRange -> PublicKey a -> PrivateKey a -> (RatchetInitParams, Maybe KEMKeyPair) -> Ratchet a
initSndRatchet rcVersion rcDHRr rcDHRs (RatchetInitParams {assocData, ratchetKey, sndHK, rcvNextHK, kemAccepted}, rcPQRs_) = do
  -- state.RK, state.CKs, state.NHKs = KDF_RK_HE(SK, DH(state.DHRs, state.DHRr) || state.PQRss)
  let (rcRK, rcCKs, rcNHKs) = rootKdf ratchetKey rcDHRr rcDHRs (rcPQRss <$> kemAccepted)
   in Ratchet
        { rcVersion,
          rcAD = assocData,
          rcDHRs,
          rcKEM = (`RatchetKEM` kemAccepted) <$> rcPQRs_,
          rcEnableKEM = isJust rcPQRs_,
          rcSndKEM = isJust kemAccepted,
          rcRcvKEM = False,
          rcRK,
          rcSnd = Just SndRatchet {rcDHRr, rcCKs, rcHKs = sndHK},
          rcRcv = Nothing,
          rcPN = 0,
          rcNs = 0,
          rcNr = 0,
          rcNHKs,
          rcNHKr = rcvNextHK
        }

-- | Receiving ratchet initialization, equivalent to RatchetInitBobPQ2HE in double ratchet spec
--
-- def RatchetInitBobPQ2HE(state, SK, bob_dh_key_pair, shared_hka, shared_nhkb, bob_pq_kem_key_pair)
--
-- Please note that the public part of rcDHRs was sent to the sender
-- as part of the connection request and random salt was received from the sender.
initRcvRatchet ::
  forall a. (AlgorithmI a, DhAlgorithm a) => VersionRange -> PrivateKey a -> (RatchetInitParams, Maybe KEMKeyPair) -> EnableKEM -> Ratchet a
initRcvRatchet rcVersion rcDHRs (RatchetInitParams {assocData, ratchetKey, sndHK, rcvNextHK, kemAccepted}, rcPQRs_) enableKEM =
  Ratchet
    { rcVersion,
      rcAD = assocData,
      rcDHRs,
      -- rcKEM:
      -- state.PQRs = bob_pq_kem_key_pair
      -- state.PQRr = None
      -- state.PQRss = None
      -- state.PQRct = None
      rcKEM = (`RatchetKEM` kemAccepted) <$> rcPQRs_,
      rcEnableKEM = enableKEM == EnableKEM,
      rcSndKEM = False,
      rcRcvKEM = False,
      rcRK = ratchetKey,
      rcSnd = Nothing,
      rcRcv = Nothing,
      rcPN = 0,
      rcNs = 0,
      rcNr = 0,
      rcNHKs = rcvNextHK,
      rcNHKr = sndHK
    }

-- encaps = state.PQRs.encaps, // added for KEM #2
-- ct = state.PQRct // added for KEM #1
data MsgHeader a = MsgHeader
  { -- | max supported ratchet version
    msgMaxVersion :: Version,
    msgDHRs :: PublicKey a,
    msgKEM :: Maybe ARKEMParams,
    msgPN :: Word32,
    msgNs :: Word32
  }
  deriving (Show)

data AMsgHeader
  = forall a.
    (AlgorithmI a, DhAlgorithm a) =>
    AMsgHeader (SAlgorithm a) (MsgHeader a)

-- to allow extension without increasing the size, the actual header length is:
-- 69 = 2 (original size) + 2 + 1+56 (Curve448) + 4 + 4
-- TODO this must be version-dependent
-- TODO this is the exact size, some reserve should be added
paddedHeaderLen :: Int
paddedHeaderLen = 2284

-- only used in tests to validate correct padding
-- (2 bytes - version size, 1 byte - header size, not to have it fixed or version-dependent)
fullHeaderLen :: Int
fullHeaderLen = 2 + 1 + paddedHeaderLen + authTagSize + ivSize @AES256

instance AlgorithmI a => Encoding (MsgHeader a) where
  smpEncode MsgHeader {msgMaxVersion, msgDHRs, msgKEM, msgPN, msgNs}
    | msgMaxVersion >= pqRatchetVersion = smpEncode (msgMaxVersion, msgDHRs, msgKEM, msgPN, msgNs)
    | otherwise = smpEncode (msgMaxVersion, msgDHRs, msgPN, msgNs)
  smpP = do
    msgMaxVersion <- smpP
    msgDHRs <- smpP
    msgKEM <- if msgMaxVersion >= pqRatchetVersion then smpP else pure Nothing
    msgPN <- smpP
    msgNs <- smpP
    pure MsgHeader {msgMaxVersion, msgDHRs, msgKEM, msgPN, msgNs}

data EncMessageHeader = EncMessageHeader
  { ehVersion :: Version,
    ehIV :: IV,
    ehAuthTag :: AuthTag,
    ehBody :: ByteString
  }

instance Encoding EncMessageHeader where
  smpEncode EncMessageHeader {ehVersion, ehIV, ehAuthTag, ehBody}
    | ehVersion >= pqRatchetVersion = smpEncode (ehVersion, ehIV, ehAuthTag, Large ehBody)
    | otherwise = smpEncode (ehVersion, ehIV, ehAuthTag, ehBody)
  smpP = do
    (ehVersion, ehIV, ehAuthTag) <- smpP
    ehBody <- if ehVersion >= pqRatchetVersion then unLarge <$> smpP else smpP
    pure EncMessageHeader {ehVersion, ehIV, ehAuthTag, ehBody}

data EncRatchetMessage = EncRatchetMessage
  { emHeader :: ByteString,
    emAuthTag :: AuthTag,
    emBody :: ByteString
  }

encodeEncRatchetMessage :: Version -> EncRatchetMessage -> ByteString
encodeEncRatchetMessage v EncRatchetMessage {emHeader, emBody, emAuthTag}
  | v >= pqRatchetVersion = smpEncode (Large emHeader, emAuthTag, Tail emBody)
  | otherwise = smpEncode (emHeader, emAuthTag, Tail emBody)

encRatchetMessageP :: Version -> Parser EncRatchetMessage
encRatchetMessageP v = do
  emHeader <- if v >= pqRatchetVersion then unLarge <$> smpP else smpP
  (emAuthTag, Tail emBody) <- smpP
  pure EncRatchetMessage {emHeader, emBody, emAuthTag}

data EnableKEM = EnableKEM | DisableKEM
  deriving (Eq, Show)

proposeKEM_ :: EnableKEM -> Maybe (UseKEM 'RKSProposed)
proposeKEM_ = \case
  EnableKEM -> Just ProposeKEM
  DisableKEM -> Nothing

connProposeKEM_ :: PQConnMode -> Maybe (UseKEM 'RKSProposed)
connProposeKEM_ = \case
  PQInvitation -> Just ProposeKEM
  PQEnable -> Nothing
  PQDisable -> Nothing

replyKEM_ :: EnableKEM -> Maybe (RKEMParams 'RKSProposed) -> Maybe AUseKEM
replyKEM_ enableKEM kem_ = case enableKEM of
  EnableKEM -> Just $ case kem_ of
    Just (RKParamsProposed k) -> AUseKEM SRKSAccepted $ AcceptKEM k
    Nothing -> AUseKEM SRKSProposed ProposeKEM
  DisableKEM -> Nothing

instance StrEncoding EnableKEM where
  strEncode = \case
    EnableKEM -> "kem=enable"
    DisableKEM -> "kem=disable"
  strP =
    A.takeTill (== ' ') >>= \case
      "kem=enable" -> pure EnableKEM
      "kem=disable" -> pure DisableKEM
      _ -> fail "bad EnableKEM"

data PQConnMode = PQInvitation | PQEnable | PQDisable
  deriving (Show)

instance StrEncoding PQConnMode where
  strEncode = \case
    PQInvitation -> "pq=invitation"
    PQEnable -> "pq=enable"
    PQDisable -> "pq=disable"
  strP =
    A.takeTill (== ' ') >>= \case
      "pq=invitation" -> pure PQInvitation
      "pq=enable" -> pure PQEnable
      "pq=disable" -> pure PQDisable
      _ -> fail "bad PQConnMode"

connEnableKEM :: PQConnMode -> EnableKEM
connEnableKEM = \case
  PQInvitation -> EnableKEM
  PQEnable -> EnableKEM
  PQDisable -> DisableKEM

joinContactEnableKEM :: EnableKEM -> PQConnMode
joinContactEnableKEM = \case
  EnableKEM -> PQInvitation
  DisableKEM -> PQDisable

createConnEnableKEM :: EnableKEM -> PQConnMode
createConnEnableKEM = \case
  EnableKEM -> PQEnable
  DisableKEM -> PQDisable

type PQEncryption = Bool

rcEncrypt :: AlgorithmI a => Ratchet a -> Int -> ByteString -> Maybe EnableKEM -> ExceptT CryptoError IO (ByteString, Ratchet a)
rcEncrypt Ratchet {rcSnd = Nothing} _ _ _ = throwE CERatchetState
rcEncrypt rc@Ratchet {rcSnd = Just sr@SndRatchet {rcCKs, rcHKs}, rcDHRs, rcKEM, rcNs, rcPN, rcAD = Str rcAD, rcVersion} paddedMsgLen msg enableKEM_ = do
  -- state.CKs, mk = KDF_CK(state.CKs)
  let (ck', mk, iv, ehIV) = chainKdf rcCKs
  -- enc_header = HENCRYPT(state.HKs, header)
  (ehAuthTag, ehBody) <- encryptAEAD rcHKs ehIV paddedHeaderLen rcAD msgHeader
  -- return enc_header, ENCRYPT(mk, plaintext, CONCAT(AD, enc_header))
  -- TODO versioning in Ratchet should change somehow
  let emHeader = smpEncode EncMessageHeader {ehVersion = maxVersion rcVersion, ehBody, ehAuthTag, ehIV}
  (emAuthTag, emBody) <- encryptAEAD mk iv paddedMsgLen (rcAD <> emHeader) msg
  let msg' = encodeEncRatchetMessage (maxVersion rcVersion) EncRatchetMessage {emHeader, emBody, emAuthTag}
      -- state.Ns += 1
      rc' = rc {rcSnd = Just sr {rcCKs = ck'}, rcNs = rcNs + 1}
      rc'' = case enableKEM_ of
        Nothing -> rc'
        Just EnableKEM -> rc' {rcEnableKEM = True}
        Just DisableKEM ->
          let rcKEM' = (\rck -> rck {rcKEMs = Nothing}) <$> rcKEM
           in rc' {rcEnableKEM = False, rcKEM = rcKEM'}
  pure (msg', rc'')
  where
    -- header = HEADER_PQ2(
    --   dh = state.DHRs.public,
    --   kem = state.PQRs.public, // added for KEM #2
    --   ct = state.PQRct, // added for KEM #1
    --   pn = state.PN,
    --   n = state.Ns
    -- )
    msgHeader =
      smpEncode
        MsgHeader
          { msgMaxVersion = maxVersion rcVersion,
            msgDHRs = publicKey rcDHRs,
            msgKEM = msgKEMParams <$> rcKEM,
            msgPN = rcPN,
            msgNs = rcNs
          }
    msgKEMParams RatchetKEM {rcPQRs = (k, _), rcKEMs} = case rcKEMs of
      Nothing -> ARKP SRKSProposed $ RKParamsProposed k
      Just RatchetKEMAccepted {rcPQRct} -> ARKP SRKSAccepted $ RKParamsAccepted rcPQRct k

data SkippedMessage a
  = SMMessage (DecryptResult a)
  | SMHeader (Maybe RatchetStep) (MsgHeader a)
  | SMNone

data RatchetStep = AdvanceRatchet | SameRatchet
  deriving (Eq, Show)

type DecryptResult a = (Either CryptoError ByteString, Ratchet a, SkippedMsgDiff)

maxSkip :: Word32
maxSkip = 512

rcDecrypt ::
  forall a.
  (AlgorithmI a, DhAlgorithm a) =>
  TVar ChaChaDRG ->
  Ratchet a ->
  SkippedMsgKeys ->
  ByteString ->
  ExceptT CryptoError IO (DecryptResult a)
rcDecrypt g rc@Ratchet {rcRcv, rcAD = Str rcAD, rcVersion} rcMKSkipped msg' = do
  -- TODO versioning should change
  encMsg@EncRatchetMessage {emHeader} <- parseE CryptoHeaderError (encRatchetMessageP $ maxVersion rcVersion) msg'
  encHdr <- parseE CryptoHeaderError smpP emHeader
  -- plaintext = TrySkippedMessageKeysHE(state, enc_header, cipher-text, AD)
  decryptSkipped encHdr encMsg >>= \case
    SMNone -> do
      (rcStep, hdr) <- decryptRcHeader rcRcv encHdr
      decryptRcMessage rcStep hdr encMsg
    SMHeader rcStep_ hdr ->
      case rcStep_ of
        Just rcStep -> decryptRcMessage rcStep hdr encMsg
        Nothing -> throwE CERatchetHeader
    SMMessage r -> pure r
  where
    decryptRcMessage :: RatchetStep -> MsgHeader a -> EncRatchetMessage -> ExceptT CryptoError IO (DecryptResult a)
    decryptRcMessage rcStep MsgHeader {msgDHRs, msgKEM, msgPN, msgNs} encMsg = do
      -- if dh_ratchet:
      (rc', smks1) <- ratchetStep rcStep
      case skipMessageKeys msgNs rc' of
        Left e -> pure (Left e, rc', smkDiff smks1)
        Right (rc''@Ratchet {rcRcv = Just rr@RcvRatchet {rcCKr}, rcNr}, smks2) -> do
          -- state.CKr, mk = KDF_CK(state.CKr)
          let (rcCKr', mk, iv, _) = chainKdf rcCKr
          -- return DECRYPT (mk, cipher-text, CONCAT (AD, enc_header))
          msg <- decryptMessage (MessageKey mk iv) encMsg
          -- state . Nr += 1
          pure (msg, rc'' {rcRcv = Just rr {rcCKr = rcCKr'}, rcNr = rcNr + 1}, smkDiff $ smks1 <> smks2)
        Right (rc'', smks2) -> do
          pure (Left CERatchetState, rc'', smkDiff $ smks1 <> smks2)
      where
        smkDiff :: SkippedMsgKeys -> SkippedMsgDiff
        smkDiff smks = if M.null smks then SMDNoChange else SMDAdd smks
        ratchetStep :: RatchetStep -> ExceptT CryptoError IO (Ratchet a, SkippedMsgKeys)
        ratchetStep SameRatchet = pure (rc, M.empty)
        ratchetStep AdvanceRatchet =
          -- SkipMessageKeysHE(state, header.pn)
          case skipMessageKeys msgPN rc of
            Left e -> throwE e
            Right (rc'@Ratchet {rcDHRs, rcRK, rcNHKs, rcNHKr}, hmks) -> do
              -- DHRatchetPQ2HE(state, header)
              (kemSS, kemSS', rcKEM') <- pqRatchetStep rc' msgKEM
              -- state.DHRs = GENERATE_DH()
              (_, rcDHRs') <- atomically $ generateKeyPair @a g
              -- state.RK, state.CKr, state.NHKr = KDF_RK_HE(state.RK, DH(state.DHRs, state.DHRr) || ss)
              let (rcRK', rcCKr', rcNHKr') = rootKdf rcRK msgDHRs rcDHRs kemSS
                  -- state.RK, state.CKs, state.NHKs = KDF_RK_HE(state.RK, DH(state.DHRs, state.DHRr) || state.PQRss)
                  (rcRK'', rcCKs', rcNHKs') = rootKdf rcRK' msgDHRs rcDHRs' kemSS'
                  rcSndKEM = isJust kemSS'
                  rcRcvKEM = isJust kemSS
                  rc'' =
                    rc'
                      { rcDHRs = rcDHRs',
                        rcKEM = rcKEM',
                        rcEnableKEM = rcSndKEM || rcRcvKEM,
                        rcSndKEM,
                        rcRcvKEM,
                        rcRK = rcRK'',
                        rcSnd = Just SndRatchet {rcDHRr = msgDHRs, rcCKs = rcCKs', rcHKs = rcNHKs},
                        rcRcv = Just RcvRatchet {rcCKr = rcCKr', rcHKr = rcNHKr},
                        rcPN = rcNs rc,
                        rcNs = 0,
                        rcNr = 0,
                        rcNHKs = rcNHKs',
                        rcNHKr = rcNHKr'
                      }
              pure (rc'', hmks)
        pqRatchetStep :: Ratchet a -> Maybe ARKEMParams -> ExceptT CryptoError IO (Maybe KEMSharedKey, Maybe KEMSharedKey, Maybe RatchetKEM)
        pqRatchetStep Ratchet {rcKEM, rcEnableKEM} = \case
          -- received message does not have KEM in header,
          -- but the user enabled KEM when sending previous message
          Nothing -> case rcKEM of
            Nothing | rcEnableKEM -> do
              rcPQRs <- liftIO $ sntrup761Keypair g
              pure (Nothing, Nothing, Just RatchetKEM {rcPQRs, rcKEMs = Nothing})
            _ -> pure (Nothing, Nothing, Nothing)
          -- received message has KEM in header.
          Just (ARKP _ ps)
            | rcEnableKEM -> do
                -- state.PQRr = header.kem
                (ss, rcPQRr) <- sharedSecret
                -- state.PQRct = PQKEM-ENC(state.PQRr, state.PQRss) // encapsulated additional shared secret KEM #1
                (rcPQRct, rcPQRss) <- liftIO $ sntrup761Enc g rcPQRr
                -- state.PQRs = GENERATE_PQKEM()
                rcPQRs <- liftIO $ sntrup761Keypair g
                let kem' = RatchetKEM {rcPQRs, rcKEMs = Just RatchetKEMAccepted {rcPQRr, rcPQRss, rcPQRct}}
                pure (ss, Just rcPQRss, Just kem')
            | otherwise -> do
                -- state.PQRr = header.kem
                (ss, _) <- sharedSecret
                pure (ss, Nothing, Nothing)
            where
              sharedSecret = case ps of
                RKParamsProposed k -> pure (Nothing, k)
                RKParamsAccepted ct k -> case rcKEM of
                  Nothing -> throwE CERatchetKEMState
                  -- ss = PQKEM-DEC(state.PQRs.private, header.ct)
                  Just RatchetKEM {rcPQRs} -> do
                    ss <- liftIO $ sntrup761Dec ct (snd rcPQRs)
                    pure (Just ss, k)
    skipMessageKeys :: Word32 -> Ratchet a -> Either CryptoError (Ratchet a, SkippedMsgKeys)
    skipMessageKeys _ r@Ratchet {rcRcv = Nothing} = Right (r, M.empty)
    skipMessageKeys untilN r@Ratchet {rcRcv = Just rr@RcvRatchet {rcCKr, rcHKr}, rcNr}
      | rcNr > untilN + 1 = Left $ CERatchetEarlierMessage (rcNr - untilN - 1)
      | rcNr == untilN + 1 = Left CERatchetDuplicateMessage
      | rcNr + maxSkip < untilN = Left $ CERatchetTooManySkipped (untilN + 1 - rcNr)
      | rcNr == untilN = Right (r, M.empty)
      | otherwise =
          let (rcCKr', rcNr', mks) = advanceRcvRatchet (untilN - rcNr) rcCKr rcNr M.empty
              r' = r {rcRcv = Just rr {rcCKr = rcCKr'}, rcNr = rcNr'}
           in Right (r', M.singleton rcHKr mks)
    advanceRcvRatchet :: Word32 -> RatchetKey -> Word32 -> SkippedHdrMsgKeys -> (RatchetKey, Word32, SkippedHdrMsgKeys)
    advanceRcvRatchet 0 ck msgNs mks = (ck, msgNs, mks)
    advanceRcvRatchet n ck msgNs mks =
      let (ck', mk, iv, _) = chainKdf ck
          mks' = M.insert msgNs (MessageKey mk iv) mks
       in advanceRcvRatchet (n - 1) ck' (msgNs + 1) mks'
    decryptSkipped :: EncMessageHeader -> EncRatchetMessage -> ExceptT CryptoError IO (SkippedMessage a)
    decryptSkipped encHdr encMsg = tryDecryptSkipped SMNone $ M.assocs rcMKSkipped
      where
        tryDecryptSkipped :: SkippedMessage a -> [(HeaderKey, SkippedHdrMsgKeys)] -> ExceptT CryptoError IO (SkippedMessage a)
        tryDecryptSkipped SMNone ((hk, mks) : hks) = do
          tryE (decryptHeader hk encHdr) >>= \case
            Left CERatchetHeader -> tryDecryptSkipped SMNone hks
            Left e -> throwE e
            Right hdr@MsgHeader {msgNs} ->
              case M.lookup msgNs mks of
                Nothing ->
                  let nextRc
                        | maybe False ((== hk) . rcHKr) rcRcv = Just SameRatchet
                        | hk == rcNHKr rc = Just AdvanceRatchet
                        | otherwise = Nothing
                   in pure $ SMHeader nextRc hdr
                Just mk -> do
                  msg <- decryptMessage mk encMsg
                  pure $ SMMessage (msg, rc, SMDRemove hk msgNs)
        tryDecryptSkipped r _ = pure r
    decryptRcHeader :: Maybe RcvRatchet -> EncMessageHeader -> ExceptT CryptoError IO (RatchetStep, MsgHeader a)
    decryptRcHeader Nothing hdr = decryptNextHeader hdr
    decryptRcHeader (Just RcvRatchet {rcHKr}) hdr =
      -- header = HDECRYPT(state.HKr, enc_header)
      ((SameRatchet,) <$> decryptHeader rcHKr hdr) `catchE` \case
        CERatchetHeader -> decryptNextHeader hdr
        e -> throwE e
    -- header = HDECRYPT(state.NHKr, enc_header)
    decryptNextHeader hdr = (AdvanceRatchet,) <$> decryptHeader (rcNHKr rc) hdr
    decryptHeader k EncMessageHeader {ehBody, ehAuthTag, ehIV} = do
      header <- decryptAEAD k ehIV rcAD ehBody ehAuthTag `catchE` \_ -> throwE CERatchetHeader
      parseE' CryptoHeaderError smpP header
    decryptMessage :: MessageKey -> EncRatchetMessage -> ExceptT CryptoError IO (Either CryptoError ByteString)
    decryptMessage (MessageKey mk iv) EncRatchetMessage {emHeader, emBody, emAuthTag} =
      -- DECRYPT(mk, cipher-text, CONCAT(AD, enc_header))
      tryE $ decryptAEAD mk iv (rcAD <> emHeader) emBody emAuthTag

rootKdf :: (AlgorithmI a, DhAlgorithm a) => RatchetKey -> PublicKey a -> PrivateKey a -> Maybe KEMSharedKey -> (RatchetKey, RatchetKey, Key)
rootKdf (RatchetKey rk) k pk kemSecret_ =
  let dhOut = dhBytes' (dh' k pk)
      ss = case kemSecret_ of
        Just (KEMSharedKey s) -> dhOut <> BA.convert s
        Nothing -> dhOut
      (rk', ck, nhk) = hkdf3 rk ss "SimpleXRootRatchet"
   in (RatchetKey rk', RatchetKey ck, Key nhk)

chainKdf :: RatchetKey -> (RatchetKey, Key, IV, IV)
chainKdf (RatchetKey ck) =
  let (ck', mk, ivs) = hkdf3 "" ck "SimpleXChainRatchet"
      (iv1, iv2) = B.splitAt 16 ivs
   in (RatchetKey ck', Key mk, IV iv1, IV iv2)

hkdf3 :: ByteString -> ByteString -> ByteString -> (ByteString, ByteString, ByteString)
hkdf3 salt ikm info = (s1, s2, s3)
  where
    prk = H.extract salt ikm :: H.PRK SHA512
    out = H.expand prk info 96
    (s1, rest) = B.splitAt 32 out
    (s2, s3) = B.splitAt 32 rest

$(JQ.deriveJSON defaultJSON ''RcvRatchet)

$(JQ.deriveJSON defaultJSON ''RatchetKEMAccepted)

$(JQ.deriveJSON defaultJSON ''RatchetKEM)

instance AlgorithmI a => ToJSON (SndRatchet a) where
  toEncoding = $(JQ.mkToEncoding defaultJSON ''SndRatchet)
  toJSON = $(JQ.mkToJSON defaultJSON ''SndRatchet)

instance AlgorithmI a => FromJSON (SndRatchet a) where
  parseJSON = $(JQ.mkParseJSON defaultJSON ''SndRatchet)

instance AlgorithmI a => ToJSON (Ratchet a) where
  toEncoding = $(JQ.mkToEncoding defaultJSON ''Ratchet)
  toJSON = $(JQ.mkToJSON defaultJSON ''Ratchet)

instance AlgorithmI a => FromJSON (Ratchet a) where
  parseJSON = $(JQ.mkParseJSON defaultJSON ''Ratchet)

instance AlgorithmI a => ToField (Ratchet a) where toField = toField . LB.toStrict . J.encode

instance (AlgorithmI a, Typeable a) => FromField (Ratchet a) where fromField = blobFieldDecoder J.eitherDecodeStrict'
