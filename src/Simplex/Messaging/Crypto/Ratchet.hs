{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeApplications #-}

module Simplex.Messaging.Crypto.Ratchet where

import Control.Monad.Except
import Control.Monad.Trans.Except
import Crypto.Cipher.AES (AES256)
import Crypto.Hash (SHA512)
import qualified Crypto.KDF.HKDF as H
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import Data.Maybe (fromMaybe)
import Data.Word (Word32)
import Simplex.Messaging.Crypto
import Simplex.Messaging.Encoding
import Simplex.Messaging.Parsers (parseE, parseE')
import Simplex.Messaging.Util (tryE)
import Simplex.Messaging.Version

e2eEncryptVersion :: Version
e2eEncryptVersion = 1

e2eEncryptVRange :: VersionRange
e2eEncryptVRange = mkVersionRange 1 e2eEncryptVersion

data Ratchet a = Ratchet
  { -- ratchet version range sent in messages (current .. max supported ratchet version)
    rcVersion :: VersionRange,
    -- associated data - must be the same in both parties ratchets
    rcAD :: ByteString,
    rcDHRs :: KeyPair a,
    rcRK :: RatchetKey,
    rcSnd :: Maybe (SndRatchet a),
    rcRcv :: Maybe RcvRatchet,
    rcNs :: Word32,
    rcNr :: Word32,
    rcPN :: Word32,
    rcNHKs :: HeaderKey,
    rcNHKr :: HeaderKey
  }

data SndRatchet a = SndRatchet
  { rcDHRr :: PublicKey a,
    rcCKs :: RatchetKey,
    rcHKs :: HeaderKey
  }

data RcvRatchet = RcvRatchet
  { rcCKr :: RatchetKey,
    rcHKr :: HeaderKey
  }

type SkippedMsgKeys = Map HeaderKey SkippedHdrMsgKeys

type SkippedHdrMsgKeys = Map Word32 MessageKey

data SkippedMsgDiff
  = SkippedMsgNoChange
  | SkippedMsgRemove HeaderKey Word32
  | SkippedMsgAdd SkippedMsgKeys

-- | this function is only used in tests to apply changes in skipped messages,
-- in the agent the diff is persisted, and the whole state is loaded for the next message.
applySkippedMsgDiff :: SkippedMsgKeys -> SkippedMsgDiff -> SkippedMsgKeys
applySkippedMsgDiff skippedMKs = \case
  SkippedMsgNoChange -> skippedMKs
  SkippedMsgRemove hk msgN -> fromMaybe skippedMKs $ do
    mks <- M.lookup hk skippedMKs
    _ <- M.lookup msgN mks
    let mks' = M.delete msgN mks
    pure $
      if M.null mks'
        then M.delete hk skippedMKs
        else M.insert hk mks' skippedMKs
  SkippedMsgAdd smks ->
    let merge hk mks = maybe mks (`M.union` mks) $ M.lookup hk smks
     in M.mapWithKey merge skippedMKs

type HeaderKey = Key

data MessageKey = MessageKey Key IV

data ARatchet
  = forall a.
    (AlgorithmI a, DhAlgorithm a) =>
    ARatchet (SAlgorithm a) (Ratchet a)

-- | Input key material for double ratchet HKDF functions
newtype RatchetKey = RatchetKey ByteString

-- | Sending ratchet initialization, equivalent to RatchetInitAliceHE in double ratchet spec
--
-- Please note that sPKey is not stored, and its public part together with random salt
-- is sent to the recipient.
initSndRatchet' ::
  forall a. (AlgorithmI a, DhAlgorithm a) => PublicKey a -> PrivateKey a -> ByteString -> ByteString -> IO (Ratchet a)
initSndRatchet' rcDHRr sPKey salt rcAD = do
  rcDHRs@(_, pk) <- generateKeyPair' @a
  let (sk, rcHKs, rcNHKr) = initKdf salt rcDHRr sPKey
      -- state.RK, state.CKs, state.NHKs = KDF_RK_HE(SK, DH(state.DHRs, state.DHRr))
      (rcRK, rcCKs, rcNHKs) = rootKdf sk rcDHRr pk
  pure
    Ratchet
      { rcVersion = e2eEncryptVRange,
        rcAD,
        rcDHRs,
        rcRK,
        rcSnd = Just SndRatchet {rcDHRr, rcCKs, rcHKs},
        rcRcv = Nothing,
        rcPN = 0,
        rcNs = 0,
        rcNr = 0,
        rcNHKs,
        rcNHKr
      }

-- | Receiving ratchet initialization, equivalent to RatchetInitBobHE in double ratchet spec
--
-- Please note that the public part of rcDHRs was sent to the sender
-- as part of the connection request and random salt was received from the sender.
initRcvRatchet' ::
  forall a. (AlgorithmI a, DhAlgorithm a) => PublicKey a -> KeyPair a -> ByteString -> ByteString -> IO (Ratchet a)
initRcvRatchet' sKey rcDHRs@(_, pk) salt rcAD = do
  let (sk, rcNHKr, rcNHKs) = initKdf salt sKey pk
  pure
    Ratchet
      { rcVersion = e2eEncryptVRange,
        rcAD,
        rcDHRs,
        rcRK = sk,
        rcSnd = Nothing,
        rcRcv = Nothing,
        rcPN = 0,
        rcNs = 0,
        rcNr = 0,
        rcNHKs,
        rcNHKr
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
-- 81 = 2 (original size) + 2 + 1 + 68 (Ed448) + 4 + 4
paddedHeaderLen :: Int
paddedHeaderLen = 96

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
    ehBody :: ByteString,
    ehAuthTag :: AuthTag,
    ehIV :: IV
  }

instance Encoding EncMessageHeader where
  smpEncode EncMessageHeader {ehVersion, ehBody, ehAuthTag, ehIV} =
    smpEncode (ehVersion, ehBody, ehAuthTag, ehIV)
  smpP = do
    ehVersion <- smpP
    ehBody <- smpP
    ehAuthTag <- smpP
    ehIV <- smpP
    pure EncMessageHeader {ehVersion, ehBody, ehAuthTag, ehIV}

data EncRatchetMessage = EncRatchetMessage
  { emHeader :: ByteString,
    emBody :: ByteString,
    emAuthTag :: AuthTag
  }

instance Encoding EncRatchetMessage where
  smpEncode EncRatchetMessage {emHeader, emBody, emAuthTag} =
    smpEncode (emHeader, emBody, emAuthTag)
  smpP = do
    emHeader <- smpP
    emBody <- smpP
    emAuthTag <- smpP
    pure EncRatchetMessage {emHeader, emBody, emAuthTag}

rcEncrypt' :: AlgorithmI a => Ratchet a -> Int -> ByteString -> ExceptT CryptoError IO (ByteString, Ratchet a)
rcEncrypt' Ratchet {rcSnd = Nothing} _ _ = throwE CERatchetState
rcEncrypt' rc@Ratchet {rcSnd = Just sr@SndRatchet {rcCKs, rcHKs}, rcNs, rcAD, rcVersion} paddedMsgLen msg = do
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
            msgDHRs = fst $ rcDHRs rc,
            msgPN = rcPN rc,
            msgNs = rcNs
          }

data SkippedMessage a
  = SMMessage (DecryptResult a)
  | SMHeader (Maybe RatchetStep) (MsgHeader a)
  | SMNone

data RatchetStep = AdvanceRatchet | SameRatchet
  deriving (Eq)

type DecryptResult a = (Either CryptoError ByteString, Ratchet a, SkippedMsgKeys)

maxSkip :: Word32
maxSkip = 512

rcDecrypt' ::
  forall a.
  (AlgorithmI a, DhAlgorithm a) =>
  Ratchet a ->
  SkippedMsgKeys ->
  ByteString ->
  ExceptT CryptoError IO (DecryptResult a)
rcDecrypt' rc@Ratchet {rcRcv, rcAD} rcMKSkipped msg' = do
  encMsg@EncRatchetMessage {emHeader} <- parseE CryptoHeaderError smpP msg'
  encHdr <- parseE CryptoHeaderError smpP emHeader
  -- plaintext = TrySkippedMessageKeysHE(state, enc_header, ciphertext, AD)
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
      (rc', rcMKSkipped') <- ratchetStep rcStep
      case skipMessageKeys msgNs rc' rcMKSkipped' of
        Left e -> pure (Left e, rc', rcMKSkipped')
        Right (rc''@Ratchet {rcRcv = Just rr@RcvRatchet {rcCKr}, rcNr}, rcMKSkipped'') -> do
          -- state.CKr, mk = KDF_CK(state.CKr)
          let (rcCKr', mk, iv, _) = chainKdf rcCKr
          -- return DECRYPT (mk, ciphertext, CONCAT (AD, enc_header))
          msg <- decryptMessage (MessageKey mk iv) encMsg
          -- state . Nr += 1
          pure (msg, rc'' {rcRcv = Just rr {rcCKr = rcCKr'}, rcNr = rcNr + 1}, rcMKSkipped'')
        Right (rc'', rcMKSkipped'') -> pure (Left CERatchetState, rc'', rcMKSkipped'')
      where
        ratchetStep :: RatchetStep -> ExceptT CryptoError IO (Ratchet a, SkippedMsgKeys)
        ratchetStep SameRatchet = pure (rc, rcMKSkipped)
        ratchetStep AdvanceRatchet =
          -- SkipMessageKeysHE(state, header.pn)
          case skipMessageKeys msgPN rc rcMKSkipped of
            Left e -> throwE e
            Right (rc'@Ratchet {rcDHRs, rcRK, rcNHKs, rcNHKr}, rcMKSkipped') -> do
              -- DHRatchetHE(state, header)
              rcDHRs' <- liftIO $ generateKeyPair' @a
              -- state.RK, state.CKr, state.NHKr = KDF_RK_HE(state.RK, DH(state.DHRs, state.DHRr))
              let (rcRK', rcCKr', rcNHKr') = rootKdf rcRK msgDHRs (snd rcDHRs)
                  -- state.RK, state.CKs, state.NHKs = KDF_RK_HE(state.RK, DH(state.DHRs, state.DHRr))
                  (rcRK'', rcCKs', rcNHKs') = rootKdf rcRK' msgDHRs (snd rcDHRs')
              pure
                ( rc'
                    { rcDHRs = rcDHRs',
                      rcRK = rcRK'',
                      rcSnd = Just SndRatchet {rcDHRr = msgDHRs, rcCKs = rcCKs', rcHKs = rcNHKs},
                      rcRcv = Just RcvRatchet {rcCKr = rcCKr', rcHKr = rcNHKr},
                      rcPN = rcNs rc,
                      rcNs = 0,
                      rcNr = 0,
                      rcNHKs = rcNHKs',
                      rcNHKr = rcNHKr'
                    },
                  rcMKSkipped'
                )
    skipMessageKeys :: Word32 -> Ratchet a -> SkippedMsgKeys -> Either CryptoError (Ratchet a, SkippedMsgKeys)
    skipMessageKeys _ r@Ratchet {rcRcv = Nothing} mkSkipped = Right (r, mkSkipped)
    skipMessageKeys untilN r@Ratchet {rcRcv = Just rr@RcvRatchet {rcCKr, rcHKr}, rcNr} mkSkipped
      | rcNr > untilN = Left CERatchetDuplicateMessage
      | rcNr + maxSkip < untilN = Left CERatchetTooManySkipped
      | rcNr == untilN = Right (r, mkSkipped)
      | otherwise =
        let mks = fromMaybe M.empty $ M.lookup rcHKr mkSkipped
            (rcCKr', rcNr', mks') = advanceRcvRatchet (untilN - rcNr) rcCKr rcNr mks
            mkSkipped' = M.insert rcHKr mks' mkSkipped
         in Right
              ( r
                  { rcRcv = Just rr {rcCKr = rcCKr'},
                    rcNr = rcNr'
                  },
                mkSkipped'
              )
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
                  let mks' = M.delete msgNs mks
                      mksSkipped
                        | M.null mks' = M.delete hk rcMKSkipped
                        | otherwise = M.insert hk mks' rcMKSkipped
                  msg <- decryptMessage mk encMsg
                  pure $ SMMessage (msg, rc, mksSkipped)
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
      -- DECRYPT(mk, ciphertext, CONCAT(AD, enc_header))
      -- TODO add associated data
      tryE $ decryptAEAD mk iv (rcAD <> emHeader) emBody emAuthTag

initKdf :: (AlgorithmI a, DhAlgorithm a) => ByteString -> PublicKey a -> PrivateKey a -> (RatchetKey, Key, Key)
initKdf salt k pk =
  let dhOut = dhSecretBytes' $ dh' k pk
      (sk, hk, nhk) = hkdf3 salt dhOut "SimpleXInitRatchet"
   in (RatchetKey sk, Key hk, Key nhk)

rootKdf :: (AlgorithmI a, DhAlgorithm a) => RatchetKey -> PublicKey a -> PrivateKey a -> (RatchetKey, RatchetKey, Key)
rootKdf (RatchetKey rk) k pk =
  let dhOut = dhSecretBytes' $ dh' k pk
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
