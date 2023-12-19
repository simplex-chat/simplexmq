{-# LANGUAGE ForeignFunctionInterface #-}

module Simplex.Messaging.Crypto.SHA512.FFI
  ( cryptoHashSHA512,
    c_crypto_hash_sha512,
  ) where

import qualified Data.ByteString as B
import Foreign
import Foreign.C.Types
import GHC.IO (unsafePerformIO)

foreign import ccall "crypto_hash_sha512"
  c_crypto_hash_sha512 :: Ptr CChar -> Ptr CChar -> Word64 -> IO ()

cryptoHashSHA512 :: B.ByteString -> B.ByteString
cryptoHashSHA512 input = unsafePerformIO $
  B.useAsCStringLen input $ \(inPtr, inLen) ->
    allocaBytes outLen $ \outPtr -> do
      c_crypto_hash_sha512 outPtr inPtr (fromIntegral inLen)
      B.packCStringLen (outPtr, outLen)
  where
    outLen = 512 `div` 8
