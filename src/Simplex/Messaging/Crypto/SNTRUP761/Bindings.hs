{-# LANGUAGE ForeignFunctionInterface #-}

module Simplex.Messaging.Crypto.SNTRUP761.Bindings (
  sntrup761_keypair,
  sntrup761_enc,
  sntrup761_dec,
  module Simplex.Messaging.Crypto.SNTRUP761.Bindings.Types
) where

import Data.Void
import Foreign
import Foreign.C
import Simplex.Messaging.Crypto.SNTRUP761.Bindings.Types

type RandomCtx = Void

-- typedef void sntrup761_random_func (void *ctx, size_t length, uint8_t *dst);
type RandomFunc = Ptr RandomCtx -> CSize -> Ptr Word8 -> IO ()

-- void sntrup761_keypair (uint8_t *pk, uint8_t *sk, void *random_ctx, sntrup761_random_func *random);
foreign import ccall "sntrup761_keypair"
  sntrup761_keypair :: Ptr Word8 -> Ptr Word8 -> Ptr RandomCtx -> Ptr RandomFunc -> IO ()

-- void sntrup761_enc (uint8_t *c, uint8_t *k, const uint8_t *pk, void *random_ctx, sntrup761_random_func *random);
foreign import ccall "sntrup761_enc"
  sntrup761_enc :: Ptr Word8 -> Ptr Word8 -> Ptr Word8 -> Ptr RandomCtx -> Ptr RandomFunc -> IO ()

-- void sntrup761_dec (uint8_t *k, const uint8_t *c, const uint8_t *sk);
foreign import ccall "sntrup761_dec"
  sntrup761_dec :: Ptr Word8 -> Ptr Word8 -> Ptr Word8 -> IO ()
