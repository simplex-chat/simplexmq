{-# LANGUAGE CPP #-}
{-# LANGUAGE TypeApplications #-}

module Simplex.Messaging.Crypto.SNTRUP761.Bindings
  ( KEMPublicKey (..),
    KEMSecretKey,
    KEMCiphertext (..),
    KEMSharedKey (..),
    KEMKeyPair,
    sntrup761Keypair,
    sntrup761Enc,
    sntrup761Dec,
  ) where

import Control.Concurrent.STM
import Control.Exception (throwIO)
import Crypto.Random (ChaChaDRG)
import Data.Aeson (FromJSON (..), ToJSON (..))
import Data.Bifunctor (bimap)
import Data.ByteArray (ScrubbedBytes)
import qualified Data.ByteArray as BA
import Data.ByteString (ByteString)
import Simplex.Messaging.Agent.Store.DB (FromField (..), ToField (..))
import Simplex.Messaging.Crypto.SNTRUP761.Bindings.Defines
import Simplex.Messaging.Crypto.SNTRUP761.Bindings.FFI
import Simplex.Messaging.Crypto.SNTRUP761.Bindings.RNG (rngFuncPtr, withDRG)
import Simplex.Messaging.Encoding
import Simplex.Messaging.Encoding.String

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
            withDRG drg $ \cxtPtr -> c_sntrup761_keypair pkPtr skPtr cxtPtr rngFuncPtr
      )

sntrup761Enc :: TVar ChaChaDRG -> KEMPublicKey -> IO (KEMCiphertext, KEMSharedKey)
sntrup761Enc drg (KEMPublicKey pk) = do
  requireByteArrayLength "SNTRUP761 public key" c_SNTRUP761_PUBLICKEY_SIZE pk
  BA.withByteArray pk $ \pkPtr ->
    bimap KEMCiphertext KEMSharedKey
      <$> BA.allocRet
        c_SNTRUP761_SIZE
        ( \kPtr ->
            BA.alloc c_SNTRUP761_CIPHERTEXT_SIZE $ \cPtr ->
              withDRG drg $ \cxtPtr -> c_sntrup761_enc cPtr kPtr pkPtr cxtPtr rngFuncPtr
        )

sntrup761Dec :: KEMCiphertext -> KEMSecretKey -> IO KEMSharedKey
sntrup761Dec (KEMCiphertext c) (KEMSecretKey sk) = do
  requireByteArrayLength "SNTRUP761 ciphertext" c_SNTRUP761_CIPHERTEXT_SIZE c
  requireByteArrayLength "SNTRUP761 secret key" c_SNTRUP761_SECRETKEY_SIZE sk
  BA.withByteArray sk $ \skPtr ->
    BA.withByteArray c $ \cPtr ->
      KEMSharedKey
        <$> BA.alloc c_SNTRUP761_SIZE (\kPtr -> c_sntrup761_dec kPtr cPtr skPtr)

requireByteArrayLength :: BA.ByteArrayAccess bytes => String -> Int -> bytes -> IO ()
requireByteArrayLength valueName expected bytes =
  either (throwIO . userError) (const $ pure ()) $
    validateByteArrayLength valueName expected bytes

validateByteArrayLength :: BA.ByteArrayAccess bytes => String -> Int -> bytes -> Either String bytes
validateByteArrayLength valueName expected bytes
  | actual == expected = Right bytes
  | otherwise = Left $ valueName <> " must be " <> show expected <> " bytes, got " <> show actual
  where
    actual = BA.length bytes

parseKEMPublicKey :: ByteString -> Either String KEMPublicKey
parseKEMPublicKey =
  fmap KEMPublicKey . validateByteArrayLength "SNTRUP761 public key" c_SNTRUP761_PUBLICKEY_SIZE

parseKEMSecretKey :: ScrubbedBytes -> Either String KEMSecretKey
parseKEMSecretKey =
  fmap KEMSecretKey . validateByteArrayLength "SNTRUP761 secret key" c_SNTRUP761_SECRETKEY_SIZE

parseKEMCiphertext :: ByteString -> Either String KEMCiphertext
parseKEMCiphertext =
  fmap KEMCiphertext . validateByteArrayLength "SNTRUP761 ciphertext" c_SNTRUP761_CIPHERTEXT_SIZE

instance Encoding KEMSecretKey where
  smpEncode (KEMSecretKey c) = smpEncode . Large $ BA.convert c
  smpP = do
    Large bytes <- smpP
    either fail pure $ parseKEMSecretKey (BA.convert bytes)

instance StrEncoding KEMSecretKey where
  strEncode (KEMSecretKey pk) = strEncode (BA.convert pk :: ByteString)
  strP = either fail pure . parseKEMSecretKey . BA.convert =<< strP @ByteString

instance Encoding KEMPublicKey where
  smpEncode (KEMPublicKey pk) = smpEncode . Large $ BA.convert pk
  smpP = do
    Large bytes <- smpP
    either fail pure $ parseKEMPublicKey bytes

instance StrEncoding KEMPublicKey where
  strEncode (KEMPublicKey pk) = strEncode (BA.convert pk :: ByteString)
  strP = either fail pure . parseKEMPublicKey =<< strP @ByteString

instance Encoding KEMCiphertext where
  smpEncode (KEMCiphertext c) = smpEncode . Large $ BA.convert c
  smpP = do
    Large bytes <- smpP
    either fail pure $ parseKEMCiphertext bytes

instance Encoding KEMSharedKey where
  smpEncode (KEMSharedKey c) = smpEncode (BA.convert c :: ByteString)
  smpP = KEMSharedKey . BA.convert <$> smpP @ByteString

instance StrEncoding KEMCiphertext where
  strEncode (KEMCiphertext pk) = strEncode (BA.convert pk :: ByteString)
  strP = either fail pure . parseKEMCiphertext =<< strP @ByteString

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

instance FromField KEMSharedKey where
#if defined(dbPostgres)
  fromField f dat = KEMSharedKey . BA.convert @ByteString <$> fromField f dat
#else
  fromField f = KEMSharedKey . BA.convert @ByteString <$> fromField f
#endif

instance ToJSON KEMSharedKey where
  toJSON = strToJSON
  toEncoding = strToJEncoding

instance FromJSON KEMSharedKey where
  parseJSON = strParseJSON "KEMSharedKey"
