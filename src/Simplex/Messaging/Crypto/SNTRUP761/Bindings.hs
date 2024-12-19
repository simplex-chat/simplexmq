{-# LANGUAGE CPP #-}
{-# LANGUAGE TypeApplications #-}

module Simplex.Messaging.Crypto.SNTRUP761.Bindings where

import Control.Concurrent.STM
import Crypto.Random (ChaChaDRG)
import Data.Aeson (FromJSON (..), ToJSON (..))
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
#if defined(dbPostgres)
import Database.PostgreSQL.Simple.FromField
import Database.PostgreSQL.Simple.ToField
#else
import Database.SQLite.Simple.FromField
import Database.SQLite.Simple.ToField
#endif

newtype KEMPublicKey = KEMPublicKey ByteString
  deriving (Eq, Show)

newtype KEMSecretKey = KEMSecretKey ScrubbedBytes
  deriving (Eq, Show)

newtype KEMCiphertext = KEMCiphertext ByteString
  deriving (Eq, Show)

newtype KEMSharedKey = KEMSharedKey ScrubbedBytes
  deriving (Eq, Show)

unsafeRevealKEMSharedKey :: KEMSharedKey -> String
unsafeRevealKEMSharedKey (KEMSharedKey scrubbed) = show (BA.convert scrubbed :: ByteString)
{-# DEPRECATED unsafeRevealKEMSharedKey "unsafeRevealKEMSharedKey left in code" #-}

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

instance Encoding KEMSecretKey where
  smpEncode (KEMSecretKey c) = smpEncode . Large $ BA.convert c
  smpP = KEMSecretKey . BA.convert . unLarge <$> smpP

instance StrEncoding KEMSecretKey where
  strEncode (KEMSecretKey pk) = strEncode (BA.convert pk :: ByteString)
  strP = KEMSecretKey . BA.convert <$> strP @ByteString

instance Encoding KEMPublicKey where
  smpEncode (KEMPublicKey pk) = smpEncode . Large $ BA.convert pk
  smpP = KEMPublicKey . BA.convert . unLarge <$> smpP

instance StrEncoding KEMPublicKey where
  strEncode (KEMPublicKey pk) = strEncode (BA.convert pk :: ByteString)
  strP = KEMPublicKey . BA.convert <$> strP @ByteString

instance Encoding KEMCiphertext where
  smpEncode (KEMCiphertext c) = smpEncode . Large $ BA.convert c
  smpP = KEMCiphertext . BA.convert . unLarge <$> smpP

instance Encoding KEMSharedKey where
  smpEncode (KEMSharedKey c) = smpEncode (BA.convert c :: ByteString)
  smpP = KEMSharedKey . BA.convert <$> smpP @ByteString

instance StrEncoding KEMCiphertext where
  strEncode (KEMCiphertext pk) = strEncode (BA.convert pk :: ByteString)
  strP = KEMCiphertext . BA.convert <$> strP @ByteString

instance StrEncoding KEMSharedKey where
  strEncode (KEMSharedKey pk) = strEncode (BA.convert pk :: ByteString)
  strP = KEMSharedKey . BA.convert <$> strP @ByteString

instance ToJSON KEMSecretKey where
  toJSON = strToJSON
  toEncoding = strToJEncoding

instance FromJSON KEMSecretKey where
  parseJSON = strParseJSON "KEMSecretKey"

instance ToJSON KEMPublicKey where
  toJSON = strToJSON
  toEncoding = strToJEncoding

instance FromJSON KEMPublicKey where
  parseJSON = strParseJSON "KEMPublicKey"

instance ToJSON KEMCiphertext where
  toJSON = strToJSON
  toEncoding = strToJEncoding

instance FromJSON KEMCiphertext where
  parseJSON = strParseJSON "KEMCiphertext"

instance ToField KEMSharedKey where
  toField (KEMSharedKey k) = toField (BA.convert k :: ByteString)

#if defined(dbPostgres)
instance FromField KEMSharedKey where
  fromField field dat = do
    bs <- fromField field dat
    pure $ KEMSharedKey (BA.convert @ByteString bs)
#else
instance FromField KEMSharedKey where
  fromField f = KEMSharedKey . BA.convert @ByteString <$> fromField f
#endif

instance ToJSON KEMSharedKey where
  toJSON = strToJSON
  toEncoding = strToJEncoding

instance FromJSON KEMSharedKey where
  parseJSON = strParseJSON "KEMSharedKey"
