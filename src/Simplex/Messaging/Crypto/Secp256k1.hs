{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | FFI bindings to libsecp256k1.
module Simplex.Messaging.Crypto.Secp256k1
  ( Secp256k1PrivateKey,
    Secp256k1PublicKey,
    Secp256k1Context,
    PubKeyFormat (..),
    RecoverableSignature (..),
    mkPrivateKey,
    unPrivateKey,
    withContext,
    secp256k1PublicKey,
    secp256k1PublicKey_,
    serializePublicKey,
    privateKeyTweakAdd,
    signRecoverable,
  )
where

import Control.Concurrent.STM
import Control.Exception (bracket, throwIO)
import Control.Monad (void, when)
import Crypto.Number.Serialize (i2ospOf_)
import qualified Crypto.PubKey.ECC.Types as ECT
import Crypto.Random (ChaChaDRG)
import Data.ByteArray (ScrubbedBytes)
import qualified Data.ByteArray as BA
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import Foreign hiding (void)
import Foreign.C
import qualified Simplex.Messaging.Crypto as C
import System.IO.Unsafe (unsafePerformIO)

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

-- | Internal size of @secp256k1_ecdsa_recoverable_signature@.
recSigInternalSize :: Int
recSigInternalSize = 65

compactSigSize :: Int
compactSigSize = 64

digestSize :: Int
digestSize = 32

-- Types

newtype Secp256k1PrivateKey = Secp256k1PrivateKey ScrubbedBytes
  deriving (Eq)

-- | A public key in libsecp256k1's opaque 64-byte form; 'serializePublicKey' returns the SEC1 bytes.
newtype Secp256k1PublicKey = Secp256k1PublicKey ByteString

newtype Secp256k1Context = Secp256k1Context (Ptr Ctx)

data PubKeyFormat = Compressed | Uncompressed
  deriving (Eq, Show)

-- | @r || s@, 64 bytes big-endian, and the recovery id, EIP-1559's @yParity@.
data RecoverableSignature = RecoverableSignature
  { rsCompact :: ByteString,
    rsRecId :: Word8
  }
  deriving (Eq, Show)

-- FFI

data Ctx

data PubKeyRaw

data RecSigRaw

foreign import ccall "secp256k1_context_create"
  c_context_create :: CUInt -> IO (Ptr Ctx)

foreign import ccall "secp256k1_context_destroy"
  c_context_destroy :: Ptr Ctx -> IO ()

foreign import ccall "secp256k1_context_randomize"
  c_context_randomize :: Ptr Ctx -> Ptr Word8 -> IO CInt

foreign import ccall "&secp256k1_context_static"
  c_context_static :: Ptr (Ptr Ctx)

foreign import ccall "secp256k1_ec_pubkey_create"
  c_ec_pubkey_create :: Ptr Ctx -> Ptr PubKeyRaw -> Ptr Word8 -> IO CInt

foreign import ccall "secp256k1_ec_pubkey_serialize"
  c_ec_pubkey_serialize :: Ptr Ctx -> Ptr Word8 -> Ptr CSize -> Ptr PubKeyRaw -> CUInt -> IO CInt

foreign import ccall "secp256k1_ec_seckey_tweak_add"
  c_ec_seckey_tweak_add :: Ptr Ctx -> Ptr Word8 -> Ptr Word8 -> IO CInt

foreign import ccall "secp256k1_ecdsa_sign_recoverable"
  c_ecdsa_sign_recoverable :: Ptr Ctx -> Ptr RecSigRaw -> Ptr Word8 -> Ptr Word8 -> Ptr () -> Ptr () -> IO CInt

foreign import ccall "secp256k1_ecdsa_recoverable_signature_serialize_compact"
  c_ecdsa_recoverable_signature_serialize_compact :: Ptr Ctx -> Ptr Word8 -> Ptr CInt -> Ptr RecSigRaw -> IO CInt

-- SECP256K1_CONTEXT_NONE = SECP256K1_FLAGS_TYPE_CONTEXT
contextNone :: CUInt
contextNone = 1

staticContext :: Ptr Ctx
staticContext = unsafePerformIO $ peek c_context_static
{-# NOINLINE staticContext #-}

withContext :: TVar ChaChaDRG -> (Secp256k1Context -> IO a) -> IO a
withContext g f = bracket (c_context_create contextNone) c_context_destroy $ \ctx -> do
  seed :: ScrubbedBytes <- atomically $ C.randomBytes' 32 g
  rc <- BA.withByteArray seed $ c_context_randomize ctx
  when (rc /= 1) $ throwIO (userError "secp256k1_context_randomize failed")
  f $ Secp256k1Context ctx

-- Public API

-- | Reject zero and anything at or above the group order, which is what makes 'secp256k1PublicKey' total.
mkPrivateKey :: ScrubbedBytes -> Either String Secp256k1PrivateKey
mkPrivateKey bs
  | BA.length bs /= privateKeySize = Left $ "private key: expected 32 bytes, got " <> show (BA.length bs)
  | BA.all (== 0) bs || bs >= groupOrder = Left "private key: not in [1, n-1]"
  | otherwise = Right $ Secp256k1PrivateKey bs

-- | Compared as bytes: both are 32 bytes big-endian, and 'ScrubbedBytes' compares lexicographically.
groupOrder :: ScrubbedBytes
groupOrder = i2ospOf_ privateKeySize $ ECT.ecc_n $ ECT.common_curve $ ECT.getCurveByName ECT.SEC_p256k1

unPrivateKey :: Secp256k1PrivateKey -> ScrubbedBytes
unPrivateKey (Secp256k1PrivateKey bs) = bs

secp256k1PublicKey :: TVar ChaChaDRG -> Secp256k1PrivateKey -> IO Secp256k1PublicKey
secp256k1PublicKey g k = withContext g (`secp256k1PublicKey_` k)

secp256k1PublicKey_ :: Secp256k1Context -> Secp256k1PrivateKey -> IO Secp256k1PublicKey
secp256k1PublicKey_ (Secp256k1Context ctx) (Secp256k1PrivateKey sk) = do
  (rc, pk) <- BA.allocRet pubKeyInternalSize $ \pkPtr -> BA.withByteArray sk $ c_ec_pubkey_create ctx pkPtr
  when (rc /= 1) $ throwIO (userError "secp256k1_ec_pubkey_create failed on a validated key")
  pure $ Secp256k1PublicKey pk

serializePublicKey :: PubKeyFormat -> Secp256k1PublicKey -> IO ByteString
serializePublicKey fmt (Secp256k1PublicKey pk) =
  BA.alloc outLen $ \outPtr ->
    with (fromIntegral outLen) $ \lenPtr ->
      BA.withByteArray pk $ \pkPtr ->
        void $ c_ec_pubkey_serialize staticContext outPtr lenPtr pkPtr flag
  where
    -- SECP256K1_EC_COMPRESSED = SECP256K1_FLAGS_TYPE_COMPRESSION | SECP256K1_FLAGS_BIT_COMPRESSION, SECP256K1_EC_UNCOMPRESSED = SECP256K1_FLAGS_TYPE_COMPRESSION
    (flag, outLen) = case fmt of
      Compressed -> (2 .|. 256, compressedSize)
      Uncompressed -> (2, uncompressedSize)

-- | @sk + tweak mod n@, as BIP-32 child derivation requires. 'Nothing' when the tweak is not 32 bytes or not below n, or when the result is zero.
privateKeyTweakAdd :: Secp256k1PrivateKey -> ScrubbedBytes -> IO (Maybe Secp256k1PrivateKey)
privateKeyTweakAdd (Secp256k1PrivateKey sk) tweak
  | BA.length tweak /= privateKeySize = pure Nothing
  | otherwise =
      BA.withByteArray tweak $ \twPtr -> do
        (rc, sk') <- BA.copyRet sk $ \skPtr -> c_ec_seckey_tweak_add staticContext skPtr twPtr
        pure $ if rc == 1 then Just (Secp256k1PrivateKey sk') else Nothing

-- | Signs a 32-byte digest, deterministically (RFC 6979) and always low-@s@, as EIP-2 requires.
signRecoverable :: TVar ChaChaDRG -> Secp256k1PrivateKey -> ByteString -> IO RecoverableSignature
signRecoverable g (Secp256k1PrivateKey sk) digest
  | B.length digest /= digestSize = throwIO $ userError $ "digest: expected 32 bytes, got " <> show (B.length digest)
  | otherwise = withContext g $ \(Secp256k1Context ctx) ->
      allocaBytes recSigInternalSize $ \sigPtr -> do
        rc <- BA.withByteArray digest $ \msgPtr -> BA.withByteArray sk $ \skPtr -> c_ecdsa_sign_recoverable ctx sigPtr msgPtr skPtr nullPtr nullPtr
        when (rc /= 1) $ throwIO (userError "secp256k1_ecdsa_sign_recoverable failed on a validated key")
        (recId, compact) <- BA.allocRet compactSigSize $ \outPtr ->
          alloca $ \recIdPtr -> do
            void $ c_ecdsa_recoverable_signature_serialize_compact ctx outPtr recIdPtr sigPtr
            peek recIdPtr
        pure RecoverableSignature {rsCompact = compact, rsRecId = fromIntegral recId}
