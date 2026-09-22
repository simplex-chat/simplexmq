{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | FFI bindings to libsecp256k1.
--
-- Key validation, public key derivation and serialization, and scalar addition
-- for BIP-32 child derivation. The pure API over 'unsafePerformIO' is safe
-- because every operation is a pure function of its arguments.
module Simplex.Messaging.Crypto.Secp256k1
  ( Secp256k1PrivateKey,
    Secp256k1PublicKey,
    PubKeyFormat (..),
    mkPrivateKey,
    unPrivateKey,
    secp256k1PublicKey,
    serializePublicKey,
    privateKeyTweakAdd,
  )
where

import Control.Monad (when)
import Crypto.Random (drgNew, randomBytesGenerate)
import qualified Data.ByteArray as BA
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import qualified Data.ByteString.Unsafe as BU
import Foreign
import Foreign.C
import System.IO.Unsafe (unsafePerformIO)

-- Sizes

-- | A secp256k1 scalar is 32 bytes, big-endian.
privateKeySize :: Int
privateKeySize = 32

-- | SEC1 compressed point: @0x02@/@0x03@ prefix and the x coordinate.
compressedSize :: Int
compressedSize = 33

-- | SEC1 uncompressed point: @0x04@ prefix, x, y.
uncompressedSize :: Int
uncompressedSize = 65


-- | Internal size of @secp256k1_pubkey@ (opaque, not a serialization).
pubKeyInternalSize :: Int
pubKeyInternalSize = 64


-- Types

-- | A validated secp256k1 private key: 32 bytes, in @[1, n-1]@.
--
-- There is no 'Show' instance, so the key cannot be logged by accident, and
-- 'Eq' is constant-time: this key authorises transfers of assets with monetary
-- value.
newtype Secp256k1PrivateKey = Secp256k1PrivateKey ByteString

instance Eq Secp256k1PrivateKey where
  Secp256k1PrivateKey a == Secp256k1PrivateKey b = BA.constEq a b

-- | A parsed public key, held in libsecp256k1's opaque 64-byte internal form.
-- Use 'serializePublicKey' to get the SEC1 bytes.
newtype Secp256k1PublicKey = Secp256k1PublicKey ByteString
  deriving newtype (Eq, Show)

-- | SEC1 output format for 'serializePublicKey'.
data PubKeyFormat = Compressed | Uncompressed
  deriving (Eq, Show)

-- FFI

data Ctx

data PubKeyRaw

foreign import ccall "secp256k1_context_create"
  c_context_create :: CUInt -> IO (Ptr Ctx)

foreign import ccall "secp256k1_context_randomize"
  c_context_randomize :: Ptr Ctx -> Ptr Word8 -> IO CInt

foreign import ccall "secp256k1_ec_seckey_verify"
  c_ec_seckey_verify :: Ptr Ctx -> Ptr Word8 -> IO CInt

foreign import ccall "secp256k1_ec_pubkey_create"
  c_ec_pubkey_create :: Ptr Ctx -> Ptr PubKeyRaw -> Ptr Word8 -> IO CInt

foreign import ccall "secp256k1_ec_pubkey_serialize"
  c_ec_pubkey_serialize :: Ptr Ctx -> Ptr Word8 -> Ptr CSize -> Ptr PubKeyRaw -> CUInt -> IO CInt

foreign import ccall "secp256k1_ec_seckey_tweak_add"
  c_ec_seckey_tweak_add :: Ptr Ctx -> Ptr Word8 -> Ptr Word8 -> IO CInt

-- SECP256K1_CONTEXT_NONE = SECP256K1_FLAGS_TYPE_CONTEXT
contextNone :: CUInt
contextNone = 1

-- | The process-wide context, created and blinded once.
--
-- Randomization is a side-channel countermeasure only: it does not affect any
-- output, and signing does not mutate the context, so sharing one context
-- across threads is safe and the pure API below is sound.
secp256k1Ctx :: Ptr Ctx
secp256k1Ctx = unsafePerformIO $ do
  ctx <- c_context_create contextNone
  when (ctx == nullPtr) $ ioError (userError "secp256k1_context_create failed")
  drg <- drgNew
  let (seed :: ByteString, _) = randomBytesGenerate 32 drg
  rc <- BU.unsafeUseAsCString seed $ \p -> c_context_randomize ctx (castPtr p)
  when (rc /= 1) $ ioError (userError "secp256k1_context_randomize failed")
  pure ctx
{-# NOINLINE secp256k1Ctx #-}

-- Helpers

withBS :: ByteString -> (Ptr Word8 -> IO a) -> IO a
withBS bs f = BU.unsafeUseAsCString bs $ f . castPtr

packPtr :: Ptr Word8 -> Int -> IO ByteString
packPtr p n = B.packCStringLen (castPtr p, n)

-- | Marshal a 'Secp256k1PublicKey' back into its opaque C representation.
withPubKeyRaw :: Secp256k1PublicKey -> (Ptr PubKeyRaw -> IO a) -> IO a
withPubKeyRaw (Secp256k1PublicKey bs) f = withBS bs $ f . castPtr


-- Public API

-- | Validate 32 bytes as a private key. Rejects zero and anything at or above
-- the group order, which is what makes 'secp256k1PublicKey' total.
mkPrivateKey :: ByteString -> Either String Secp256k1PrivateKey
mkPrivateKey bs
  | B.length bs /= privateKeySize = Left $ "private key: expected 32 bytes, got " <> show (B.length bs)
  | otherwise = unsafePerformIO $ withBS bs $ \p -> do
      rc <- c_ec_seckey_verify secp256k1Ctx p
      pure $ if rc == 1 then Right (Secp256k1PrivateKey bs) else Left "private key: not in [1, n-1]"

unPrivateKey :: Secp256k1PrivateKey -> ByteString
unPrivateKey (Secp256k1PrivateKey bs) = bs

-- | Derive the public key. Total, because 'Secp256k1PrivateKey' is validated.
secp256k1PublicKey :: Secp256k1PrivateKey -> Secp256k1PublicKey
secp256k1PublicKey (Secp256k1PrivateKey sk) = unsafePerformIO $
  allocaBytes pubKeyInternalSize $ \pkPtr ->
    withBS sk $ \skPtr -> do
      rc <- c_ec_pubkey_create secp256k1Ctx pkPtr skPtr
      -- Cannot fail: the key was verified by mkPrivateKey.
      when (rc /= 1) $ ioError (userError "secp256k1_ec_pubkey_create failed on a validated key")
      Secp256k1PublicKey <$> packPtr (castPtr pkPtr) pubKeyInternalSize


serializePublicKey :: PubKeyFormat -> Secp256k1PublicKey -> ByteString
serializePublicKey fmt pk = unsafePerformIO $
  allocaBytes outLen $ \outPtr ->
    alloca $ \lenPtr ->
      withPubKeyRaw pk $ \pkPtr -> do
        poke lenPtr (fromIntegral outLen)
        rc <- c_ec_pubkey_serialize secp256k1Ctx outPtr lenPtr pkPtr flag
        when (rc /= 1) $ ioError (userError "secp256k1_ec_pubkey_serialize failed")
        written <- peek lenPtr
        packPtr outPtr (fromIntegral written)
  where
    -- SECP256K1_EC_COMPRESSED = SECP256K1_FLAGS_TYPE_COMPRESSION | SECP256K1_FLAGS_BIT_COMPRESSION
    -- SECP256K1_EC_UNCOMPRESSED = SECP256K1_FLAGS_TYPE_COMPRESSION
    (flag, outLen) = case fmt of
      Compressed -> (2 .|. 256, compressedSize)
      Uncompressed -> (2, uncompressedSize)

-- | @sk + tweak mod n@, as BIP-32 child derivation needs.
--
-- 'Nothing' when the result is zero or the tweak is out of range - BIP-32
-- requires the caller to skip to the next child index in that case.
privateKeyTweakAdd :: Secp256k1PrivateKey -> ByteString -> Maybe Secp256k1PrivateKey
privateKeyTweakAdd (Secp256k1PrivateKey sk) tweak
  | B.length tweak /= privateKeySize = Nothing
  | otherwise = unsafePerformIO $
      allocaBytes privateKeySize $ \skPtr ->
        withBS tweak $ \twPtr -> do
          withBS sk $ \src -> copyBytes skPtr src privateKeySize
          rc <- c_ec_seckey_tweak_add secp256k1Ctx skPtr twPtr
          if rc == 1
            then Just . Secp256k1PrivateKey <$> packPtr skPtr privateKeySize
            else pure Nothing


