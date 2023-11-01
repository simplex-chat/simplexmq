{-# LANGUAGE TypeApplications #-}

module Simplex.Messaging.Crypto.SNTRUP761.Bindings where

import Control.Concurrent.STM
import Crypto.Random (ChaChaDRG)
import Data.Bifunctor (bimap)
import Data.ByteArray (ScrubbedBytes)
import qualified Data.ByteArray as BA
import Data.ByteString (ByteString)
import Foreign (nullPtr)
import Simplex.Messaging.Crypto.SNTRUP761.Bindings.Defines
import Simplex.Messaging.Crypto.SNTRUP761.Bindings.FFI
import Simplex.Messaging.Crypto.SNTRUP761.Bindings.RNG (withDRG)
import Simplex.Messaging.Encoding
import Simplex.Messaging.Encoding.String

newtype KEMPublicKey = KEMPublicKey ByteString

newtype KEMSecretKey = KEMSecretKey ScrubbedBytes

newtype KEMCiphertext = KEMCiphertext ByteString

newtype KEMSharedKey = KEMSharedKey ScrubbedBytes

sntrup761Keypair :: TVar ChaChaDRG -> IO (KEMPublicKey, KEMSecretKey)
sntrup761Keypair drg =
  withDRG drg $ \rngFunc ->
    bimap KEMPublicKey KEMSecretKey
      <$> BA.allocRet
        c_SNTRUP761_SECRETKEY_SIZE
        ( \skPtr ->
            BA.alloc c_SNTRUP761_PUBLICKEY_SIZE $ \pkPtr ->
              c_sntrup761_keypair pkPtr skPtr nullPtr rngFunc
        )

sntrup761Enc :: TVar ChaChaDRG -> KEMPublicKey -> IO (KEMCiphertext, KEMSharedKey)
sntrup761Enc drg (KEMPublicKey pk) =
  withDRG drg $ \rngFunc ->
    BA.withByteArray pk $ \pkPtr ->
      bimap KEMCiphertext KEMSharedKey
        <$> BA.allocRet
          c_SNTRUP761_SIZE
          ( \kPtr ->
              BA.alloc c_SNTRUP761_CIPHERTEXT_SIZE $ \cPtr ->
                c_sntrup761_enc cPtr kPtr pkPtr nullPtr rngFunc
          )

sntrup761Dec :: KEMCiphertext -> KEMSecretKey -> IO KEMSharedKey
sntrup761Dec (KEMCiphertext c) (KEMSecretKey sk) =
  BA.withByteArray sk $ \skPtr ->
    BA.withByteArray c $ \cPtr ->
      KEMSharedKey
        <$> BA.alloc c_SNTRUP761_SIZE (\kPtr -> c_sntrup761_dec kPtr cPtr skPtr)

instance Encoding KEMPublicKey where
  smpEncode (KEMPublicKey pk) = smpEncode (BA.convert pk :: ByteString)
  smpP = KEMPublicKey . BA.convert <$> smpP @ByteString

instance StrEncoding KEMPublicKey where
  strEncode (KEMPublicKey pk) = strEncode (BA.convert pk :: ByteString)
  strP = KEMPublicKey . BA.convert <$> strP @ByteString

instance Encoding KEMCiphertext where
  smpEncode (KEMCiphertext c) = smpEncode (BA.convert c :: ByteString)
  smpP = KEMCiphertext . BA.convert <$> smpP @ByteString
