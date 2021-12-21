{-# LANGUAGE GADTs #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

module Simplex.Messaging.Crypto.Ratchet where

import Crypto.Hash (SHA512)
import qualified Crypto.KDF.HKDF as H
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import Data.Int (Int64)
import Simplex.Messaging.Crypto

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

initKdf :: (AlgorithmI a, DhAlgorithm a) => ByteString -> PublicKey a -> PrivateKey a -> (RatchetKey, Key, Key)
initKdf salt k pk =
  let (sk, hk, nhk) = hkdf3 salt k pk "SimpleXInitRatchet"
   in (RatchetKey sk, Key hk, Key nhk)

rootKdf :: (AlgorithmI a, DhAlgorithm a) => RatchetKey -> PublicKey a -> PrivateKey a -> (RatchetKey, RatchetKey, Key)
rootKdf (RatchetKey rk) k pk =
  let (rk', ck, nhk) = hkdf3 rk k pk "SimpleXRootRatchet"
   in (RatchetKey rk', RatchetKey ck, Key nhk)

hkdf3 :: (AlgorithmI a, DhAlgorithm a) => ByteString -> PublicKey a -> PrivateKey a -> ByteString -> (ByteString, ByteString, ByteString)
hkdf3 salt k pk info =
  split3 $ hkdf salt (dhSecretBytes $ dh' k pk) info 96

hkdf :: ByteString -> ByteString -> ByteString -> Int -> ByteString
hkdf salt ikm info len =
  let prk = H.extract salt ikm :: H.PRK SHA512
   in H.expand prk info len

split3 :: ByteString -> (ByteString, ByteString, ByteString)
split3 s =
  let (s1, rest) = B.splitAt 32 s
      (s2, s3) = B.splitAt 32 rest
   in (s1, s2, s3)
