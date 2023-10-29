{-# LANGUAGE ForeignFunctionInterface #-}

module Simplex.Messaging.Crypto.SNTRUP761.Bindings.FFI (
  sntrup761_keypair,
  sntrup761_enc,
  sntrup761_dec,
) where

import Foreign
import Foreign.C
import Simplex.Messaging.Crypto.SNTRUP761.Bindings.RNG (RNGContext, RNGFunc)

-- void sntrup761_keypair (uint8_t *pk, uint8_t *sk, void *random_ctx, sntrup761_random_func *random);
foreign import ccall "sntrup761_keypair"
  sntrup761_keypair :: Ptr Word8 -> Ptr Word8 -> RNGContext -> FunPtr RNGFunc -> IO ()

-- void sntrup761_enc (uint8_t *c, uint8_t *k, const uint8_t *pk, void *random_ctx, sntrup761_random_func *random);
foreign import ccall "sntrup761_enc"
  sntrup761_enc :: Ptr Word8 -> Ptr Word8 -> Ptr Word8 -> RNGContext -> FunPtr RNGFunc -> IO ()

-- void sntrup761_dec (uint8_t *k, const uint8_t *c, const uint8_t *sk);
foreign import ccall "sntrup761_dec"
  sntrup761_dec :: Ptr Word8 -> Ptr Word8 -> Ptr Word8 -> IO ()
