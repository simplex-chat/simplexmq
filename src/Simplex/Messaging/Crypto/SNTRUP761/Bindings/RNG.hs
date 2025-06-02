module Simplex.Messaging.Crypto.SNTRUP761.Bindings.RNG
  ( withDRG,
    rngFuncPtr,
    RNGContext,
    RNGFunc,
  ) where

import Control.Concurrent.STM
import Control.Exception (bracket)
import Crypto.Random (ChaChaDRG)
import Data.ByteArray (ByteArrayAccess (copyByteArrayToPtr))
import Foreign
import Foreign.C
import qualified Simplex.Messaging.Crypto as C

withDRG :: TVar ChaChaDRG -> (Ptr RNGContext -> IO a) -> IO a
withDRG drg = bracket (castStablePtrToPtr <$> newStablePtr drg) (freeStablePtr . castPtrToStablePtr)

rngFunc :: RNGFunc
rngFunc cxt sz buf = do
  drg <- deRefStablePtr $ castPtrToStablePtr cxt
  bs <- atomically $ C.randomBytes (fromIntegral sz) drg
  copyByteArrayToPtr bs buf

type RNGContext = ()

-- typedef void random_func (void *ctx, size_t length, uint8_t *dst);
type RNGFunc = Ptr RNGContext -> CSize -> Ptr Word8 -> IO ()

foreign export ccall "haskell_rng_func" rngFunc :: RNGFunc

foreign import ccall "&haskell_rng_func" rngFuncPtr :: FunPtr RNGFunc
