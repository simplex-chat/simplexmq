{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DerivingVia #-}
{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | FFI bindings to libbbs (BBS+ signatures over BLS12-381, SHA-256 suite).
-- Values parsed from untrusted input are length-validated; see FixedBS and the
-- BBSProof StrEncoding instance.
module Simplex.Messaging.Crypto.BBS
  ( BBSSecretKey (..),
    BBSPublicKey (..),
    BBSKeyPair,
    BBSSignature (..),
    BBSProof (..),
    BBSHeader (..),
    BBSPresHeader (..),
    bbsKeyGen,
    bbsPublicKey,
    bbsSign,
    bbsVerify,
    bbsProofGen,
    bbsProofVerify,
  ) where

import Data.Aeson (FromJSON, ToJSON)
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import qualified Data.ByteString.Unsafe as BU
import Data.Proxy (Proxy (..))
import Foreign
import Foreign.C
import GHC.TypeLits (KnownNat, KnownSymbol, Nat, Symbol, natVal, symbolVal)
import Simplex.Messaging.Encoding.String
import System.IO.Unsafe (unsafePerformIO)

-- Note: the data constructors below are unchecked escape hatches for trusted,
-- internally-produced values (e.g. keygen output). Any value parsed from
-- untrusted input (StrEncoding / FromJSON) is length-validated — see FixedBS
-- and the BBSProof StrEncoding instance.

newtype BBSSecretKey = BBSSecretKey ByteString
  deriving newtype (Eq, Show)
  deriving (StrEncoding) via (FixedBS "BBSSecretKey" 32)
  deriving (ToJSON, FromJSON) via (StrJSON "BBSSecretKey")

newtype BBSPublicKey = BBSPublicKey ByteString
  deriving newtype (Eq, Show)
  deriving (StrEncoding) via (FixedBS "BBSPublicKey" 96)
  deriving (ToJSON, FromJSON) via (StrJSON "BBSPublicKey")

type BBSKeyPair = (BBSPublicKey, BBSSecretKey)

newtype BBSSignature = BBSSignature ByteString
  deriving newtype (Eq, Show)
  deriving (StrEncoding) via (FixedBS "BBSSignature" 80)
  deriving (ToJSON, FromJSON) via (StrJSON "BBSSignature")

newtype BBSProof = BBSProof ByteString
  deriving newtype (Eq, Show)
  deriving (ToJSON, FromJSON) via (StrJSON "BBSProof")

newtype BBSHeader = BBSHeader ByteString
  deriving newtype (Eq, Show, StrEncoding)
  deriving (ToJSON, FromJSON) via (StrJSON "BBSHeader")

newtype BBSPresHeader = BBSPresHeader ByteString
  deriving newtype (Eq, Show, StrEncoding)
  deriving (ToJSON, FromJSON) via (StrJSON "BBSPresHeader")

-- | A ByteString validated to be exactly @n@ bytes when parsed via StrEncoding
-- (and the JSON derived from it). Local to BBS, where every key/signature is a
-- fixed size; @name@ appears in the decode error only.
newtype FixedBS (name :: Symbol) (n :: Nat) = FixedBS ByteString

instance forall name n. (KnownSymbol name, KnownNat n) => StrEncoding (FixedBS name n) where
  strEncode (FixedBS bs) = strEncode bs
  strP = do
    bs <- base64urlP
    let n = fromIntegral (natVal (Proxy :: Proxy n))
    if B.length bs == n
      then pure (FixedBS bs)
      else fail $ symbolVal (Proxy :: Proxy name) <> ": expected " <> show n <> " bytes, got " <> show (B.length bs)

-- Constants

bbsSkLen, bbsPkLen, bbsSigLen, bbsProofBaseLen, bbsProofUdElemLen :: Int
bbsSkLen = 32
bbsPkLen = 96
bbsSigLen = 80
bbsProofBaseLen = 272
bbsProofUdElemLen = 32

bbsProofLen :: Int -> Int
bbsProofLen numUndisclosed = bbsProofBaseLen + numUndisclosed * bbsProofUdElemLen

-- | A proof is @bbsProofBaseLen + 32 * numUndisclosed@ bytes; reject anything else.
instance StrEncoding BBSProof where
  strEncode (BBSProof bs) = strEncode bs
  strP = do
    bs <- base64urlP
    let len = B.length bs
    if len >= bbsProofBaseLen && (len - bbsProofBaseLen) `mod` bbsProofUdElemLen == 0
      then pure (BBSProof bs)
      else fail $ "BBS: invalid proof length " <> show len

-- FFI

data BBS_Ciphersuite

foreign import ccall "bbs_keygen_full"
  c_bbs_keygen_full :: Ptr BBS_Ciphersuite -> Ptr Word8 -> Ptr Word8 -> IO CInt

foreign import ccall "bbs_sk_to_pk"
  c_bbs_sk_to_pk :: Ptr BBS_Ciphersuite -> Ptr Word8 -> Ptr Word8 -> IO CInt

foreign import ccall "bbs_sign"
  c_bbs_sign ::
    Ptr BBS_Ciphersuite ->
    Ptr Word8 -> Ptr Word8 -> Ptr Word8 ->
    Ptr Word8 -> CSize ->
    CSize -> Ptr (Ptr Word8) -> Ptr CSize ->
    IO CInt

foreign import ccall "bbs_verify"
  c_bbs_verify ::
    Ptr BBS_Ciphersuite ->
    Ptr Word8 -> Ptr Word8 ->
    Ptr Word8 -> CSize ->
    CSize -> Ptr (Ptr Word8) -> Ptr CSize ->
    IO CInt

foreign import ccall "bbs_proof_gen"
  c_bbs_proof_gen ::
    Ptr BBS_Ciphersuite ->
    Ptr Word8 -> Ptr Word8 -> Ptr Word8 ->
    Ptr Word8 -> CSize ->
    Ptr Word8 -> CSize ->
    Ptr CSize -> CSize ->
    CSize -> Ptr (Ptr Word8) -> Ptr CSize ->
    IO CInt

foreign import ccall "bbs_proof_verify"
  c_bbs_proof_verify ::
    Ptr BBS_Ciphersuite ->
    Ptr Word8 ->
    Ptr Word8 -> CSize ->
    Ptr Word8 -> CSize ->
    Ptr Word8 -> CSize ->
    Ptr CSize -> CSize ->
    CSize -> Ptr (Ptr Word8) -> Ptr CSize ->
    IO CInt

foreign import ccall "&bbs_sha256_ciphersuite"
  c_bbs_sha256_ciphersuite :: Ptr (Ptr BBS_Ciphersuite)

-- The ciphersuite is a static const pointer in libbbs; read it once.
ciphersuite :: Ptr BBS_Ciphersuite
ciphersuite = unsafePerformIO $ peek c_bbs_sha256_ciphersuite
{-# NOINLINE ciphersuite #-}

-- Helpers

withBS :: ByteString -> (Ptr Word8 -> CSize -> IO a) -> IO a
withBS bs f = BU.unsafeUseAsCStringLen bs $ \(p, l) -> f (castPtr p) (fromIntegral l)

packPtr :: Ptr Word8 -> Int -> IO ByteString
packPtr ptr len = B.packCStringLen (castPtr ptr, len)

-- Marshals a list of messages into parallel pointer/length arrays. Each
-- ByteString is held alive (via nested unsafeUseAsCStringLen) until @f@ returns,
-- so the C callee never sees a pointer to freed memory.
withMessages :: [ByteString] -> (Ptr (Ptr Word8) -> Ptr CSize -> CSize -> IO a) -> IO a
withMessages msgs f = go msgs []
  where
    go [] acc =
      let cstrs = reverse acc
       in withArray (map fst cstrs) $ \msgsPtr ->
            withArray (map snd cstrs) $ \lensPtr ->
              f msgsPtr lensPtr (fromIntegral $ length cstrs)
    go (m : ms) acc =
      BU.unsafeUseAsCStringLen m $ \(p, l) ->
        go ms ((castPtr p :: Ptr Word8, fromIntegral l :: CSize) : acc)

withIndexes :: [Int] -> (Ptr CSize -> CSize -> IO a) -> IO a
withIndexes idxs f =
  withArrayLen (map fromIntegral idxs :: [CSize]) $ \n ptr -> f ptr (fromIntegral n)

-- Public API

bbsKeyGen :: IO (Either String BBSKeyPair)
bbsKeyGen =
  allocaBytes bbsSkLen $ \skPtr ->
    allocaBytes bbsPkLen $ \pkPtr -> do
      rc <- c_bbs_keygen_full ciphersuite skPtr pkPtr
      if rc /= 0
        then pure $ Left "bbsKeyGen failed"
        else do
          sk <- packPtr skPtr bbsSkLen
          pk <- packPtr pkPtr bbsPkLen
          pure $ Right (BBSPublicKey pk, BBSSecretKey sk)

bbsPublicKey :: BBSSecretKey -> IO (Either String BBSPublicKey)
bbsPublicKey (BBSSecretKey sk) =
  allocaBytes bbsPkLen $ \pkPtr ->
    withBS sk $ \skPtr _ -> do
      rc <- c_bbs_sk_to_pk ciphersuite skPtr pkPtr
      if rc /= 0
        then pure $ Left "bbsPublicKey failed"
        else Right . BBSPublicKey <$> packPtr pkPtr bbsPkLen

bbsSign ::
  BBSSecretKey ->
  BBSHeader ->
  [ByteString] ->
  IO (Either String BBSSignature)
bbsSign secret@(BBSSecretKey sk) (BBSHeader header) msgs =
  bbsPublicKey secret >>= either (pure . Left) sign'
  where
    sign' (BBSPublicKey pk) =
      allocaBytes bbsSigLen $ \sigPtr ->
        withBS sk $ \skPtr _ ->
          withBS pk $ \pkPtr _ ->
            withBS header $ \hdrPtr hdrLen ->
              withMessages msgs $ \msgsPtr lensPtr n -> do
                rc <- c_bbs_sign ciphersuite skPtr pkPtr sigPtr hdrPtr hdrLen n msgsPtr lensPtr
                if rc /= 0
                  then pure $ Left "bbsSign failed"
                  else Right . BBSSignature <$> packPtr sigPtr bbsSigLen

bbsVerify ::
  BBSPublicKey ->
  BBSSignature ->
  BBSHeader ->
  [ByteString] ->
  IO Bool
bbsVerify (BBSPublicKey pk) (BBSSignature sig) (BBSHeader header) msgs =
  withBS pk $ \pkPtr _ ->
    withBS sig $ \sigPtr _ ->
      withBS header $ \hdrPtr hdrLen ->
        withMessages msgs $ \msgsPtr lensPtr n -> do
          rc <- c_bbs_verify ciphersuite pkPtr sigPtr hdrPtr hdrLen n msgsPtr lensPtr
          pure (rc == 0)

bbsProofGen ::
  BBSPublicKey ->
  BBSSignature ->
  BBSHeader ->
  BBSPresHeader ->
  [Int] ->
  [ByteString] ->
  IO (Either String BBSProof)
bbsProofGen (BBSPublicKey pk) (BBSSignature sig) (BBSHeader header) (BBSPresHeader ph) disclosedIdxs msgs =
  allocaBytes proofSz $ \proofPtr ->
    withBS pk $ \pkPtr _ ->
      withBS sig $ \sigPtr _ ->
        withBS header $ \hdrPtr hdrLen ->
          withBS ph $ \phPtr phLen ->
            withIndexes disclosedIdxs $ \idxsPtr idxsLen ->
              withMessages msgs $ \msgsPtr lensPtr n -> do
                rc <- c_bbs_proof_gen ciphersuite pkPtr sigPtr proofPtr hdrPtr hdrLen phPtr phLen idxsPtr idxsLen n msgsPtr lensPtr
                if rc /= 0
                  then pure $ Left "bbsProofGen failed"
                  else Right . BBSProof <$> packPtr proofPtr proofSz
  where
    numUndisclosed = length msgs - length disclosedIdxs
    proofSz = bbsProofLen numUndisclosed

bbsProofVerify ::
  BBSPublicKey ->
  BBSProof ->
  BBSHeader ->
  BBSPresHeader ->
  [Int] ->
  Int ->
  [ByteString] ->
  IO Bool
bbsProofVerify (BBSPublicKey pk) (BBSProof proof) (BBSHeader header) (BBSPresHeader ph) disclosedIdxs numMessages disclosedMsgs =
  withBS pk $ \pkPtr _ ->
    withBS proof $ \proofPtr proofLen ->
      withBS header $ \hdrPtr hdrLen ->
        withBS ph $ \phPtr phLen ->
          withIndexes disclosedIdxs $ \idxsPtr idxsLen ->
            withMessages disclosedMsgs $ \msgsPtr lensPtr _ -> do
              rc <- c_bbs_proof_verify ciphersuite pkPtr proofPtr proofLen hdrPtr hdrLen phPtr phLen idxsPtr idxsLen (fromIntegral numMessages) msgsPtr lensPtr
              pure (rc == 0)
