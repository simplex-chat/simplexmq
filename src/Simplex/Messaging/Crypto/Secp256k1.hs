{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | FFI bindings to libsecp256k1.
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

import Control.Exception (bracket)
import Control.Monad (void, when)
import Crypto.Random (drgNew, randomBytesGenerate)
import Data.ByteArray (ScrubbedBytes)
import qualified Data.ByteArray as BA
import Data.ByteString (ByteString)
import Foreign hiding (void)
import Foreign.C

-- Sizes

privateKeySize :: Int
privateKeySize = 32

compressedSize :: Int
compressedSize = 33

uncompressedSize :: Int
uncompressedSize = 65

-- | Internal size of @secp256k1_pubkey@ (opaque, not a serialization).
pubKeyInternalSize :: Int
pubKeyInternalSize = 64

-- Types

newtype Secp256k1PrivateKey = Secp256k1PrivateKey ScrubbedBytes
  deriving (Eq)

-- | A public key in libsecp256k1's opaque 64-byte form; 'serializePublicKey' returns the SEC1 bytes.
newtype Secp256k1PublicKey = Secp256k1PublicKey ByteString

data PubKeyFormat = Compressed | Uncompressed
  deriving (Eq, Show)

-- FFI

data Ctx

data PubKeyRaw

foreign import ccall "secp256k1_context_create"
  c_context_create :: CUInt -> IO (Ptr Ctx)

foreign import ccall "secp256k1_context_destroy"
  c_context_destroy :: Ptr Ctx -> IO ()

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

withContext :: (Ptr Ctx -> IO a) -> IO a
withContext f = bracket (c_context_create contextNone) c_context_destroy $ \ctx -> do
  drg <- drgNew
  let (seed :: ByteString, _) = randomBytesGenerate 32 drg
  rc <- BA.withByteArray seed $ c_context_randomize ctx
  when (rc /= 1) $ ioError (userError "secp256k1_context_randomize failed")
  f ctx

-- Public API

-- | Reject zero and anything at or above the group order, which is what makes 'secp256k1PublicKey' total.
mkPrivateKey :: ScrubbedBytes -> IO (Either String Secp256k1PrivateKey)
mkPrivateKey bs
  | BA.length bs /= privateKeySize = pure $ Left $ "private key: expected 32 bytes, got " <> show (BA.length bs)
  | otherwise = withContext $ \ctx -> BA.withByteArray bs $ \p -> do
      rc <- c_ec_seckey_verify ctx p
      pure $ if rc == 1 then Right (Secp256k1PrivateKey bs) else Left "private key: not in [1, n-1]"

unPrivateKey :: Secp256k1PrivateKey -> ScrubbedBytes
unPrivateKey (Secp256k1PrivateKey bs) = bs

secp256k1PublicKey :: Secp256k1PrivateKey -> IO Secp256k1PublicKey
secp256k1PublicKey (Secp256k1PrivateKey sk) = withContext $ \ctx -> do
  (rc, pk) <- BA.allocRet pubKeyInternalSize $ \pkPtr -> BA.withByteArray sk $ c_ec_pubkey_create ctx pkPtr
  when (rc /= 1) $ ioError (userError "secp256k1_ec_pubkey_create failed on a validated key")
  pure $ Secp256k1PublicKey pk

serializePublicKey :: PubKeyFormat -> Secp256k1PublicKey -> IO ByteString
serializePublicKey fmt (Secp256k1PublicKey pk) = withContext $ \ctx ->
  BA.alloc outLen $ \outPtr ->
    alloca $ \lenPtr ->
      BA.withByteArray pk $ \pkPtr -> do
        poke lenPtr (fromIntegral outLen)
        void $ c_ec_pubkey_serialize ctx outPtr lenPtr pkPtr flag
  where
    -- SECP256K1_EC_COMPRESSED = FLAGS_TYPE_COMPRESSION | FLAGS_BIT_COMPRESSION, SECP256K1_EC_UNCOMPRESSED = FLAGS_TYPE_COMPRESSION
    (flag, outLen) = case fmt of
      Compressed -> (2 .|. 256, compressedSize)
      Uncompressed -> (2, uncompressedSize)

-- | @sk + tweak mod n@, as BIP-32 child derivation requires. 'Nothing' when the result is zero or the tweak is out of range.
privateKeyTweakAdd :: Secp256k1PrivateKey -> ScrubbedBytes -> IO (Maybe Secp256k1PrivateKey)
privateKeyTweakAdd (Secp256k1PrivateKey sk) tweak
  | BA.length tweak /= privateKeySize = pure Nothing
  | otherwise = withContext $ \ctx ->
      BA.withByteArray tweak $ \twPtr -> do
        (rc, sk') <- BA.copyRet sk $ \skPtr -> c_ec_seckey_tweak_add ctx skPtr twPtr
        pure $ if rc == 1 then Just (Secp256k1PrivateKey sk') else Nothing
