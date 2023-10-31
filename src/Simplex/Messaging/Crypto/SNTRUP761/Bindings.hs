{-# LANGUAGE NamedFieldPuns #-}

module Simplex.Messaging.Crypto.SNTRUP761.Bindings where

import Data.ByteArray (ScrubbedBytes)
import qualified Data.ByteArray as BA
import Data.ByteString (ByteString)
import Simplex.Messaging.Crypto.SNTRUP761.Bindings.Defines
import Simplex.Messaging.Crypto.SNTRUP761.Bindings.FFI
import Simplex.Messaging.Crypto.SNTRUP761.Bindings.RNG (RNG (..))

type PublicKey = ByteString

type SecretKey = ScrubbedBytes

type Ciphertext = ByteString

type SharedKey = ScrubbedBytes

sntrup761Keypair :: RNG -> IO (PublicKey, SecretKey)
sntrup761Keypair RNG {rngContext, rngFunc} = do
  BA.allocRet c_SNTRUP761_SECRETKEY_SIZE $ \skPtr ->
    BA.alloc c_SNTRUP761_PUBLICKEY_SIZE $ \pkPtr ->
      c_sntrup761_keypair pkPtr skPtr rngContext rngFunc

sntrup761Enc :: RNG -> PublicKey -> IO (Ciphertext, SharedKey)
sntrup761Enc RNG {rngContext, rngFunc} pk =
  BA.withByteArray pk $ \pkPtr ->
    BA.allocRet c_SNTRUP761_SIZE $ \kPtr ->
      BA.alloc c_SNTRUP761_CIPHERTEXT_SIZE $ \cPtr ->
        c_sntrup761_enc cPtr kPtr pkPtr rngContext rngFunc

sntrup761Dec :: Ciphertext -> SecretKey -> IO SharedKey
sntrup761Dec c sk =
  BA.withByteArray sk $ \skPtr ->
    BA.withByteArray c $ \cPtr ->
      BA.alloc c_SNTRUP761_SIZE $ \kPtr ->
        c_sntrup761_dec kPtr cPtr skPtr
