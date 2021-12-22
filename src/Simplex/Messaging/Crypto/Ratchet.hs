{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

module Simplex.Messaging.Crypto.Ratchet where

import Control.Monad.Except
import Control.Monad.Trans.Except
import qualified Crypto.Cipher.Types as AES
import Crypto.Hash (SHA512)
import qualified Crypto.KDF.HKDF as H
import Crypto.Random (getRandomBytes)
import Data.Attoparsec.ByteString.Char8 (Parser)
import qualified Data.Attoparsec.ByteString.Char8 as A
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.Type.Equality
import Data.Word (Word16)
import Network.Transport.Internal (decodeWord16, encodeWord16)
import Simplex.Messaging.Crypto
import Simplex.Messaging.Parsers (parseAll)
import Simplex.Messaging.Util ((<$?>))

data RatchetState a = RatchetState
  { rcVersion :: E2EEncryptionVersion,
    rcDHRs :: KeyPair a,
    rcDHRr :: Maybe (PublicKey a), -- initialized as Nothing for the party receiving the first message
    rcRK :: RatchetKey,
    rcCKs :: Maybe RatchetKey, -- initialized as Nothing for the party receiving the first message
    rcCKr :: Maybe RatchetKey, -- initialized as Nothing for both
    rcNs :: Word16,
    rcNr :: Word16,
    rcPN :: Word16,
    rcHKs :: Maybe Key, -- initialized as Nothing for the party receiving the first message
    rcHKr :: Maybe Key, -- initialized as Nothing for both
    rcNHKs :: Key,
    rcNHKr :: Key
  }

data ARatchetState
  = forall a.
    (AlgorithmI a, DhAlgorithm a) =>
    ARatchetState (SAlgorithm a) (RatchetState a)

-- | Input key material for double ratchet HKDF functions
newtype RatchetKey = RatchetKey ByteString

-- | Sending ratchet initialization, equivalent to RatchetInitAliceHE in double ratchet spec
--
-- Please note that sndPrivKey is not stored, and its public part together with random salt
-- is sent to the recipient.
initSndRatchet' ::
  forall a. (AlgorithmI a, DhAlgorithm a) => PublicKey a -> PrivateKey a -> ByteString -> IO (RatchetState a)
initSndRatchet' rKey sPKey salt = do
  rcDHRs@(_, pk) <- generateKeyPair' @a 0
  let (sk, rcHKs', rcNHKr) = initKdf salt rKey sPKey
      (rcRK, rcCKs', rcNHKs) = rootKdf sk rKey pk
  pure
    RatchetState
      { rcVersion = currentE2EVersion,
        rcDHRs,
        rcDHRr = Just rKey,
        rcRK,
        rcCKs = Just rcCKs',
        rcCKr = Nothing,
        rcNs = 0,
        rcNr = 0,
        rcPN = 0,
        rcHKs = Just rcHKs',
        rcHKr = Nothing,
        rcNHKs,
        rcNHKr
      }

-- | Receiving ratchet initialization, equivalent to RatchetInitBobHE in double ratchet spec
--
-- Please note that the public part of rcDHRs was sent to the sender
-- as part of the connection request and random salt was received from the sender.
initRcvRatchet' ::
  forall a. (AlgorithmI a, DhAlgorithm a) => PublicKey a -> KeyPair a -> ByteString -> IO (RatchetState a)
initRcvRatchet' sKey rcDHRs@(_, pk) salt = do
  let (sk, rcNHKr, rcNHKs) = initKdf salt sKey pk
  pure
    RatchetState
      { rcVersion = currentE2EVersion,
        rcDHRs,
        rcDHRr = Nothing,
        rcRK = sk,
        rcCKs = Nothing,
        rcCKr = Nothing,
        rcNs = 0,
        rcNr = 0,
        rcPN = 0,
        rcHKs = Nothing,
        rcHKr = Nothing,
        rcNHKs,
        rcNHKr
      }

data MsgHeader a = MsgHeader
  { msgVersion :: E2EEncryptionVersion,
    msgLatestVersion :: E2EEncryptionVersion,
    msgDHR :: PublicKey a,
    msgPN :: Word16,
    msgN :: Word16,
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

serializeMsgHeader' :: AlgorithmI a => MsgHeader a -> ByteString
serializeMsgHeader' MsgHeader {msgVersion, msgLatestVersion, msgDHR, msgPN, msgN, msgRndId, msgIV, msgLen} =
  encodeWord16 msgVersion
    <> encodeWord16 msgLatestVersion
    <> encodeWord16 (fromIntegral $ B.length key)
    <> key
    <> encodeWord16 msgPN
    <> encodeWord16 msgN
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
  msgPN <- word16
  msgN <- word16
  msgRndId <- A.take 16
  msgIV <- ivP
  msgLen <- word16
  pure MsgHeader {msgVersion, msgLatestVersion, msgDHR, msgPN, msgN, msgRndId, msgIV, msgLen}
  where
    word16 = decodeWord16 <$> A.take 2

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
  ehBody <- A.take 64 -- TBC
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
  emHeader <- A.take 64 -- TBC
  s <- A.takeByteString
  let (emBody, aTag) = B.splitAt (B.length s - authTagSize) s
      emAuthTag = bsToAuthTag aTag
  pure EncMessage {emHeader, emBody, emAuthTag}

rcEncrypt' :: AlgorithmI a => RatchetState a -> Int -> ByteString -> ExceptT CryptoError IO (ByteString, RatchetState a)
rcEncrypt' rc@RatchetState {rcCKs = Just ck, rcHKs = Just hk} paddedMsgLen msg = do
  msgRndId <- liftIO $ getRandomBytes 16
  let (ck', mk, msgIV, ehIV) = chainKdf ck msgRndId
      header = serializeMsgHeader' $ mkMsgHeader msgRndId msgIV
  (ehAuthTag, ehBody) <- encryptAES hk ehIV paddedHeaderLen header
  (emAuthTag, emBody) <- encryptAES mk msgIV paddedMsgLen msg
  let emHeader = serializeEncHeader EncHeader {ehBody, ehAuthTag, ehIV}
      msg' = serializeEncMessage EncMessage {emHeader, emBody, emAuthTag}
      rc' = rc {rcCKs = Just ck', rcNs = rcNs rc + 1}
  pure (msg', rc')
  where
    mkMsgHeader msgRndId msgIV =
      MsgHeader
        { msgVersion = rcVersion rc,
          msgLatestVersion = currentE2EVersion,
          msgDHR = fst $ rcDHRs rc,
          msgPN = rcPN rc,
          msgN = rcNs rc,
          msgRndId,
          msgIV,
          msgLen = fromIntegral $ B.length msg
        }
rcEncrypt' RatchetState {rcCKs = _, rcHKs = _} _ _ = throwE CryptoRatchetNoCKs

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
