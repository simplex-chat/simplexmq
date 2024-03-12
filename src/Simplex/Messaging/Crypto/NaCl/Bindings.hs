{-# LANGUAGE CApiFFI #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Simplex.Messaging.Crypto.NaCl.Bindings where

import Crypto.Error (CryptoError, eitherCryptoError)
import Crypto.PubKey.Curve25519 (dhSecret)
import Data.ByteArray (ScrubbedBytes)
import qualified Data.ByteArray as BA
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import Data.Memory.PtrMethods (memSet)
import Foreign
import Foreign.C.ConstPtr
import Foreign.C.Types
import GHC.IO (unsafePerformIO)
import qualified Simplex.Messaging.Crypto as C

crypto_box_PUBLICKEYBYTES :: Num a => a
crypto_box_PUBLICKEYBYTES = 32

crypto_box_SECRETKEYBYTES :: Num a => a
crypto_box_SECRETKEYBYTES = 32

crypto_box_BEFORENMBYTES :: Num a => a
crypto_box_BEFORENMBYTES = 32

crypto_box_NONCEBYTES :: Num a => a
crypto_box_NONCEBYTES = 24

crypto_box_ZEROBYTES :: Num a => a
crypto_box_ZEROBYTES = 32

crypto_box_BOXZEROBYTES :: Num a => a
crypto_box_BOXZEROBYTES = 16

-- XXX: message should be ScrubbedBytes or something like that
cryptoBox :: BA.ByteArrayAccess msg => C.PublicKeyX25519 -> C.PrivateKeyX25519 -> C.CbNonce -> msg -> Either Int ByteString
cryptoBox (C.PublicKeyX25519 pk) (C.PrivateKeyX25519 sk _) (C.CbNonce n) msg = unsafePerformIO $ do
  (r, c) <-
    BA.withByteArray msg0 $ \mPtr ->
      BA.withByteArray n $ \nPtr ->
        BA.withByteArray pk $ \pkPtr ->
          BA.withByteArray sk $ \skPtr ->
            BA.allocRet (B.length msg0) $ \cPtr ->
              c_crypto_box cPtr (ConstPtr mPtr) (fromIntegral $ B.length msg0) (ConstPtr nPtr) (ConstPtr pkPtr) (ConstPtr skPtr)
  pure $
    if r /= 0
      then Left (fromIntegral r)
      else Right (B.drop crypto_box_BOXZEROBYTES c)
  where
    msg0 = B.replicate crypto_box_ZEROBYTES 0 <> BA.convert msg

foreign import capi "tweetnacl.h crypto_box"
  c_crypto_box :: Ptr Word8 -> ConstPtr Word8 -> Word64 -> ConstPtr Word8 -> ConstPtr Word8 -> ConstPtr Word8 -> IO CInt

cryptoBoxOpen :: C.PublicKeyX25519 -> C.PrivateKeyX25519 -> C.CbNonce -> ByteString -> Either Int ByteString
cryptoBoxOpen (C.PublicKeyX25519 pk) (C.PrivateKeyX25519 sk _) (C.CbNonce n) ciphertext = unsafePerformIO $ do
  (r, msg) <-
    BA.withByteArray ciphertext0 $ \cPtr ->
      BA.withByteArray n $ \nPtr ->
        BA.withByteArray pk $ \pkPtr ->
          BA.withByteArray sk $ \skPtr ->
            BA.allocRet cLen $ \mPtr ->
              c_crypto_box_open mPtr (ConstPtr cPtr) (fromIntegral cLen) (ConstPtr nPtr) (ConstPtr pkPtr) (ConstPtr skPtr)
  pure $
    if r /= 0
      then Left (fromIntegral r)
      else Right (B.drop crypto_box_ZEROBYTES msg)
  where
    ciphertext0 = B.replicate crypto_box_BOXZEROBYTES 0 <> ciphertext
    cLen = B.length ciphertext0

foreign import capi "crypto_box_open"
  c_crypto_box_open :: Ptr Word8 -> ConstPtr Word8 -> Word64 -> ConstPtr Word8 -> ConstPtr Word8 -> ConstPtr Word8 -> IO CInt

-- XXX: requires randombytes extern symbol available. Not relevant as we can random it ourselves.
-- foreign import ccall "crypto_box_keypair"
--   c_crypto_box_keypair :: Ptr Word8 -> Ptr Word8 -> IO CInt

foreign import capi "tweetnacl.h crypto_scalarmult"
  crypto_scalarmult :: Ptr Word8 -> ConstPtr Word8 -> ConstPtr Word8 -> IO CInt

-- | A replica of C.dh' using NaCl
dh :: C.PublicKeyX25519 -> C.PrivateKeyX25519 -> Either CryptoError (C.DhSecret C.X25519)
dh (C.PublicKeyX25519 pub) (C.PrivateKeyX25519 priv _) = unsafePerformIO $ do
  (r, ba :: ScrubbedBytes) <- BA.withByteArray pub $ \pubPtr ->
    BA.withByteArray priv $ \privPtr ->
      BA.allocRet 32 $ \sharedPtr -> do
        memSet sharedPtr 0 32
        crypto_scalarmult sharedPtr (ConstPtr privPtr) (ConstPtr pubPtr)
  pure $
    if r /= 0
      then Left (toEnum $ fromIntegral r)
      else C.DhSecretX25519 <$> eitherCryptoError (dhSecret ba)

-- XXX: does NOT result in the same DH key we/crypton use as it throws HSalsa20 at the result of the scalarmult op above
foreign import capi "tweetnacl.h crypto_box_beforenm"
  c_crypto_box_beforenm :: Ptr Word8 -> ConstPtr Word8 -> ConstPtr Word8 -> IO CInt

-- foreign import capi "crypto_box_afternm"
--   c_crypto_box_afternm :: Ptr Word8 -> ConstPtr Word8 -> Word64 -> ConstPtr Word8 -> ConstPtr Word8 -> IO CInt

-- foreign import capi "crypto_box_open_afternm"
--   c_crypto_box_open_afternm :: Ptr Word8 -> ConstPtr Word8 -> Word64 -> ConstPtr Word8 -> ConstPtr Word8 -> IO CInt
