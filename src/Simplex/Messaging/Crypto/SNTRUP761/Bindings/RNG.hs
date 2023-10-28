module Simplex.Messaging.Crypto.SNTRUP761.Bindings.RNG
  ( RNG (..)
  , dummyRNG
  , RNGContext
  , RNGFunc
  ) where

import Foreign
import Foreign.C

data RNG = RNG
  { rngContext :: RNGContext
  , rngFunc :: RNGFunc
  }

dummyRNG :: RNG
dummyRNG = RNG {rngContext = nullPtr, rngFunc = randomDummy}

type RNGContext = Ptr RNG

-- typedef void random_func (void *ctx, size_t length, uint8_t *dst);
type RNGFunc = FunPtr (Ptr RNGContext -> CSize -> Ptr Word8 -> IO ())

foreign import ccall "&sxcrandom_dummy"
  randomDummy :: RNGFunc
