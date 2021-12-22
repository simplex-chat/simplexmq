{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

module Simplex.Messaging.Crypto.Ratchet where

import Crypto.Hash (SHA512)
import qualified Crypto.KDF.HKDF as H
import Crypto.Random (getRandomBytes)
import Data.Attoparsec.ByteString.Char8 (Parser)
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.Int (Int64)
import Data.Type.Equality
import Simplex.Messaging.Crypto
import Simplex.Messaging.Util ((<$?>))

data RatchetState a = RatchetState
  { rcDHRs :: KeyPair a,
    rcDHRr :: Maybe (PublicKey a), -- initialized as Nothing for the party receiving the first message
    rcRK :: RatchetKey,
    rcCKs :: Maybe RatchetKey, -- initialized as Nothing for the party receiving the first message
    rcCKr :: Maybe RatchetKey, -- initialized as Nothing for both
    rcNs :: Int64,
    rcNr :: Int64,
    rcPN :: Int64,
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
      { rcDHRs,
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
      { rcDHRs,
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
  { msgDHRs :: PublicKey a,
    rcPN :: Int64,
    rcNs :: Int64,
    msgRndId :: ByteString,
    msgIV :: IV
  }

data AMsgHeader
  = forall a.
    (AlgorithmI a, DhAlgorithm a) =>
    AMsgHeader (SAlgorithm a) (MsgHeader a)

serializeMsgHeader' :: MsgHeader a -> ByteString
serializeMsgHeader' MsgHeader {} = ""

msgHeaderP' :: AlgorithmI a => Parser (MsgHeader a)
msgHeaderP' = msgHeader' <$?> msgHeaderP

msgHeaderP :: Parser (AMsgHeader)
msgHeaderP = fail "not implemented"

msgHeader' :: forall a. AlgorithmI a => AMsgHeader -> Either String (MsgHeader a)
msgHeader' (AMsgHeader a h) = case testEquality a $ sAlgorithm @a of
  Just Refl -> Right h
  _ -> Left "bad key algorithm"

rcEncrypt' :: RatchetState a -> ByteString -> IO (ByteString)
rcEncrypt' RatchetState {rcCKs = Nothing} _ = pure ""
rcEncrypt' RatchetState {rcCKs = Just ck, rcDHRs = (msgDHRs, _), rcPN, rcNs} msg = do
  msgRndId <- getRandomBytes 16
  let (ck', mk, msgIV) = chainKdf ck msgRndId
      header = MsgHeader {msgDHRs, rcPN, rcNs, msgRndId, msgIV}
  pure ""

initKdf :: (AlgorithmI a, DhAlgorithm a) => ByteString -> PublicKey a -> PrivateKey a -> (RatchetKey, Key, Key)
initKdf salt k pk =
  let dhOut = dhSecretBytes $ dh' k pk
      (sk, hk, nhk) = split3 $ hkdf salt dhOut "SimpleXInitRatchet" 96
   in (RatchetKey sk, Key hk, Key nhk)

rootKdf :: (AlgorithmI a, DhAlgorithm a) => RatchetKey -> PublicKey a -> PrivateKey a -> (RatchetKey, RatchetKey, Key)
rootKdf (RatchetKey rk) k pk =
  let dhOut = dhSecretBytes $ dh' k pk
      (rk', ck, nhk) = split3 $ hkdf rk dhOut "SimpleXRootRatchet" 96
   in (RatchetKey rk', RatchetKey ck, Key nhk)

chainKdf :: RatchetKey -> ByteString -> (RatchetKey, Key, IV)
chainKdf (RatchetKey ck) msgRandomId =
  let (ck', mk, iv) = split3 $ hkdf ck msgRandomId "SimpleXChainRatchet" 80
   in (RatchetKey ck', Key mk, IV iv)

hkdf :: ByteString -> ByteString -> ByteString -> Int -> ByteString
hkdf salt ikm info len =
  let prk = H.extract salt ikm :: H.PRK SHA512
   in H.expand prk info len

split3 :: ByteString -> (ByteString, ByteString, ByteString)
split3 s =
  let (s1, rest) = B.splitAt 32 s
      (s2, s3) = B.splitAt 32 rest
   in (s1, s2, s3)
