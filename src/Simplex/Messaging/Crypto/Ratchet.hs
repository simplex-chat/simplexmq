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
import Crypto.Random (getRandomBytes)
import Data.Attoparsec.ByteString.Char8 (Parser)
import qualified Data.Attoparsec.ByteString.Char8 as A
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import Data.Word (Word16, Word32)
import Network.Transport.Internal (decodeWord16, decodeWord32, encodeWord16, encodeWord32)
import Simplex.Messaging.Crypto
import Simplex.Messaging.Parsers (parseAll, parseE)
import Simplex.Messaging.Util (tryE, (<$?>))

data Ratchet a = Ratchet
  { rcVersion :: E2EEncryptionVersion,
    rcDHRs :: KeyPair a,
    rcRK :: RatchetKey,
    rcSnd :: Maybe (SndRatchet a),
    rcRcv :: Maybe RcvRatchet,
    rcMKSkipped :: Map HeaderKey SkippedMsgKeys,
    rcPN :: Word32,
    rcNHKs :: Key,
    rcNHKr :: Key
  }

data SndRatchet a = SndRatchet
  { rcDHRr :: PublicKey a,
    rcCKs :: RatchetKey,
    rcHKs :: Key,
    rcNs :: Word32
  }

data RcvRatchet = RcvRatchet
  { rcCKr :: RatchetKey,
    rcHKr :: Key,
    rcNr :: Word32
  }

type SkippedMsgKeys = Map Word32 MessageKey

type HeaderKey = Key

type MessageKey = Key

data ARatchet
  = forall a.
    (AlgorithmI a, DhAlgorithm a) =>
    ARatchet (SAlgorithm a) (Ratchet a)

-- | Input key material for double ratchet HKDF functions
newtype RatchetKey = RatchetKey ByteString

-- | Sending ratchet initialization, equivalent to RatchetInitAliceHE in double ratchet spec
--
-- Please note that sndPrivKey is not stored, and its public part together with random salt
-- is sent to the recipient.
initSndRatchet' ::
  forall a. (AlgorithmI a, DhAlgorithm a) => PublicKey a -> PrivateKey a -> ByteString -> IO (Ratchet a)
initSndRatchet' rKey sPKey salt = do
  rcDHRs@(_, pk) <- generateKeyPair' @a 0
  let (sk, rcHKs, rcNHKr) = initKdf salt rKey sPKey
      (rcRK, rcCKs, rcNHKs) = rootKdf sk rKey pk
  pure
    Ratchet
      { rcVersion = currentE2EVersion,
        rcDHRs,
        rcRK,
        rcSnd = Just SndRatchet {rcDHRr = rKey, rcCKs, rcHKs, rcNs = 0},
        rcRcv = Nothing,
        rcMKSkipped = M.empty,
        rcPN = 0,
        rcNHKs,
        rcNHKr
      }

-- | Receiving ratchet initialization, equivalent to RatchetInitBobHE in double ratchet spec
--
-- Please note that the public part of rcDHRs was sent to the sender
-- as part of the connection request and random salt was received from the sender.
initRcvRatchet' ::
  forall a. (AlgorithmI a, DhAlgorithm a) => PublicKey a -> KeyPair a -> ByteString -> IO (Ratchet a)
initRcvRatchet' sKey rcDHRs@(_, pk) salt = do
  let (sk, rcNHKr, rcNHKs) = initKdf salt sKey pk
  pure
    Ratchet
      { rcVersion = currentE2EVersion,
        rcDHRs,
        rcRK = sk,
        rcSnd = Nothing,
        rcRcv = Nothing,
        rcMKSkipped = M.empty,
        rcPN = 0,
        rcNHKs,
        rcNHKr
      }

data MsgHeader a = MsgHeader
  { msgVersion :: E2EEncryptionVersion,
    msgLatestVersion :: E2EEncryptionVersion,
    msgDHR :: PublicKey a,
    msgPN :: Word32,
    msgN :: Word32,
    msgRndId :: ByteString,
    msgIV :: IV,
    msgLen :: Word16
  }

data AMsgHeader
  = forall a.
    (AlgorithmI a, DhAlgorithm a) =>
    AMsgHeader (SAlgorithm a) (MsgHeader a)

paddedHeaderLen :: Int
paddedHeaderLen = 128

fullHeaderLen :: Int
fullHeaderLen = paddedHeaderLen + authTagSize + ivSize @AES256

serializeMsgHeader' :: AlgorithmI a => MsgHeader a -> ByteString
serializeMsgHeader' MsgHeader {msgVersion, msgLatestVersion, msgDHR, msgPN, msgN, msgRndId, msgIV, msgLen} =
  encodeWord16 msgVersion
    <> encodeWord16 msgLatestVersion
    <> encodeWord16 (fromIntegral $ B.length key)
    <> key
    <> encodeWord32 msgPN
    <> encodeWord32 msgN
    <> msgRndId
    <> unIV msgIV
    <> encodeWord16 msgLen
  where
    key = encodeKey msgDHR

