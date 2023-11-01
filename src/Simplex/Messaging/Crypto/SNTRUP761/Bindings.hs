module Simplex.Messaging.Crypto.SNTRUP761.Bindings where

import Crypto.Random (ChaChaDRG)
import Data.ByteArray (ScrubbedBytes)
import qualified Data.ByteArray as BA
import Data.ByteString (ByteString)
import Data.IORef (IORef)
import Foreign (nullPtr)
import Simplex.Messaging.Crypto.SNTRUP761.Bindings.Defines
import Simplex.Messaging.Crypto.SNTRUP761.Bindings.FFI
import Simplex.Messaging.Crypto.SNTRUP761.Bindings.RNG (withDRG)

type PublicKey = ByteString

type SecretKey = ScrubbedBytes

type Ciphertext = ByteString

type SharedKey = ScrubbedBytes

sntrup761Keypair :: IORef ChaChaDRG -> IO (PublicKey, SecretKey)
sntrup761Keypair drg =
  withDRG drg $ \rngFunc ->
    BA.allocRet c_SNTRUP761_SECRETKEY_SIZE $ \skPtr ->
      BA.alloc c_SNTRUP761_PUBLICKEY_SIZE $ \pkPtr ->
        c_sntrup761_keypair pkPtr skPtr nullPtr rngFunc

sntrup761Enc :: IORef ChaChaDRG -> PublicKey -> IO (Ciphertext, SharedKey)
sntrup761Enc drg pk =
  withDRG drg $ \rngFunc ->
    BA.withByteArray pk $ \pkPtr ->
      BA.allocRet c_SNTRUP761_SIZE $ \kPtr ->
        BA.alloc c_SNTRUP761_CIPHERTEXT_SIZE $ \cPtr ->
          c_sntrup761_enc cPtr kPtr pkPtr nullPtr rngFunc

sntrup761Dec :: Ciphertext -> SecretKey -> IO SharedKey
sntrup761Dec c sk =
  BA.withByteArray sk $ \skPtr ->
    BA.withByteArray c $ \cPtr ->
      BA.alloc c_SNTRUP761_SIZE $ \kPtr ->
        c_sntrup761_dec kPtr cPtr skPtr
