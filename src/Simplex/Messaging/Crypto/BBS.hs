{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DerivingVia #-}
{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

module Simplex.Messaging.Crypto.BBS
  ( BBSSecretKey (..),
    BBSPublicKey (..),
    BBSSignature (..),
    BBSProof (..),
    BBSHeader (..),
    BBSPresHeader (..),
    bbsKeyGen,
    bbsSign,
    bbsVerify,
    bbsProofGen,
    bbsProofVerify,
  ) where

import Data.Aeson (FromJSON (..), ToJSON (..))
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import qualified Data.ByteString.Internal as BI
import Foreign
import Foreign.C
import Simplex.Messaging.Encoding.String

newtype BBSSecretKey = BBSSecretKey ByteString
  deriving newtype (Eq, Show, StrEncoding)

instance ToJSON BBSSecretKey where
  toJSON = strToJSON
  toEncoding = strToJEncoding

instance FromJSON BBSSecretKey where
  parseJSON = strParseJSON "BBSSecretKey"

newtype BBSPublicKey = BBSPublicKey ByteString
  deriving newtype (Eq, Show, StrEncoding)
  deriving (ToJSON, FromJSON) via BBSSecretKey

newtype BBSSignature = BBSSignature ByteString
  deriving newtype (Eq, Show, StrEncoding)
  deriving (ToJSON, FromJSON) via BBSSecretKey

newtype BBSProof = BBSProof ByteString
  deriving newtype (Eq, Show, StrEncoding)
  deriving (ToJSON, FromJSON) via BBSSecretKey

newtype BBSHeader = BBSHeader ByteString
  deriving newtype (Eq, Show, StrEncoding)
  deriving (ToJSON, FromJSON) via BBSSecretKey

newtype BBSPresHeader = BBSPresHeader ByteString
  deriving newtype (Eq, Show, StrEncoding)
  deriving (ToJSON, FromJSON) via BBSSecretKey

-- Constants

bbsSkLen, bbsPkLen, bbsSigLen, bbsProofBaseLen, bbsProofUdElemLen :: Int
bbsSkLen = 32
bbsPkLen = 96
bbsSigLen = 80
bbsProofBaseLen = 272
bbsProofUdElemLen = 32

bbsProofLen :: Int -> Int
bbsProofLen numUndisclosed = bbsProofBaseLen + numUndisclosed * bbsProofUdElemLen

-- FFI

data BBS_Ciphersuite

foreign import ccall "bbs_keygen_full"
  c_bbs_keygen_full :: Ptr BBS_Ciphersuite -> Ptr Word8 -> Ptr Word8 -> IO CInt

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

getCiphersuite :: IO (Ptr BBS_Ciphersuite)
getCiphersuite = peek c_bbs_sha256_ciphersuite

-- Helpers

withBS :: ByteString -> (Ptr Word8 -> CSize -> IO a) -> IO a
withBS bs f =
  let (fptr, off, len) = BI.toForeignPtr bs
   in withForeignPtr fptr $ \ptr -> f (ptr `plusPtr` off) (fromIntegral len)

packPtr :: Ptr Word8 -> Int -> IO ByteString
packPtr ptr len = B.packCStringLen (castPtr ptr, len)

withMessages :: [ByteString] -> (Ptr (Ptr Word8) -> Ptr CSize -> CSize -> IO a) -> IO a
withMessages msgs f = do
  let n = length msgs
  allocaArray n $ \msgsPtr ->
    allocaArray n $ \lensPtr -> do
      pokeMessages msgs msgsPtr lensPtr 0
      f msgsPtr lensPtr (fromIntegral n)
  where
    pokeMessages [] _ _ _ = pure ()
    pokeMessages (m : ms) msgsPtr lensPtr i = do
      let (fptr, off, len) = BI.toForeignPtr m
      withForeignPtr fptr $ \ptr -> do
        pokeElemOff msgsPtr i (ptr `plusPtr` off)
        pokeElemOff lensPtr i (fromIntegral len)
      pokeMessages ms msgsPtr lensPtr (i + 1)

withIndexes :: [Int] -> (Ptr CSize -> CSize -> IO a) -> IO a
withIndexes idxs f = do
  let n = length idxs
  allocaArray n $ \ptr -> do
    pokeArray ptr (map fromIntegral idxs)
    f ptr (fromIntegral n)

-- Public API

bbsKeyGen :: IO (Either String (BBSSecretKey, BBSPublicKey))
bbsKeyGen = do
  cs <- getCiphersuite
  allocaBytes bbsSkLen $ \skPtr ->
    allocaBytes bbsPkLen $ \pkPtr -> do
      rc <- c_bbs_keygen_full cs skPtr pkPtr
      if rc /= 0
        then pure $ Left "bbsKeyGen failed"
        else do
          sk <- packPtr skPtr bbsSkLen
          pk <- packPtr pkPtr bbsPkLen
          pure $ Right (BBSSecretKey sk, BBSPublicKey pk)

bbsSign ::
  BBSSecretKey ->
  BBSPublicKey ->
  BBSHeader ->
  [ByteString] ->
  IO (Either String BBSSignature)
bbsSign (BBSSecretKey sk) (BBSPublicKey pk) (BBSHeader header) msgs = do
  cs <- getCiphersuite
  allocaBytes bbsSigLen $ \sigPtr ->
    withBS sk $ \skPtr _ ->
      withBS pk $ \pkPtr _ ->
        withBS header $ \hdrPtr hdrLen ->
          withMessages msgs $ \msgsPtr lensPtr n -> do
            rc <- c_bbs_sign cs skPtr pkPtr sigPtr hdrPtr hdrLen n msgsPtr lensPtr
            if rc /= 0
              then pure $ Left "bbsSign failed"
              else Right . BBSSignature <$> packPtr sigPtr bbsSigLen

bbsVerify ::
  BBSPublicKey ->
  BBSSignature ->
  BBSHeader ->
  [ByteString] ->
  IO Bool
bbsVerify (BBSPublicKey pk) (BBSSignature sig) (BBSHeader header) msgs = do
  cs <- getCiphersuite
  withBS pk $ \pkPtr _ ->
    withBS sig $ \sigPtr _ ->
      withBS header $ \hdrPtr hdrLen ->
        withMessages msgs $ \msgsPtr lensPtr n -> do
          rc <- c_bbs_verify cs pkPtr sigPtr hdrPtr hdrLen n msgsPtr lensPtr
          pure (rc == 0)

bbsProofGen ::
  BBSPublicKey ->
  BBSSignature ->
  BBSHeader ->
  BBSPresHeader ->
  [Int] ->
  [ByteString] ->
  IO (Either String BBSProof)
bbsProofGen (BBSPublicKey pk) (BBSSignature sig) (BBSHeader header) (BBSPresHeader ph) disclosedIdxs msgs = do
  cs <- getCiphersuite
  let numUndisclosed = length msgs - length disclosedIdxs
      proofSz = bbsProofLen numUndisclosed
  allocaBytes proofSz $ \proofPtr ->
    withBS pk $ \pkPtr _ ->
      withBS sig $ \sigPtr _ ->
        withBS header $ \hdrPtr hdrLen ->
          withBS ph $ \phPtr phLen ->
            withIndexes disclosedIdxs $ \idxsPtr idxsLen ->
              withMessages msgs $ \msgsPtr lensPtr n -> do
                rc <- c_bbs_proof_gen cs pkPtr sigPtr proofPtr hdrPtr hdrLen phPtr phLen idxsPtr idxsLen n msgsPtr lensPtr
                if rc /= 0
                  then pure $ Left "bbsProofGen failed"
                  else Right . BBSProof <$> packPtr proofPtr proofSz

bbsProofVerify ::
  BBSPublicKey ->
  BBSProof ->
  BBSHeader ->
  BBSPresHeader ->
  [Int] ->
  Int ->
  [ByteString] ->
  IO Bool
bbsProofVerify (BBSPublicKey pk) (BBSProof proof) (BBSHeader header) (BBSPresHeader ph) disclosedIdxs numMessages disclosedMsgs = do
  cs <- getCiphersuite
  withBS pk $ \pkPtr _ ->
    withBS proof $ \proofPtr proofLen ->
      withBS header $ \hdrPtr hdrLen ->
        withBS ph $ \phPtr phLen ->
          withIndexes disclosedIdxs $ \idxsPtr idxsLen ->
            withMessages disclosedMsgs $ \msgsPtr lensPtr _ -> do
              rc <- c_bbs_proof_verify cs pkPtr proofPtr proofLen hdrPtr hdrLen phPtr phLen idxsPtr idxsLen (fromIntegral numMessages) msgsPtr lensPtr
              pure (rc == 0)
