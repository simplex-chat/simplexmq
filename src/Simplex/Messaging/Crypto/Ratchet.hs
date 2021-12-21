{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Simplex.Messaging.Crypto.Ratchet where

import Crypto.Hash (SHA512)
import qualified Crypto.KDF.HKDF as H
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import Data.Int (Int64)
import Simplex.Messaging.Crypto

data RatchetState a = RatchetState
  { rcDHs :: KeyPair a,
    rcDHr :: Maybe (PublicKey a), -- initialized as Nothing for the party receiving the first message
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
    ARatchetState (SAlgorithm a) (PublicKey a)

-- | Input key material for double ratchet HKDF functions
newtype RatchetKey = RatchetKey ByteString

-- | Sending ratchet initialization, equivalent to RatchetInitAliceHE in double ratchet doc
initSndRatchet' :: (AlgorithmI a, DhAlgorithm a) => PublicKey a -> PrivateKey a -> ByteString -> IO (RatchetState a)
initSndRatchet' rcvPubKey sndPrivKey salt = do
  pure RatchetState {}
  where
    shared = dh' rcvPubKey sndPrivKey
    (sk, hkSnd, nhkRcv) = initHkdf salt shared

initHkdf :: AlgorithmI a => ByteString -> DhSecret a -> (ByteString, Key, Key)
initHkdf salt shared =
  let out = hkdf salt (dhSecretBytes shared) "InitSimpleXRatchet" 96
      (sk, rest) = B.splitAt 32 out
      (hk, nhk) = B.splitAt 32 rest
   in (sk, Key hk, Key nhk)

hkdf :: ByteString -> ByteString -> ByteString -> Int -> ByteString
hkdf salt ikm info len =
  let prk = H.extract salt ikm :: H.PRK SHA512
   in H.expand prk info len

-- From
-- def RatchetInitAliceHE(state, SK, bob_dh_public_key, shared_hka, shared_nhkb):
--     state.DHRs = GENERATE_DH()
--     state.DHRr = bob_dh_public_key
--     state.RK, state.CKs, state.NHKs = KDF_RK_HE(SK, DH(state.DHRs, state.DHRr))
--     state.CKr = None
--     state.Ns = 0
--     state.Nr = 0
--     state.PN = 0
--     state.MKSKIPPED = {}
--     state.HKs = shared_hka
--     state.HKr = None
--     state.NHKr = shared_nhkb
