{-# LANGUAGE TypeApplications #-}

module Simplex.Messaging.Crypto.SNTRUP761.Bindings where

import Control.Concurrent.STM
import Crypto.Random (ChaChaDRG)
import Data.Aeson (FromJSON (..), ToJSON (..))
import Data.Bifunctor (bimap)
import Data.ByteArray (ScrubbedBytes)
import qualified Data.ByteArray as BA
import Data.ByteString (ByteString)
import Database.SQLite.Simple.FromField
import Database.SQLite.Simple.ToField
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

instance StrEncoding KEMPublicKey where
  strEncode (KEMPublicKey pk) = strEncode (BA.convert pk :: ByteString)
  strP = KEMPublicKey . BA.convert <$> strP @ByteString

instance Encoding KEMCiphertext where
  smpEncode (KEMCiphertext c) = smpEncode . Large $ BA.convert c
  smpP = KEMCiphertext . BA.convert . unLarge <$> smpP

instance ToJSON KEMPublicKey where
  toJSON = strToJSON
  toEncoding = strToJEncoding

instance FromJSON KEMPublicKey where
  parseJSON = strParseJSON "KEMPublicKey"

instance ToField KEMSharedKey where
  toField (KEMSharedKey k) = toField (BA.convert k :: ByteString)

instance FromField KEMSharedKey where
  fromField f = KEMSharedKey . BA.convert @ByteString <$> fromField f
