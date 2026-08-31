{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | FFI bindings to libsecp256k1 (ECDSA over secp256k1 with public key recovery).
--
-- Only what Ethereum signing needs: key validation, public key derivation and
-- serialization, scalar addition (for BIP-32 child derivation), recoverable
-- signing and recovery.
--
-- Signatures are produced with libsecp256k1's default RFC-6979 deterministic
-- nonce, so signing is a pure function of (key, digest) — which is why this
-- module exposes a pure API over 'unsafePerformIO'. libsecp256k1 also always
-- emits the low-@s@ form, so every signature from 'signRecoverable' is already
-- EIP-2 compliant; 'isLowS' is provided so callers can assert that rather than
-- trust it. Note there is deliberately no normalization entry point: we never
-- accept a foreign signature, we only produce our own.
module Simplex.Messaging.Crypto.Secp256k1
  ( PrivateKey,
    PublicKey,
    RecoverableSignature (..),
    PubKeyFormat (..),
    mkPrivateKey,
    unPrivateKey,
    publicKey,
    parsePublicKey,
    serializePublicKey,
    privateKeyTweakAdd,
    publicKeyTweakMul,
    publicKeyTweakAdd,
    signRecoverable,
    recoverPublicKey,
    isLowS,
    privateKeySize,
    compressedSize,
    uncompressedSize,
    digestSize,
  )
where

import Control.Monad (when)
import Crypto.Random (drgNew, randomBytesGenerate)
import qualified Data.ByteArray as BA
import qualified Data.ByteArray.Encoding as BAE
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as BC
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

-- | ECDSA signs a 32-byte digest, never a message.
digestSize :: Int
digestSize = 32

-- | Internal size of @secp256k1_pubkey@ (opaque, not a serialization).
pubKeyInternalSize :: Int
pubKeyInternalSize = 64

-- | Internal size of @secp256k1_ecdsa_recoverable_signature@.
recSigInternalSize :: Int
recSigInternalSize = 65

compactSize :: Int
compactSize = 64

-- Types

-- | A validated secp256k1 private key: 32 bytes, in @[1, n-1]@.
--
-- 'Show' is redacting and 'Eq' is constant-time, both deliberately: this key
-- authorises transfers of assets with monetary value, so it must not reach a
-- log through a derived 'Show' and must not leak through comparison timing.
newtype PrivateKey = PrivateKey ByteString

instance Show PrivateKey where
  show _ = "PrivateKey <redacted>"

instance Eq PrivateKey where
  PrivateKey a == PrivateKey b = BA.constEq a b

-- | A parsed public key, held in libsecp256k1's opaque 64-byte internal form.
-- Use 'serializePublicKey' to get the SEC1 bytes.
newtype PublicKey = PublicKey ByteString
  deriving newtype (Eq)

instance Show PublicKey where
  show pk = "PublicKey " <> BC.unpack (hex $ serializePublicKey Compressed pk)

hex :: ByteString -> ByteString
hex = BAE.convertToBase BAE.Base16

-- | SEC1 output format for 'serializePublicKey'.
data PubKeyFormat = Compressed | Uncompressed
  deriving (Eq, Show)

-- | A signature plus the recovery id needed to recover the signing key.
-- @rsCompact@ is @r || s@, 64 bytes big-endian; @rsRecId@ is in @[0, 3]@.
-- Ethereum's @v@ is @rsRecId + 27@ (or @+ 35 + 2 * chainId@ for EIP-155).
data RecoverableSignature = RecoverableSignature
  { rsCompact :: ByteString,
    rsRecId :: Int
  }
  deriving (Eq, Show)

-- FFI

data Ctx

data PubKeyRaw

data RecSigRaw

foreign import ccall "secp256k1_context_create"
  c_context_create :: CUInt -> IO (Ptr Ctx)

foreign import ccall "secp256k1_context_randomize"
  c_context_randomize :: Ptr Ctx -> Ptr Word8 -> IO CInt

foreign import ccall "secp256k1_ec_seckey_verify"
  c_ec_seckey_verify :: Ptr Ctx -> Ptr Word8 -> IO CInt

foreign import ccall "secp256k1_ec_pubkey_create"
  c_ec_pubkey_create :: Ptr Ctx -> Ptr PubKeyRaw -> Ptr Word8 -> IO CInt

foreign import ccall "secp256k1_ec_pubkey_parse"
  c_ec_pubkey_parse :: Ptr Ctx -> Ptr PubKeyRaw -> Ptr Word8 -> CSize -> IO CInt

foreign import ccall "secp256k1_ec_pubkey_serialize"
  c_ec_pubkey_serialize :: Ptr Ctx -> Ptr Word8 -> Ptr CSize -> Ptr PubKeyRaw -> CUInt -> IO CInt

foreign import ccall "secp256k1_ec_seckey_tweak_add"
  c_ec_seckey_tweak_add :: Ptr Ctx -> Ptr Word8 -> Ptr Word8 -> IO CInt

foreign import ccall "secp256k1_ec_pubkey_tweak_mul"
  c_ec_pubkey_tweak_mul :: Ptr Ctx -> Ptr PubKeyRaw -> Ptr Word8 -> IO CInt
foreign import ccall "secp256k1_ec_pubkey_tweak_add"
  c_ec_pubkey_tweak_add :: Ptr Ctx -> Ptr PubKeyRaw -> Ptr Word8 -> IO CInt

foreign import ccall "secp256k1_ecdsa_sign_recoverable"
  c_ecdsa_sign_recoverable :: Ptr Ctx -> Ptr RecSigRaw -> Ptr Word8 -> Ptr Word8 -> Ptr () -> Ptr () -> IO CInt

foreign import ccall "secp256k1_ecdsa_recoverable_signature_serialize_compact"
  c_recsig_serialize_compact :: Ptr Ctx -> Ptr Word8 -> Ptr CInt -> Ptr RecSigRaw -> IO CInt

foreign import ccall "secp256k1_ecdsa_recoverable_signature_parse_compact"
  c_recsig_parse_compact :: Ptr Ctx -> Ptr RecSigRaw -> Ptr Word8 -> CInt -> IO CInt

foreign import ccall "secp256k1_ecdsa_recover"
  c_ecdsa_recover :: Ptr Ctx -> Ptr PubKeyRaw -> Ptr RecSigRaw -> Ptr Word8 -> IO CInt

-- SECP256K1_CONTEXT_NONE = SECP256K1_FLAGS_TYPE_CONTEXT
contextNone :: CUInt
contextNone = 1

-- SECP256K1_EC_COMPRESSED = SECP256K1_FLAGS_TYPE_COMPRESSION | SECP256K1_FLAGS_BIT_COMPRESSION
-- SECP256K1_EC_UNCOMPRESSED = SECP256K1_FLAGS_TYPE_COMPRESSION
formatFlag :: PubKeyFormat -> CUInt
formatFlag = \case
  Compressed -> 2 .|. 256
  Uncompressed -> 2

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

-- | Marshal a 'PublicKey' back into its opaque C representation.
withPubKeyRaw :: PublicKey -> (Ptr PubKeyRaw -> IO a) -> IO a
withPubKeyRaw (PublicKey bs) f = withBS bs $ f . castPtr

-- | Marshal a 'RecoverableSignature' into the opaque C representation, failing
-- if libsecp256k1 rejects it.
withRecSigRaw :: RecoverableSignature -> (Ptr RecSigRaw -> IO (Either String a)) -> IO (Either String a)
withRecSigRaw (RecoverableSignature compact recId) f
  | B.length compact /= compactSize = pure $ Left "signature: expected 64 bytes"
  | recId < 0 || recId > 3 = pure $ Left "signature: recovery id out of range"
  | otherwise =
      allocaBytes recSigInternalSize $ \sigPtr ->
        withBS compact $ \cPtr -> do
          rc <- c_recsig_parse_compact secp256k1Ctx sigPtr cPtr (fromIntegral recId)
          if rc /= 1 then pure $ Left "signature: malformed" else f sigPtr

-- Public API

-- | Validate 32 bytes as a private key. Rejects zero and anything at or above
-- the group order, which is what makes 'publicKey' and 'signRecoverable' total.
mkPrivateKey :: ByteString -> Either String PrivateKey
mkPrivateKey bs
  | B.length bs /= privateKeySize = Left $ "private key: expected 32 bytes, got " <> show (B.length bs)
  | otherwise = unsafePerformIO $ withBS bs $ \p -> do
      rc <- c_ec_seckey_verify secp256k1Ctx p
      pure $ if rc == 1 then Right (PrivateKey bs) else Left "private key: not in [1, n-1]"

unPrivateKey :: PrivateKey -> ByteString
unPrivateKey (PrivateKey bs) = bs

-- | Derive the public key. Total, because 'PrivateKey' is validated.
publicKey :: PrivateKey -> PublicKey
publicKey (PrivateKey sk) = unsafePerformIO $
  allocaBytes pubKeyInternalSize $ \pkPtr ->
    withBS sk $ \skPtr -> do
      rc <- c_ec_pubkey_create secp256k1Ctx pkPtr skPtr
      -- Cannot fail: the key was verified by mkPrivateKey.
      when (rc /= 1) $ ioError (userError "secp256k1_ec_pubkey_create failed on a validated key")
      PublicKey <$> packPtr (castPtr pkPtr) pubKeyInternalSize

-- | Parse a SEC1 point, compressed (33 bytes) or uncompressed (65 bytes).
parsePublicKey :: ByteString -> Either String PublicKey
parsePublicKey bs
  | len /= compressedSize && len /= uncompressedSize =
      Left $ "public key: expected 33 or 65 bytes, got " <> show len
  | otherwise = unsafePerformIO $
      allocaBytes pubKeyInternalSize $ \pkPtr ->
        withBS bs $ \inPtr -> do
          rc <- c_ec_pubkey_parse secp256k1Ctx pkPtr inPtr (fromIntegral len)
          if rc == 1
            then Right . PublicKey <$> packPtr (castPtr pkPtr) pubKeyInternalSize
            else pure $ Left "public key: not a valid curve point"
  where
    len = B.length bs

serializePublicKey :: PubKeyFormat -> PublicKey -> ByteString
serializePublicKey fmt pk = unsafePerformIO $
  allocaBytes outLen $ \outPtr ->
    alloca $ \lenPtr ->
      withPubKeyRaw pk $ \pkPtr -> do
        poke lenPtr (fromIntegral outLen)
        rc <- c_ec_pubkey_serialize secp256k1Ctx outPtr lenPtr pkPtr (formatFlag fmt)
        when (rc /= 1) $ ioError (userError "secp256k1_ec_pubkey_serialize failed")
        written <- peek lenPtr
        packPtr outPtr (fromIntegral written)
  where
    outLen = case fmt of
      Compressed -> compressedSize
      Uncompressed -> uncompressedSize

-- | @sk + tweak mod n@, as BIP-32 child derivation needs.
--
-- 'Nothing' when the result is zero or the tweak is out of range — BIP-32
-- requires the caller to skip to the next child index in that case.
privateKeyTweakAdd :: PrivateKey -> ByteString -> Maybe PrivateKey
privateKeyTweakAdd (PrivateKey sk) tweak
  | B.length tweak /= privateKeySize = Nothing
  | otherwise = unsafePerformIO $
      allocaBytes privateKeySize $ \skPtr ->
        withBS tweak $ \twPtr -> do
          withBS sk $ \src -> copyBytes skPtr src privateKeySize
          rc <- c_ec_seckey_tweak_add secp256k1Ctx skPtr twPtr
          if rc == 1
            then Just . PrivateKey <$> packPtr skPtr privateKeySize
            else pure Nothing

-- | @tweak * P@. The scalar multiplication behind an ECDH shared secret.
--
-- Deliberately exposed instead of @secp256k1_ecdh@: that function hashes the
-- resulting point with SHA-256, while ERC-5564 hashes it with keccak256 over
-- the uncompressed coordinates. Returning the point leaves the hash to the
-- caller.
--
-- 'Nothing' when the tweak is zero or out of range.
publicKeyTweakMul :: PublicKey -> ByteString -> Maybe PublicKey
publicKeyTweakMul = tweakPubKey c_ec_pubkey_tweak_mul

-- | @P + tweak * G@, the point addition stealth address derivation needs.
--
-- 'Nothing' when the tweak is out of range or the result is the point at
-- infinity.
publicKeyTweakAdd :: PublicKey -> ByteString -> Maybe PublicKey
publicKeyTweakAdd = tweakPubKey c_ec_pubkey_tweak_add

tweakPubKey :: (Ptr Ctx -> Ptr PubKeyRaw -> Ptr Word8 -> IO CInt) -> PublicKey -> ByteString -> Maybe PublicKey
tweakPubKey f pk tweak
  | B.length tweak /= privateKeySize = Nothing
  | otherwise = unsafePerformIO $
      allocaBytes pubKeyInternalSize $ \pkPtr ->
        withBS tweak $ \twPtr -> do
          withPubKeyRaw pk $ \src -> copyBytes (castPtr pkPtr) (castPtr src) pubKeyInternalSize
          rc <- f secp256k1Ctx pkPtr twPtr
          if rc == 1
            then Just . PublicKey <$> packPtr (castPtr pkPtr) pubKeyInternalSize
            else pure Nothing

-- | Sign a 32-byte digest. Deterministic (RFC 6979) and always low-@s@.
signRecoverable :: PrivateKey -> ByteString -> Either String RecoverableSignature
signRecoverable (PrivateKey sk) digest
  | B.length digest /= digestSize =
      Left $ "digest: expected 32 bytes, got " <> show (B.length digest)
  | otherwise = unsafePerformIO $
      allocaBytes recSigInternalSize $ \sigPtr ->
        withBS digest $ \msgPtr ->
          withBS sk $ \skPtr -> do
            rc <- c_ecdsa_sign_recoverable secp256k1Ctx sigPtr msgPtr skPtr nullPtr nullPtr
            if rc /= 1
              then pure $ Left "secp256k1_ecdsa_sign_recoverable failed"
              else allocaBytes compactSize $ \outPtr ->
                alloca $ \recIdPtr -> do
                  rc' <- c_recsig_serialize_compact secp256k1Ctx outPtr recIdPtr sigPtr
                  if rc' /= 1
                    then pure $ Left "secp256k1_ecdsa_recoverable_signature_serialize_compact failed"
                    else do
                      compact <- packPtr outPtr compactSize
                      recId <- peek recIdPtr
                      pure $ Right RecoverableSignature {rsCompact = compact, rsRecId = fromIntegral recId}

-- | Recover the signing public key from a signature and the digest it signed.
recoverPublicKey :: RecoverableSignature -> ByteString -> Either String PublicKey
recoverPublicKey sig digest
  | B.length digest /= digestSize =
      Left $ "digest: expected 32 bytes, got " <> show (B.length digest)
  | otherwise = unsafePerformIO $
      withRecSigRaw sig $ \sigPtr ->
        allocaBytes pubKeyInternalSize $ \pkPtr ->
          withBS digest $ \msgPtr -> do
            rc <- c_ecdsa_recover secp256k1Ctx pkPtr sigPtr msgPtr
            if rc == 1
              then Right . PublicKey <$> packPtr (castPtr pkPtr) pubKeyInternalSize
              else pure $ Left "secp256k1_ecdsa_recover failed"

-- | Whether @s <= n/2@, i.e. the signature is in the canonical form EIP-2
-- requires. libsecp256k1 guarantees this for anything it signs; this exists so
-- tests can assert it rather than assume it.
isLowS :: RecoverableSignature -> Bool
isLowS (RecoverableSignature compact _) =
  B.length compact == compactSize && beToInteger (B.drop 32 compact) <= halfOrder
  where
    halfOrder :: Integer
    halfOrder = 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0

beToInteger :: ByteString -> Integer
beToInteger = B.foldl' (\acc w -> acc * 256 + fromIntegral w) 0
