{-# LANGUAGE CPP #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE PatternSynonyms #-}

module Simplex.Messaging.Crypto.SNTRUP761.Bindings
  ( KEMPublicKey,
    KEMSecretKey,
    KEMCiphertext,
    KEMSharedKey,
    pattern KEMPublicKey,
    pattern KEMSharedKey,
    KEMKeyPair,
    sntrup761Keypair,
    sntrup761Enc,
    sntrup761Dec,
  ) where

import Control.Concurrent.STM
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
import Simplex.Messaging.Util ((<$?>))

newtype KEMPublicKey = KEMPublicKey_ ByteString
  deriving (Eq, Show)

newtype KEMSecretKey = KEMSecretKey ScrubbedBytes
  deriving (Eq, Show)

newtype KEMCiphertext = KEMCiphertext ByteString
  deriving (Eq, Show)

newtype KEMSharedKey = KEMSharedKey_ ScrubbedBytes
  deriving (Eq, Show)

pattern KEMPublicKey :: ByteString -> KEMPublicKey
pattern KEMPublicKey s <- KEMPublicKey_ s

pattern KEMSharedKey :: ScrubbedBytes -> KEMSharedKey
pattern KEMSharedKey s <- KEMSharedKey_ s

{-# COMPLETE KEMPublicKey #-}

{-# COMPLETE KEMSharedKey #-}

type KEMKeyPair = (KEMPublicKey, KEMSecretKey)

sntrup761Keypair :: TVar ChaChaDRG -> IO KEMKeyPair
sntrup761Keypair drg =
  bimap KEMPublicKey_ KEMSecretKey
    <$> BA.allocRet
      c_SNTRUP761_SECRETKEY_SIZE
      ( \skPtr ->
          BA.alloc c_SNTRUP761_PUBLICKEY_SIZE $ \pkPtr ->
            withDRG drg $ \cxtPtr -> c_sntrup761_keypair pkPtr skPtr cxtPtr rngFuncPtr
      )

sntrup761Enc :: TVar ChaChaDRG -> KEMPublicKey -> IO (KEMCiphertext, KEMSharedKey)
sntrup761Enc drg (KEMPublicKey pk) =
  BA.withByteArray pk $ \pkPtr ->
    bimap KEMCiphertext KEMSharedKey_
      <$> BA.allocRet
        c_SNTRUP761_SIZE
        ( \kPtr ->
            BA.alloc c_SNTRUP761_CIPHERTEXT_SIZE $ \cPtr ->
              withDRG drg $ \cxtPtr -> c_sntrup761_enc cPtr kPtr pkPtr cxtPtr rngFuncPtr
        )

sntrup761Dec :: KEMCiphertext -> KEMSecretKey -> IO KEMSharedKey
sntrup761Dec (KEMCiphertext c) (KEMSecretKey sk) =
  BA.withByteArray sk $ \skPtr ->
    BA.withByteArray c $ \cPtr ->
      KEMSharedKey_
        <$> BA.alloc c_SNTRUP761_SIZE (\kPtr -> c_sntrup761_dec kPtr cPtr skPtr)

parseKey :: BA.ByteArrayAccess bs => (bs -> key) -> String -> Int -> bs -> Either String key
parseKey kCon name expected s
  | len == expected = Right $ kCon s
  | otherwise = Left $ name <> " must be " <> show expected <> " bytes, got " <> show len
  where
    len = BA.length s    

instance Encoding KEMSecretKey where
  smpEncode (KEMSecretKey c) = smpEncode . Large $ BA.convert c
  smpP = parseKey KEMSecretKey "SNTRUP761 secret key" c_SNTRUP761_SECRETKEY_SIZE . BA.convert . unLarge <$?> smpP

instance StrEncoding KEMSecretKey where
  strEncode (KEMSecretKey pk) = strEncode (BA.convert pk :: ByteString)
  strP = parseKey KEMSecretKey "SNTRUP761 secret key" c_SNTRUP761_SECRETKEY_SIZE . BA.convert <$?> strP @ByteString

instance Encoding KEMPublicKey where
  smpEncode (KEMPublicKey pk) = smpEncode . Large $ BA.convert pk
  smpP = parseKey KEMPublicKey_ "SNTRUP761 public key" c_SNTRUP761_PUBLICKEY_SIZE . unLarge <$?> smpP

instance StrEncoding KEMPublicKey where
  strEncode (KEMPublicKey pk) = strEncode (BA.convert pk :: ByteString)
  strP = parseKey KEMPublicKey_ "SNTRUP761 public key" c_SNTRUP761_PUBLICKEY_SIZE <$?> strP @ByteString

instance Encoding KEMCiphertext where
  smpEncode (KEMCiphertext c) = smpEncode . Large $ BA.convert c
  smpP = parseKey KEMCiphertext "SNTRUP761 ciphertext" c_SNTRUP761_CIPHERTEXT_SIZE . unLarge <$?> smpP

instance Encoding KEMSharedKey where
  smpEncode (KEMSharedKey c) = smpEncode (BA.convert c :: ByteString)
  smpP = KEMSharedKey_ . BA.convert <$> smpP @ByteString

instance StrEncoding KEMCiphertext where
  strEncode (KEMCiphertext pk) = strEncode (BA.convert pk :: ByteString)
  strP = parseKey KEMCiphertext "SNTRUP761 ciphertext" c_SNTRUP761_CIPHERTEXT_SIZE <$?> strP @ByteString

instance StrEncoding KEMSharedKey where
  strEncode (KEMSharedKey pk) = strEncode (BA.convert pk :: ByteString)
  strP = KEMSharedKey_ . BA.convert <$> strP @ByteString

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
  fromField f dat = KEMSharedKey_ . BA.convert @ByteString <$> fromField f dat
#else
  fromField f = KEMSharedKey_ . BA.convert @ByteString <$> fromField f
#endif

instance ToJSON KEMSharedKey where
  toJSON = strToJSON
  toEncoding = strToJEncoding

instance FromJSON KEMSharedKey where
  parseJSON = strParseJSON "KEMSharedKey"
