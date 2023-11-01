module Simplex.Messaging.Crypto.SNTRUP761.Bindings.RNG
  ( withDRG,
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

withDRG :: TVar ChaChaDRG -> (FunPtr RNGFunc -> IO a) -> IO a
withDRG drg = bracket (createRNGFunc drg) freeHaskellFunPtr

createRNGFunc :: TVar ChaChaDRG -> IO (FunPtr RNGFunc)
createRNGFunc drg =
  mkRNGFunc $ \_ctx sz buf -> do
    bs <- atomically $ C.pseudoRandomBytes (fromIntegral sz) drg
    copyByteArrayToPtr bs buf

type RNGContext = ()

-- typedef void random_func (void *ctx, size_t length, uint8_t *dst);
type RNGFunc = Ptr RNGContext -> CSize -> Ptr Word8 -> IO ()

foreign import ccall "wrapper"
  mkRNGFunc :: RNGFunc -> IO (FunPtr RNGFunc)
