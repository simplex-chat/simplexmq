{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# OPTIONS_GHC -Wno-unrecognised-pragmas #-}

{-# HLINT ignore "Use camelCase" #-}

module Bench.Crypto where

import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Crypto.NaCl.Bindings
import Test.Tasty.Bench

import Control.Concurrent.STM (TVar)
import Control.Monad.STM (atomically)
import qualified Crypto.Cipher.XSalsa as XSalsa
import qualified Crypto.MAC.Poly1305 as Poly1305
import Crypto.Random (ChaChaDRG)
import qualified Data.ByteArray as BA
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
-- import Test.Tasty (withResource)

benchCrypto :: [Benchmark]
benchCrypto =
  [ bgroup
      "cryptoBox"
      [ env randomChunk $ bench "crypton" . nf cryptoBoxRef,
        env randomChunk $ bcompare "crypton" . bench "tweetnacl" . nf cryptoBoxNaCl
      ]
  ]

randomChunk :: IO (ByteString, ByteString, ByteString)
randomChunk = do
  g <- C.newRandom
  (aPub :: C.PublicKeyX25519, _aPriv :: C.PrivateKeyX25519) <- atomically $ C.generateKeyPair g
  (_bPub :: C.PublicKeyX25519, bPriv :: C.PrivateKeyX25519) <- atomically $ C.generateKeyPair g
  let C.DhSecretX25519 sk = C.dh' aPub bPriv
  -- let baShared = C.dh' bPub aPriv
  C.CbNonce n <- atomically $ C.randomCbNonce g
  msg <- atomically $ C.randomBytes 12345 g
  pure (BA.convert sk, n, msg)

cryptoBoxRef :: (ByteString, ByteString, ByteString) -> ByteString
cryptoBoxRef (k, nonce', msg) = ref_cryptoBox k nonce' msg

cryptoBoxNaCl :: (ByteString, ByteString, ByteString) -> ByteString
cryptoBoxNaCl (k, nonce', msg) = C.cryptoBox k nonce' msg

ref_cryptoBox :: BA.ByteArrayAccess key => key -> ByteString -> ByteString -> ByteString
ref_cryptoBox secret nonce s = BA.convert tag <> c
  where
    (rs, c) = ref_xSalsa20 secret nonce s
    tag = Poly1305.auth rs c

-- | NaCl @crypto_box@ decrypt with a shared DH secret and 192-bit nonce (without unpadding).
ref_sbDecryptNoPad_ :: BA.ByteArrayAccess key => key -> C.CbNonce -> ByteString -> Either C.CryptoError ByteString
ref_sbDecryptNoPad_ secret (C.CbNonce nonce) packet
  | B.length packet < 16 = Left C.CBDecryptError
  | BA.constEq tag' tag = Right msg
  | otherwise = Left C.CBDecryptError
  where
    (tag', c) = B.splitAt 16 packet
    (rs, msg) = ref_xSalsa20 secret nonce c
    tag = Poly1305.auth rs c

ref_xSalsa20 :: BA.ByteArrayAccess key => key -> ByteString -> ByteString -> (ByteString, ByteString)
ref_xSalsa20 secret nonce msg = (rs, msg')
  where
    zero = B.replicate 16 $ toEnum 0
    (iv0, iv1) = B.splitAt 8 nonce
    state0 = XSalsa.initialize 20 secret (zero `B.append` iv0)
    state1 = XSalsa.derive state0 iv1
    (rs, state2) = XSalsa.generate state1 32
    (msg', _) = XSalsa.combine state2 msg