msgHeaderP' :: AlgorithmI a => Parser (MsgHeader a)
msgHeaderP' = do
  msgVersion <- word16
  msgLatestVersion <- word16
  keyLen <- fromIntegral <$> word16
  msgDHR <- parseAll binaryKeyP <$?> A.take keyLen
  msgPN <- word32
  msgN <- word32
  msgRndId <- A.take 16
  msgIV <- ivP
  msgLen <- word16
  pure MsgHeader {msgVersion, msgLatestVersion, msgDHR, msgPN, msgN, msgRndId, msgIV, msgLen}
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
rcEncrypt' rc@Ratchet {rcSnd = Just sr@SndRatchet {rcCKs, rcHKs, rcNs}} paddedMsgLen msg = do
  msgRndId <- liftIO $ getRandomBytes 16
  let (ck', mk, msgIV, ehIV) = chainKdf rcCKs msgRndId
      header = serializeMsgHeader' $ mkMsgHeader msgRndId msgIV
  (ehAuthTag, ehBody) <- encryptAES rcHKs ehIV paddedHeaderLen header
  (emAuthTag, emBody) <- encryptAES mk msgIV paddedMsgLen msg
  let emHeader = serializeEncHeader EncHeader {ehBody, ehAuthTag, ehIV}
      msg' = serializeEncMessage EncMessage {emHeader, emBody, emAuthTag}
      rc' = rc {rcSnd = Just sr {rcCKs = ck', rcNs = rcNs + 1}}
  pure (msg', rc')
  where
    mkMsgHeader msgRndId msgIV =
      MsgHeader
        { msgVersion = rcVersion rc,
          msgLatestVersion = currentE2EVersion,
          msgDHR = fst $ rcDHRs rc,
          msgPN = rcPN rc,
          msgN = rcNs,
          msgRndId,
          msgIV,
          msgLen = fromIntegral $ B.length msg
        }

data SkippedMessage a
  = SMMessage (Either CryptoError ByteString) (Ratchet a)
  | SMHeader (Maybe RatchetStep) (MsgHeader a)
  | SMNone

data RatchetStep = AdvanceRatchet | SameRatchet
  deriving (Eq)

rcDecrypt' :: forall a. AlgorithmI a => Ratchet a -> ByteString -> ExceptT CryptoError IO (Either CryptoError ByteString, Ratchet a)
rcDecrypt' rc@Ratchet {rcRcv, rcNHKr, rcMKSkipped} msg' = do
  encMsg@EncMessage {emHeader} <- parseE CryptoHeaderError encMessageP msg'
  encHdr <- parseE CryptoHeaderError encHeaderP emHeader
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
    decryptRcMessage :: RatchetStep -> MsgHeader a -> EncMessage -> ExceptT CryptoError IO (Either CryptoError ByteString, Ratchet a)
    decryptRcMessage rcStep MsgHeader {} encMsg = do
      rc' <- ratchetStep rcStep
      pure (Right "", rc')
    ratchetStep AdvanceRatchet = pure rc
    ratchetStep SameRatchet = pure rc
    decryptSkipped :: EncHeader -> EncMessage -> ExceptT CryptoError IO (SkippedMessage a)
    decryptSkipped encHdr encMsg = tryDecryptSkipped SMNone $ M.assocs rcMKSkipped
      where
        tryDecryptSkipped :: SkippedMessage a -> [(HeaderKey, SkippedMsgKeys)] -> ExceptT CryptoError IO (SkippedMessage a)
        tryDecryptSkipped SMNone ((hk, mks) : hks) = do
          tryE (decryptHeader hk encHdr) >>= \case
            Left CERatchetHeader -> tryDecryptSkipped SMNone hks
            Left e -> throwE e
            Right hdr@MsgHeader {msgN} ->
              case M.lookup msgN mks of
                Nothing ->
                  let nextRc
                        | Just hk == (rcHKr <$> rcRcv) = Just SameRatchet
                        | hk == rcNHKr = Just AdvanceRatchet
                        | otherwise = Nothing
                   in pure $ SMHeader nextRc hdr
                Just mk -> do
                  let mks' = M.delete msgN mks
                      mksSkipped
                        | M.null mks' = M.delete hk rcMKSkipped
                        | otherwise = M.insert hk mks' rcMKSkipped
                      rc' = rc {rcMKSkipped = mksSkipped}
                  msg <- liftIO $ decryptMessage mk hdr encMsg
                  pure $ SMMessage msg rc'
        tryDecryptSkipped r _ = pure r
    decryptRcHeader :: Maybe RcvRatchet -> EncHeader -> ExceptT CryptoError IO (RatchetStep, MsgHeader a)
    decryptRcHeader Nothing h = decryptNextHeader h
    decryptRcHeader (Just RcvRatchet {rcHKr}) h =
      ((SameRatchet,) <$> decryptHeader rcHKr h) `catchE` \case
        CERatchetHeader -> decryptNextHeader h
        e -> throwE e
    decryptNextHeader h = (AdvanceRatchet,) <$> decryptHeader rcNHKr h
    decryptHeader k EncHeader {ehBody, ehAuthTag, ehIV} = do
      header <- decryptAES k ehIV ehBody ehAuthTag `catchE` \_ -> throwE CERatchetHeader
      parseE CryptoHeaderError msgHeaderP' header
    decryptMessage :: Key -> MsgHeader a -> EncMessage -> IO (Either CryptoError ByteString)
    decryptMessage mk MsgHeader {} encMsg = pure $ Right ""

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

chainKdf :: RatchetKey -> ByteString -> (RatchetKey, Key, IV, IV)
chainKdf (RatchetKey ck) msgRandomId =
  let (ck', mk, ivs) = hkdf3 ck msgRandomId "SimpleXChainRatchet"
      (iv1, iv2) = B.splitAt 16 ivs
   in (RatchetKey ck', Key mk, IV iv1, IV iv2)

hkdf3 :: ByteString -> ByteString -> ByteString -> (ByteString, ByteString, ByteString)
hkdf3 salt ikm info = (s1, s2, s3)
  where
    prk = H.extract salt ikm :: H.PRK SHA512
    out = H.expand prk info 96
    (s1, rest) = B.splitAt 32 out
    (s2, s3) = B.splitAt 32 rest
