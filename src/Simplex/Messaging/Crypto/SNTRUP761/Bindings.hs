{-# LANGUAGE TypeApplications #-}

module Simplex.Messaging.Crypto.SNTRUP761.Bindings where

import Control.Concurrent.STM
import Crypto.Random (ChaChaDRG)
import qualified Data.Aeson as J
import Data.Bifunctor (bimap)
import Data.ByteArray (ScrubbedBytes)
import qualified Data.ByteArray as BA
import Data.ByteString (ByteString)
import Data.Text.Encoding (decodeUtf8, encodeUtf8)
import Foreign (nullPtr)
import Simplex.Messaging.Crypto.SNTRUP761.Bindings.Defines
import Simplex.Messaging.Crypto.SNTRUP761.Bindings.FFI
import Simplex.Messaging.Crypto.SNTRUP761.Bindings.RNG (withDRG)
import Simplex.Messaging.Encoding
import Simplex.Messaging.Encoding.String

newtype KEMPublicKey = KEMPublicKey ByteString
  deriving (Show)

newtype KEMSecretKey = KEMSecretKey ScrubbedBytes
  deriving (Show)

newtype KEMCiphertext = KEMCiphertext ByteString
  deriving (Show)

newtype KEMSharedKey = KEMSharedKey ScrubbedBytes
  deriving (Show)

type KEMKeyPair = (KEMPublicKey, KEMSecretKey)

sntrup761Keypair :: TVar ChaChaDRG -> IO KEMKeyPair
sntrup761Keypair drg =
  bimap KEMPublicKey KEMSecretKey
    <$> BA.allocRet
      c_SNTRUP761_SECRETKEY_SIZE
      ( \skPtr ->
          BA.alloc c_SNTRUP761_PUBLICKEY_SIZE $ \pkPtr ->
            withDRG drg $ c_sntrup761_keypair pkPtr skPtr nullPtr
      )

sntrup761Enc :: TVar ChaChaDRG -> KEMPublicKey -> IO (KEMCiphertext, KEMSharedKey)
sntrup761Enc drg (KEMPublicKey pk) =
  BA.withByteArray pk $ \pkPtr ->
    bimap KEMCiphertext KEMSharedKey
      <$> BA.allocRet
        c_SNTRUP761_SIZE
        ( \kPtr ->
            BA.alloc c_SNTRUP761_CIPHERTEXT_SIZE $ \cPtr ->
              withDRG drg $ c_sntrup761_enc cPtr kPtr pkPtr nullPtr
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

instance J.ToJSON KEMPublicKey where
  toJSON = J.toJSON . decodeUtf8 . strEncode

instance J.FromJSON KEMPublicKey where
  parseJSON =
    J.withText "KEMPublicKey" $
      either fail pure . strDecode . encodeUtf8
