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
import qualified Crypto.Cipher.Types as AES
import Crypto.Hash (SHA512)
import qualified Crypto.KDF.HKDF as H
import Data.Attoparsec.ByteString.Char8 (Parser)
import qualified Data.Attoparsec.ByteString.Char8 as A
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import Data.Maybe (fromMaybe)
import Data.Word (Word16, Word32)
import Network.Transport.Internal (decodeWord16, decodeWord32, encodeWord16, encodeWord32)
import Simplex.Messaging.Crypto
import Simplex.Messaging.Parsers (parseAll, parseE, parseE')
import Simplex.Messaging.Util (tryE, (<$?>))

data Ratchet a = Ratchet
  { -- current ratchet version
    rcVersion :: E2EEncryptionVersion,
    -- associated data - must be the same in both parties ratchets
    rcAD :: ByteString,
    rcDHRs :: KeyPair a,
    rcRK :: RatchetKey,
    rcSnd :: Maybe (SndRatchet a),
    rcRcv :: Maybe RcvRatchet,
    rcMKSkipped :: Map HeaderKey SkippedMsgKeys,
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

type SkippedMsgKeys = Map Word32 MessageKey

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
  rcDHRs@(_, pk) <- generateKeyPair' @a 0
  let (sk, rcHKs, rcNHKr) = initKdf salt rcDHRr sPKey
      -- state.RK, state.CKs, state.NHKs = KDF_RK_HE(SK, DH(state.DHRs, state.DHRr))
      (rcRK, rcCKs, rcNHKs) = rootKdf sk rcDHRr pk
  pure
    Ratchet
      { rcVersion = currentE2EVersion,
        rcAD,
        rcDHRs,
        rcRK,
        rcSnd = Just SndRatchet {rcDHRr, rcCKs, rcHKs},
        rcRcv = Nothing,
        rcMKSkipped = M.empty,
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
      { rcVersion = currentE2EVersion,
        rcAD,
        rcDHRs,
        rcRK = sk,
        rcSnd = Nothing,
        rcRcv = Nothing,
        rcMKSkipped = M.empty,
        rcPN = 0,
        rcNs = 0,
        rcNr = 0,
        rcNHKs,
        rcNHKr
      }

data MsgHeader a = MsgHeader
  { -- | current E2E version
    msgVersion :: E2EEncryptionVersion,
    -- | latest E2E version supported by sending clients (to simplify version upgrade)
    msgLatestVersion :: E2EEncryptionVersion,
    msgDHRs :: PublicKey a,
    msgPN :: Word32,
    msgNs :: Word32,
    msgLen :: Word16
  }
  deriving (Eq, Show)

data AMsgHeader
  = forall a.
    (AlgorithmI a, DhAlgorithm a) =>
    AMsgHeader (SAlgorithm a) (MsgHeader a)

paddedHeaderLen :: Int
paddedHeaderLen = 128

fullHeaderLen :: Int
fullHeaderLen = paddedHeaderLen + authTagSize + ivSize @AES256

serializeMsgHeader' :: AlgorithmI a => MsgHeader a -> ByteString
serializeMsgHeader' MsgHeader {msgVersion, msgLatestVersion, msgDHRs, msgPN, msgNs, msgLen} =
  encodeWord16 msgVersion
    <> encodeWord16 msgLatestVersion
    <> encodeWord16 (fromIntegral $ B.length key)
    <> key
    <> encodeWord32 msgPN
    <> encodeWord32 msgNs
    <> encodeWord16 msgLen
  where
    key = encodeKey msgDHRs

msgHeaderP' :: AlgorithmI a => Parser (MsgHeader a)
msgHeaderP' = do
  msgVersion <- word16
  msgLatestVersion <- word16
  keyLen <- fromIntegral <$> word16
  msgDHRs <- parseAll binaryKeyP <$?> A.take keyLen
  msgPN <- word32
  msgNs <- word32
  msgLen <- word16
  pure MsgHeader {msgVersion, msgLatestVersion, msgDHRs, msgPN, msgNs, msgLen}
  where
    word16 = decodeWord16 <$> A.take 2
    word32 = decodeWord32 <$> A.take 4

data EncHeader = EncHeader
  { ehBody :: ByteString,
    ehAuthTag :: AES.AuthTag,
    ehIV :: IV
  }

serializeEncHeader :: EncHeader -> ByteString
serializeEncHeader EncHeader {ehBody, ehAuthTag, ehIV} =
  ehBody <> authTagToBS ehAuthTag <> unIV ehIV

encHeaderP :: Parser EncHeader
encHeaderP = do
  ehBody <- A.take paddedHeaderLen
  ehAuthTag <- bsToAuthTag <$> A.take authTagSize
  ehIV <- ivP
  pure EncHeader {ehBody, ehAuthTag, ehIV}

data EncMessage = EncMessage
  { emHeader :: ByteString,
    emBody :: ByteString,
    emAuthTag :: AES.AuthTag
  }

serializeEncMessage :: EncMessage -> ByteString
serializeEncMessage EncMessage {emHeader, emBody, emAuthTag} =
  emHeader <> emBody <> authTagToBS emAuthTag

encMessageP :: Parser EncMessage
encMessageP = do
  emHeader <- A.take fullHeaderLen
  s <- A.takeByteString
  when (B.length s <= authTagSize) $ fail "message too short"
  let (emBody, aTag) = B.splitAt (B.length s - authTagSize) s
      emAuthTag = bsToAuthTag aTag
  pure EncMessage {emHeader, emBody, emAuthTag}

rcEncrypt' :: AlgorithmI a => Ratchet a -> Int -> ByteString -> ExceptT CryptoError IO (ByteString, Ratchet a)
rcEncrypt' Ratchet {rcSnd = Nothing} _ _ = throwE CERatchetState
rcEncrypt' rc@Ratchet {rcSnd = Just sr@SndRatchet {rcCKs, rcHKs}, rcNs, rcAD} paddedMsgLen msg = do
  -- state.CKs, mk = KDF_CK(state.CKs)
  let (ck', mk, iv, ehIV) = chainKdf rcCKs
  -- enc_header = HENCRYPT(state.HKs, header)
  (ehAuthTag, ehBody) <- encryptAEAD rcHKs ehIV paddedHeaderLen rcAD msgHeader
  -- return enc_header, ENCRYPT(mk, plaintext, CONCAT(AD, enc_header))
  let emHeader = serializeEncHeader EncHeader {ehBody, ehAuthTag, ehIV}
  (emAuthTag, emBody) <- encryptAEAD mk iv paddedMsgLen (rcAD <> emHeader) msg
  let msg' = serializeEncMessage EncMessage {emHeader, emBody, emAuthTag}
      -- state.Ns += 1
      rc' = rc {rcSnd = Just sr {rcCKs = ck'}, rcNs = rcNs + 1}
  pure (msg', rc')
  where
    -- header = HEADER(state.DHRs, state.PN, state.Ns)
    msgHeader =
      serializeMsgHeader'
        MsgHeader
          { msgVersion = rcVersion rc,
            msgLatestVersion = currentE2EVersion,
            msgDHRs = fst $ rcDHRs rc,
            msgPN = rcPN rc,
            msgNs = rcNs,
            msgLen = fromIntegral $ B.length msg
          }

data SkippedMessage a
  = SMMessage (Either CryptoError ByteString) (Ratchet a)
  | SMHeader (Maybe RatchetStep) (MsgHeader a)
  | SMNone

data RatchetStep = AdvanceRatchet | SameRatchet
  deriving (Eq)

type DecryptResult a = (Either CryptoError ByteString, Ratchet a)

maxSkip :: Word32
maxSkip = 512

rcDecrypt' ::
  forall a.
  (AlgorithmI a, DhAlgorithm a) =>
  Ratchet a ->
  ByteString ->
  ExceptT CryptoError IO (DecryptResult a)
rcDecrypt' rc@Ratchet {rcRcv, rcMKSkipped, rcAD} msg' = do
  encMsg@EncMessage {emHeader} <- parseE CryptoHeaderError encMessageP msg'
  encHdr <- parseE CryptoHeaderError encHeaderP emHeader
  -- plaintext = TrySkippedMessageKeysHE(state, enc_header, ciphertext, AD)
  decryptSkipped encHdr encMsg >>= \case
    SMNone -> do
      (rcStep, hdr) <- decryptRcHeader rcRcv encHdr
      decryptRcMessage rcStep hdr encMsg
    SMHeader rcStep_ hdr ->
      case rcStep_ of
        Just rcStep -> decryptRcMessage rcStep hdr encMsg
        Nothing -> throwE CERatchetHeader
    SMMessage msg rc' -> pure (msg, rc')
  where
    decryptRcMessage :: RatchetStep -> MsgHeader a -> EncMessage -> ExceptT CryptoError IO (DecryptResult a)
    decryptRcMessage rcStep hdr@MsgHeader {msgDHRs, msgPN, msgNs} encMsg = do
      -- if dh_ratchet:
      rc' <- ratchetStep rcStep
      case skipMessageKeys msgNs rc' of
        Left e -> pure (Left e, rc')
        Right rc''@Ratchet {rcRcv = Just rr@RcvRatchet {rcCKr}, rcNr} -> do
          -- state.CKr, mk = KDF_CK(state.CKr)
          let (rcCKr', mk, iv, _) = chainKdf rcCKr
          -- return DECRYPT (mk, ciphertext, CONCAT (AD, enc_header))
          msg <- decryptMessage (MessageKey mk iv) hdr encMsg
          -- state . Nr += 1
          pure (msg, rc'' {rcRcv = Just rr {rcCKr = rcCKr'}, rcNr = rcNr + 1})
        Right rc'' -> pure (Left CERatchetState, rc'')
      where
        ratchetStep :: RatchetStep -> ExceptT CryptoError IO (Ratchet a)
        ratchetStep SameRatchet = pure rc
        ratchetStep AdvanceRatchet =
          -- SkipMessageKeysHE(state, header.pn)
          case skipMessageKeys msgPN rc of
            Left e -> throwE e
            Right rc'@Ratchet {rcDHRs, rcRK, rcNHKs, rcNHKr} -> do
              -- DHRatchetHE(state, header)
              rcDHRs' <- liftIO $ generateKeyPair' @a 0
              -- state.RK, state.CKr, state.NHKr = KDF_RK_HE(state.RK, DH(state.DHRs, state.DHRr))
              let (rcRK', rcCKr', rcNHKr') = rootKdf rcRK msgDHRs (snd rcDHRs)
                  -- state.RK, state.CKs, state.NHKs = KDF_RK_HE(state.RK, DH(state.DHRs, state.DHRr))
                  (rcRK'', rcCKs', rcNHKs') = rootKdf rcRK' msgDHRs (snd rcDHRs')
              pure
                rc'
                  { rcDHRs = rcDHRs',
                    rcRK = rcRK'',
                    rcSnd = Just SndRatchet {rcDHRr = msgDHRs, rcCKs = rcCKs', rcHKs = rcNHKs},
                    rcRcv = Just RcvRatchet {rcCKr = rcCKr', rcHKr = rcNHKr},
                    rcPN = rcNs rc,
                    rcNs = 0,
                    rcNr = 0,
                    rcNHKs = rcNHKs',
                    rcNHKr = rcNHKr'
                  }
    skipMessageKeys :: Word32 -> Ratchet a -> Either CryptoError (Ratchet a)
    skipMessageKeys _ r@Ratchet {rcRcv = Nothing} = Right r
    skipMessageKeys untilN r@Ratchet {rcRcv = Just rr@RcvRatchet {rcCKr, rcHKr}, rcNr, rcMKSkipped = mkSkipped}
      | rcNr > untilN = Left CERatchetDuplicateMessage
      | rcNr + maxSkip < untilN = Left CERatchetTooManySkipped
      | rcNr == untilN = Right r
      | otherwise =
        let mks = fromMaybe M.empty $ M.lookup rcHKr mkSkipped
            (rcCKr', rcNr', mks') = advanceRcvRatchet (untilN - rcNr) rcCKr rcNr mks
         in Right
              r
                { rcRcv = Just rr {rcCKr = rcCKr'},
                  rcNr = rcNr',
                  rcMKSkipped = M.insert rcHKr mks' mkSkipped
                }
    advanceRcvRatchet :: Word32 -> RatchetKey -> Word32 -> SkippedMsgKeys -> (RatchetKey, Word32, SkippedMsgKeys)
    advanceRcvRatchet 0 ck msgNs mks = (ck, msgNs, mks)
    advanceRcvRatchet n ck msgNs mks =
      let (ck', mk, iv, _) = chainKdf ck
          mks' = M.insert msgNs (MessageKey mk iv) mks
       in advanceRcvRatchet (n - 1) ck' (msgNs + 1) mks'
    decryptSkipped :: EncHeader -> EncMessage -> ExceptT CryptoError IO (SkippedMessage a)
    decryptSkipped encHdr encMsg = tryDecryptSkipped SMNone $ M.assocs rcMKSkipped
      where
        tryDecryptSkipped :: SkippedMessage a -> [(HeaderKey, SkippedMsgKeys)] -> ExceptT CryptoError IO (SkippedMessage a)
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
                      rc' = rc {rcMKSkipped = mksSkipped}
                  msg <- decryptMessage mk hdr encMsg
                  pure $ SMMessage msg rc'
        tryDecryptSkipped r _ = pure r
    decryptRcHeader :: Maybe RcvRatchet -> EncHeader -> ExceptT CryptoError IO (RatchetStep, MsgHeader a)
    decryptRcHeader Nothing hdr = decryptNextHeader hdr
    decryptRcHeader (Just RcvRatchet {rcHKr}) hdr =
      -- header = HDECRYPT(state.HKr, enc_header)
      ((SameRatchet,) <$> decryptHeader rcHKr hdr) `catchE` \case
        CERatchetHeader -> decryptNextHeader hdr
        e -> throwE e
    -- header = HDECRYPT(state.NHKr, enc_header)
    decryptNextHeader hdr = (AdvanceRatchet,) <$> decryptHeader (rcNHKr rc) hdr
    decryptHeader k EncHeader {ehBody, ehAuthTag, ehIV} = do
      header <- decryptAEAD k ehIV rcAD ehBody ehAuthTag `catchE` \_ -> throwE CERatchetHeader
      parseE' CryptoHeaderError msgHeaderP' header
    decryptMessage :: MessageKey -> MsgHeader a -> EncMessage -> ExceptT CryptoError IO (Either CryptoError ByteString)
    decryptMessage (MessageKey mk iv) MsgHeader {msgLen} EncMessage {emHeader, emBody, emAuthTag} =
      -- DECRYPT(mk, ciphertext, CONCAT(AD, enc_header))
      -- TODO add associated data
      tryE (B.take (fromIntegral msgLen) <$> decryptAEAD mk iv (rcAD <> emHeader) emBody emAuthTag)

initKdf :: (AlgorithmI a, DhAlgorithm a) => ByteString -> PublicKey a -> PrivateKey a -> (RatchetKey, Key, Key)
initKdf salt k pk =
  let dhOut = dhSecretBytes $ dh' k pk
      (sk, hk, nhk) = hkdf3 salt dhOut "SimpleXInitRatchet"
   in (RatchetKey sk, Key hk, Key nhk)

rootKdf :: (AlgorithmI a, DhAlgorithm a) => RatchetKey -> PublicKey a -> PrivateKey a -> (RatchetKey, RatchetKey, Key)
rootKdf (RatchetKey rk) k pk =
  let dhOut = dhSecretBytes $ dh' k pk
      (rk', ck, nhk) = hkdf3 rk dhOut "SimpleXRootRatchet"
   in (RatchetKey rk', RatchetKey ck, Key nhk)

-- TODO revise using HKDF instead of HMAC as the chain key KDF (KDF_CK), https://signal.org/docs/specifications/doubleratchet/#recommended-cryptographic-algorithms
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
