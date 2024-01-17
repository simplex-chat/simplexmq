{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# OPTIONS_GHC -fno-warn-redundant-constraints #-}

module Simplex.Messaging.Crypto.Ratchet where

import Control.Monad.Except
import Control.Monad.Trans.Except
import Crypto.Cipher.AES (AES256)
import Crypto.Hash (SHA512)
import qualified Crypto.KDF.HKDF as H
import Crypto.Random (ChaChaDRG)
import Data.Aeson (FromJSON (..), ToJSON (..))
import qualified Data.Aeson as J
import qualified Data.Aeson.TH as JQ
import Data.Bifunctor (bimap)
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import qualified Data.ByteString.Lazy as LB
import qualified Data.List.NonEmpty as L
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import Data.Maybe (fromMaybe)
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
import Simplex.Messaging.Version
import UnliftIO.STM

currentE2EEncryptVersion :: Version
currentE2EEncryptVersion = 3

pqRatchetVersion :: Version
pqRatchetVersion = 3

supportedE2EEncryptVRange :: VersionRange
supportedE2EEncryptVRange = mkVersionRange 1 currentE2EEncryptVersion

data E2ERatchetParams (a :: Algorithm) kem
  = E2ERatchetParams Version (PublicKey a) (PublicKey a) (Maybe kem)
  deriving (Eq, Show)

instance (AlgorithmI a, Encoding kem) => Encoding (E2ERatchetParams a kem) where
  smpEncode (E2ERatchetParams v k1 k2 kem)
    | v >= pqRatchetVersion = smpEncode (v, k1, k2, kem)
    | otherwise = smpEncode (v, k1, k2)
  smpP = smpP >>= \v -> E2ERatchetParams v <$> smpP <*> smpP <*> kemP v
    where
      kemP v
        | v >= pqRatchetVersion = smpP
        | otherwise = pure Nothing

instance VersionI (E2ERatchetParams a kem) where
  type VersionRangeT (E2ERatchetParams a kem) = E2ERatchetParamsUri a kem
  version (E2ERatchetParams v _ _ _) = v
  toVersionRangeT (E2ERatchetParams _ k1 k2 kem) vr = E2ERatchetParamsUri vr k1 k2 kem

instance VersionRangeI (E2ERatchetParamsUri a kem) where
  type VersionT (E2ERatchetParamsUri a kem) = (E2ERatchetParams a kem)
  versionRange (E2ERatchetParamsUri vr _ _ _) = vr
  toVersionT (E2ERatchetParamsUri _ k1 k2 kem) v = E2ERatchetParams v k1 k2 kem

type RcvE2ERatchetParamsUri a = E2ERatchetParamsUri a KEMPublicKey

data E2ERatchetParamsUri (a :: Algorithm) kem
  = E2ERatchetParamsUri VersionRange (PublicKey a) (PublicKey a) (Maybe kem)
  deriving (Eq, Show)

instance (AlgorithmI a, StrEncoding kem) => StrEncoding (E2ERatchetParamsUri a kem) where
  strEncode (E2ERatchetParamsUri vs key1 key2 kem_) =
    strEncode . QSP QNoEscaping $
      [("v", strEncode vs), ("x3dh", strEncodeList [key1, key2])]
        <> maybe [] (\kem -> [("kem", strEncode kem) | maxVersion vs >= pqRatchetVersion]) kem_
  strP = do
    query <- strP
    vs <- queryParam "v" query
    keys <- L.toList <$> queryParam "x3dh" query
    case keys of
      [key1, key2] -> E2ERatchetParamsUri vs key1 key2 <$> kemP vs query
      _ -> fail "bad e2e params"
    where
      kemP vs query
        | maxVersion vs >= pqRatchetVersion = queryParam_ "kem" query
        | otherwise = pure Nothing

data E2ERachetKEM = E2ERachetKEM KEMPublicKey (Maybe KEMCiphertext)
  deriving (Eq, Show)

instance Encoding E2ERachetKEM where
  smpEncode (E2ERachetKEM k ct) = smpEncode (k, ct)
  smpP = E2ERachetKEM <$> smpP <*> smpP

type RcvE2ERatchetParams a = E2ERatchetParams a KEMPublicKey

type SndE2ERatchetParams a = E2ERatchetParams a E2ERachetKEM

toSndE2EParams :: RcvE2ERatchetParams a -> SndE2ERatchetParams a
toSndE2EParams (E2ERatchetParams v k1 k2 kem_) = E2ERatchetParams v k1 k2 ((`E2ERachetKEM` Nothing) <$> kem_)

data PrivateE2ERachetKEM = PrivateE2ERachetKEM KEMKeyPair (Maybe KEMSharedKey)

-- if version supports KEM and withKEM is True, the result will include KEMSecretKey and KEMPublicKey in RcvE2ERatchetParams
generateRcvE2EParams :: (AlgorithmI a, DhAlgorithm a) => TVar ChaChaDRG -> Version -> Bool -> IO (PrivateKey a, PrivateKey a, Maybe KEMKeyPair, RcvE2ERatchetParams a)
generateRcvE2EParams g v withKEM = do
  (k1, pk1) <- atomically $ generateKeyPair g
  (k2, pk2) <- atomically $ generateKeyPair g
  pKem <- kemPair
  pure (pk1, pk2, pKem, E2ERatchetParams v k1 k2 (fst <$> pKem))
  where
    kemPair
      | v >= pqRatchetVersion && withKEM = Just <$> sntrup761Keypair g
      | otherwise = pure Nothing

data WithKEM = NoKEM | WithKEM (Maybe KEMPublicKey)

-- if version supports KEM, the result will depend on WithKEM parameter:
-- NoKEM: no PrivateE2ERachetKEM, no E2ERachetKEM in SndE2ERatchetParams
-- WithKEM Nothing: PrivateE2ERachetKEM without KEMSharedKey, E2ERachetKEM in SndE2ERatchetParams without KEMCiphertext
-- WithKEM (Just KEMPublicKey): PrivateE2ERachetKEM with KEMSharedKey, E2ERachetKEM in SndE2ERatchetParams with KEMCiphertext
generateSndE2EParams :: (AlgorithmI a, DhAlgorithm a) => TVar ChaChaDRG -> Version -> WithKEM -> IO (PrivateKey a, PrivateKey a, Maybe PrivateE2ERachetKEM, SndE2ERatchetParams a)
generateSndE2EParams g v withKEM = do
  (k1, pk1) <- atomically $ generateKeyPair g
  (k2, pk2) <- atomically $ generateKeyPair g
  (kem, pKemParams) <- kemParams
  pure (pk1, pk2, pKemParams, E2ERatchetParams v k1 k2 kem)
  where
    kemParams = case withKEM of
      WithKEM kem_ | v >= pqRatchetVersion -> do
        pKem@(kem, _) <- sntrup761Keypair g
        (ct_, shared_) <- case kem_ of
          Just k -> bimap Just Just <$> sntrup761Enc g k
          Nothing -> pure (Nothing, Nothing)
        pure (Just $ E2ERachetKEM kem ct_, Just $ PrivateE2ERachetKEM pKem shared_)
      _ -> pure (Nothing, Nothing)

data RatchetInitParams = RatchetInitParams
  { assocData :: Str,
    ratchetKey :: RatchetKey,
    sndHK :: HeaderKey,
    rcvNextHK :: HeaderKey
  }
  deriving (Eq, Show)

-- this is used by the peer joining the connection
pqX3dhSnd :: DhAlgorithm a => PrivateKey a -> PrivateKey a -> Maybe PrivateE2ERachetKEM -> RcvE2ERatchetParams a -> RatchetInitParams
pqX3dhSnd spk1 spk2 _ (E2ERatchetParams v rk1 rk2 _) =
  pqX3dh v (publicKey spk1, rk1) (dh' rk1 spk2) (dh' rk2 spk1) (dh' rk2 spk2)

-- this is used by the peer that created new connection, after receiving the reply
pqX3dhRcv :: DhAlgorithm a => PrivateKey a -> PrivateKey a -> Maybe KEMSecretKey -> SndE2ERatchetParams a -> RatchetInitParams
pqX3dhRcv rpk1 rpk2 _ (E2ERatchetParams v sk1 sk2 _) =
  pqX3dh v (sk1, publicKey rpk1) (dh' sk2 rpk1) (dh' sk1 rpk2) (dh' sk2 rpk2)

pqX3dh :: DhAlgorithm a => Version -> (PublicKey a, PublicKey a) -> DhSecret a -> DhSecret a -> DhSecret a -> RatchetInitParams
pqX3dh v (sk1, rk1) dh1 dh2 dh3 =
  RatchetInitParams {assocData, ratchetKey = RatchetKey sk, sndHK = Key hk, rcvNextHK = Key nhk}
  where
    assocData = Str $ pubKeyBytes sk1 <> pubKeyBytes rk1
    dhs = dhBytes' dh1 <> dhBytes' dh2 <> dhBytes' dh3
    (hk, nhk, sk)
      -- for backwards compatibility with clients using agent version before 3.4.0
      | v == 1 =
          let (hk', rest) = B.splitAt 32 dhs
           in uncurry (hk',,) $ B.splitAt 32 rest
      | otherwise =
          let salt = B.replicate 64 '\0'
           in hkdf3 salt dhs "SimpleXX3DH"

type RatchetX448 = Ratchet 'X448

data SndRatchetKEM = SndRatchetKEM
  { rcPQRr :: KEMPublicKey,
    rcPQRss :: KEMSharedKey,
    rcPQRct :: KEMCiphertext
  }
  deriving (Eq, Show)

data Ratchet a = Ratchet
  { -- ratchet version range sent in messages (current .. max supported ratchet version)
    rcVersion :: VersionRange,
    -- associated data - must be the same in both parties ratchets
    rcAD :: Str,
    rcDHRs :: PrivateKey a,
    rcPQRs :: Maybe KEMKeyPair,
    rcRK :: RatchetKey,
    rcSnd :: Maybe (SndRatchet a),
    rcRcv :: Maybe RcvRatchet,
    rcNs :: Word32,
    rcNr :: Word32,
    rcPN :: Word32,
    rcNHKs :: HeaderKey,
    rcNHKr :: HeaderKey
  }
  deriving (Eq, Show)

data SndRatchet a = SndRatchet
  { rcDHRr :: PublicKey a,
    rcPQR :: Maybe SndRatchetKEM,
    rcCKs :: RatchetKey,
    rcHKs :: HeaderKey
  }
  deriving (Eq, Show)

data RcvRatchet = RcvRatchet
  { rcCKr :: RatchetKey,
    rcHKr :: HeaderKey
  }
  deriving (Eq, Show)

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
  deriving (Eq, Show)

instance ToJSON RatchetKey where
  toJSON (RatchetKey k) = strToJSON k
  toEncoding (RatchetKey k) = strToJEncoding k

instance FromJSON RatchetKey where
  parseJSON = fmap RatchetKey . strParseJSON "Key"

instance ToField MessageKey where toField = toField . smpEncode

instance FromField MessageKey where fromField = blobFieldDecoder smpDecode

-- | Sending ratchet initialization, equivalent to RatchetInitAliceHE in double ratchet spec
--
-- Please note that sPKey is not stored, and its public part together with random salt
-- is sent to the recipient.
initSndRatchet ::
  forall a. (AlgorithmI a, DhAlgorithm a) => VersionRange -> PublicKey a -> PrivateKey a -> Maybe KEMKeyPair -> RatchetInitParams -> Ratchet a
initSndRatchet rcVersion rcDHRr rcDHRs rcPQRs RatchetInitParams {assocData, ratchetKey, sndHK, rcvNextHK} = do
  -- state.RK, state.CKs, state.NHKs = KDF_RK_HE(SK, DH(state.DHRs, state.DHRr))
  let (rcRK, rcCKs, rcNHKs) = rootKdf ratchetKey rcDHRr rcDHRs
   in Ratchet
        { rcVersion,
          rcAD = assocData,
          rcDHRs,
          rcPQRs,
          rcRK,
          rcSnd = Just SndRatchet {rcDHRr, rcPQR = Nothing, rcCKs, rcHKs = sndHK}, -- rcPQR should be initialized here
          rcRcv = Nothing,
          rcPN = 0,
          rcNs = 0,
          rcNr = 0,
          rcNHKs,
          rcNHKr = rcvNextHK
        }

-- | Receiving ratchet initialization, equivalent to RatchetInitBobHE in double ratchet spec
--
-- Please note that the public part of rcDHRs was sent to the sender
-- as part of the connection request and random salt was received from the sender.
initRcvRatchet ::
  forall a. (AlgorithmI a, DhAlgorithm a) => VersionRange -> PrivateKey a -> Maybe KEMKeyPair -> RatchetInitParams -> Ratchet a
initRcvRatchet rcVersion rcDHRs rcPQRs RatchetInitParams {assocData, ratchetKey, sndHK, rcvNextHK} =
  Ratchet
    { rcVersion,
      rcAD = assocData,
      rcDHRs,
      rcPQRs,
      rcRK = ratchetKey,
      rcSnd = Nothing,
      rcRcv = Nothing,
      rcPN = 0,
      rcNs = 0,
      rcNr = 0,
      rcNHKs = rcvNextHK,
      rcNHKr = sndHK
    }

data MsgHeader a = MsgHeader
  { -- | max supported ratchet version
    msgMaxVersion :: Version,
    msgDHRs :: PublicKey a,
    msgPN :: Word32,
    msgNs :: Word32
  }
  deriving (Eq, Show)

data AMsgHeader
  = forall a.
    (AlgorithmI a, DhAlgorithm a) =>
    AMsgHeader (SAlgorithm a) (MsgHeader a)

-- to allow extension without increasing the size, the actual header length is:
-- 69 = 2 (original size) + 2 + 1+56 (Curve448) + 4 + 4
paddedHeaderLen :: Int
paddedHeaderLen = 88

-- only used in tests to validate correct padding
-- (2 bytes - version size, 1 byte - header size, not to have it fixed or version-dependent)
fullHeaderLen :: Int
fullHeaderLen = 2 + 1 + paddedHeaderLen + authTagSize + ivSize @AES256

instance AlgorithmI a => Encoding (MsgHeader a) where
  smpEncode MsgHeader {msgMaxVersion, msgDHRs, msgPN, msgNs} =
    smpEncode (msgMaxVersion, msgDHRs, msgPN, msgNs)
  smpP = do
    msgMaxVersion <- smpP
    msgDHRs <- smpP
    msgPN <- smpP
    msgNs <- smpP
    pure MsgHeader {msgMaxVersion, msgDHRs, msgPN, msgNs}

data EncMessageHeader = EncMessageHeader
  { ehVersion :: Version,
    ehIV :: IV,
    ehAuthTag :: AuthTag,
    ehBody :: ByteString
  }

instance Encoding EncMessageHeader where
  smpEncode EncMessageHeader {ehVersion, ehIV, ehAuthTag, ehBody} =
    smpEncode (ehVersion, ehIV, ehAuthTag, ehBody)
  smpP = do
    (ehVersion, ehIV, ehAuthTag, ehBody) <- smpP
    pure EncMessageHeader {ehVersion, ehIV, ehAuthTag, ehBody}

data EncRatchetMessage = EncRatchetMessage
  { emHeader :: ByteString,
    emAuthTag :: AuthTag,
    emBody :: ByteString
  }

instance Encoding EncRatchetMessage where
  smpEncode EncRatchetMessage {emHeader, emBody, emAuthTag} =
    smpEncode (emHeader, emAuthTag, Tail emBody)
  smpP = do
    (emHeader, emAuthTag, Tail emBody) <- smpP
    pure EncRatchetMessage {emHeader, emBody, emAuthTag}

rcEncrypt :: AlgorithmI a => Ratchet a -> Int -> ByteString -> ExceptT CryptoError IO (ByteString, Ratchet a)
rcEncrypt Ratchet {rcSnd = Nothing} _ _ = throwE CERatchetState
rcEncrypt rc@Ratchet {rcSnd = Just sr@SndRatchet {rcCKs, rcHKs}, rcDHRs, rcNs, rcPN, rcAD = Str rcAD, rcVersion} paddedMsgLen msg = do
  -- state.CKs, mk = KDF_CK(state.CKs)
  let (ck', mk, iv, ehIV) = chainKdf rcCKs
  -- enc_header = HENCRYPT(state.HKs, header)
  (ehAuthTag, ehBody) <- encryptAEAD rcHKs ehIV paddedHeaderLen rcAD msgHeader
  -- return enc_header, ENCRYPT(mk, plaintext, CONCAT(AD, enc_header))
  let emHeader = smpEncode EncMessageHeader {ehVersion = minVersion rcVersion, ehBody, ehAuthTag, ehIV}
  (emAuthTag, emBody) <- encryptAEAD mk iv paddedMsgLen (rcAD <> emHeader) msg
  let msg' = smpEncode EncRatchetMessage {emHeader, emBody, emAuthTag}
      -- state.Ns += 1
      rc' = rc {rcSnd = Just sr {rcCKs = ck'}, rcNs = rcNs + 1}
  pure (msg', rc')
  where
    -- header = HEADER(state.DHRs, state.PN, state.Ns)
    msgHeader =
      smpEncode
        MsgHeader
          { msgMaxVersion = maxVersion rcVersion,
            msgDHRs = publicKey rcDHRs,
            msgPN = rcPN,
            msgNs = rcNs
          }

data SkippedMessage a
  = SMMessage (DecryptResult a)
  | SMHeader (Maybe RatchetStep) (MsgHeader a)
  | SMNone

data RatchetStep = AdvanceRatchet | SameRatchet
  deriving (Eq)

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
rcDecrypt g rc@Ratchet {rcRcv, rcAD = Str rcAD} rcMKSkipped msg' = do
  encMsg@EncRatchetMessage {emHeader} <- parseE CryptoHeaderError smpP msg'
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
    decryptRcMessage rcStep MsgHeader {msgDHRs, msgPN, msgNs} encMsg = do
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
              -- DHRatchetHE(state, header)
              (_, rcDHRs') <- atomically $ generateKeyPair @a g
              -- state.RK, state.CKr, state.NHKr = KDF_RK_HE(state.RK, DH(state.DHRs, state.DHRr))
              let (rcRK', rcCKr', rcNHKr') = rootKdf rcRK msgDHRs rcDHRs
                  -- state.RK, state.CKs, state.NHKs = KDF_RK_HE(state.RK, DH(state.DHRs, state.DHRr))
                  (rcRK'', rcCKs', rcNHKs') = rootKdf rcRK' msgDHRs rcDHRs'
                  rc'' =
                    rc'
                      { rcDHRs = rcDHRs',
                        rcPQRs = Nothing, -- update
                        rcRK = rcRK'',
                        rcSnd = Just SndRatchet {rcDHRr = msgDHRs, rcPQR = Nothing, rcCKs = rcCKs', rcHKs = rcNHKs},
                        rcRcv = Just RcvRatchet {rcCKr = rcCKr', rcHKr = rcNHKr},
                        rcPN = rcNs rc,
                        rcNs = 0,
                        rcNr = 0,
                        rcNHKs = rcNHKs',
                        rcNHKr = rcNHKr'
                      }
              pure (rc'', hmks)
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

rootKdf :: (AlgorithmI a, DhAlgorithm a) => RatchetKey -> PublicKey a -> PrivateKey a -> (RatchetKey, RatchetKey, Key)
rootKdf (RatchetKey rk) k pk =
  let dhOut = dhBytes' $ dh' k pk
      (rk', ck, nhk) = hkdf3 rk dhOut "SimpleXRootRatchet"
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

$(JQ.deriveJSON defaultJSON ''SndRatchetKEM)

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
