{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

module Simplex.Messaging.Crypto
  ( PrivateKey (..),
    PublicKey (..),
    Signature (..),
    CryptoError (..),
    generateKeyPair,
    sign,
    verify,
    encrypt,
    decrypt,
    serializePrivKey,
    serializePubKey,
    parsePrivKey,
    parsePubKey,
    privKeyP,
    pubKeyP,
  )
where

import Control.Exception (Exception)
import Control.Monad.Except
import Control.Monad.Trans.Except
import Crypto.Cipher.AES (AES256)
import qualified Crypto.Cipher.Types as AES
import qualified Crypto.Error as CE
import Crypto.Hash.Algorithms (SHA256 (..))
import Crypto.Number.Generate (generateMax)
import Crypto.Number.Prime (findPrimeFrom)
import Crypto.Number.Serialize (i2osp, os2ip)
import qualified Crypto.PubKey.RSA as R
import qualified Crypto.PubKey.RSA.OAEP as OAEP
import qualified Crypto.PubKey.RSA.PSS as PSS
import Crypto.Random (getRandomBytes)
import Data.Attoparsec.ByteString.Char8 (Parser)
import qualified Data.Attoparsec.ByteString.Char8 as A
import Data.Bifunctor (first)
import qualified Data.ByteArray as BA
import Data.ByteString.Base64
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.ByteString.Internal (c2w, w2c)
import Data.String
import Database.SQLite.Simple as DB
import Database.SQLite.Simple.FromField
import Database.SQLite.Simple.Internal (Field (..))
import Database.SQLite.Simple.Ok (Ok (Ok))
import Database.SQLite.Simple.ToField (ToField (..))
import Simplex.Messaging.Parsers (base64P)
import Simplex.Messaging.Util (bshow, liftEitherError, (<$$>))

newtype PublicKey = PublicKey {rsaPublicKey :: R.PublicKey} deriving (Eq, Show)

data PrivateKey = PrivateKey
  { private_size :: Int,
    private_n :: Integer,
    private_d :: Integer
  }
  deriving (Eq, Show)

instance ToField PrivateKey where toField = toField . serializePrivKey

instance ToField PublicKey where toField = toField . serializePubKey

instance FromField PrivateKey where
  fromField f@(Field (SQLBlob b) _) =
    case parsePrivKey b of
      Right k -> Ok k
      Left e -> returnError ConversionFailed f ("couldn't parse PrivateKey field: " ++ e)
  fromField f = returnError ConversionFailed f "expecting SQLBlob column type"

instance FromField PublicKey where
  fromField f@(Field (SQLBlob b) _) =
    case parsePubKey b of
      Right k -> Ok k
      Left e -> returnError ConversionFailed f ("couldn't parse PublicKey field: " ++ e)
  fromField f = returnError ConversionFailed f "expecting SQLBlob column type"

type KeyPair = (PublicKey, PrivateKey)

newtype Signature = Signature {unSignature :: ByteString} deriving (Eq, Show)

instance IsString Signature where
  fromString = Signature . fromString

newtype Verified = Verified ByteString deriving (Show)

data CryptoError
  = CryptoRSAError R.Error
  | CryptoCipherError CE.CryptoError
  | CryptoIVError
  | CryptoDecryptError
  deriving (Eq, Show, Exception)

pubExpRange :: Integer
pubExpRange = 2 ^ (1024 :: Int)

generateKeyPair :: Int -> IO KeyPair
generateKeyPair size = loop
  where
    publicExponent = findPrimeFrom . (+ 3) <$> generateMax pubExpRange
    privateKey s n d = PrivateKey {private_size = s, private_n = n, private_d = d}
    loop = do
      (pub, priv) <- R.generate size =<< publicExponent
      let s = R.public_size pub
          n = R.public_n pub
          d = R.private_d priv
       in if d * d < n
            then loop
            else return (PublicKey pub, privateKey s n d)

encrypt :: PublicKey -> ByteString -> ExceptT CryptoError IO ByteString
encrypt k msg = do
  aesKey <- randomBytes 32
  ivBytes <- randomIVBytes @AES256
  aead <- initAEAD @AES256 (aesKey, ivBytes)
  let (authTag, msg') = encryptAES aead msg
  encKeyIv <- encryptOAEP k (aesKey <> ivBytes)
  return $ encKeyIv <> authTagToBS authTag <> msg'

decrypt :: PrivateKey -> ByteString -> ExceptT CryptoError IO ByteString
decrypt pk msg'' = do
  let (encKeyIv, msg') = B.splitAt (private_size pk) msg''
      (authTag, msg) = B.splitAt 16 msg'
  keyIv <- B.splitAt 32 <$> decryptOAEP pk encKeyIv
  aead <- initAEAD @AES256 keyIv
  decryptAES aead msg (bsToAuthTag authTag)

encryptAES :: AES.AEAD AES256 -> ByteString -> (AES.AuthTag, ByteString)
encryptAES aead plaintext = AES.aeadSimpleEncrypt aead B.empty plaintext 16

decryptAES :: AES.AEAD AES256 -> ByteString -> AES.AuthTag -> ExceptT CryptoError IO ByteString
decryptAES aead ciphertext authTag =
  maybeError CryptoDecryptError $ AES.aeadSimpleDecrypt aead B.empty ciphertext authTag

initAEAD :: forall c. AES.BlockCipher c => (ByteString, ByteString) -> ExceptT CryptoError IO (AES.AEAD c)
initAEAD (aesKey, ivBytes) = do
  iv <- makeIV @c ivBytes
  cryptoFailable $ do
    cipher <- AES.cipherInit aesKey
    AES.aeadInit AES.AEAD_GCM cipher iv

randomIVBytes :: forall c. AES.BlockCipher c => ExceptT CryptoError IO ByteString
randomIVBytes = randomBytes (AES.blockSize (undefined :: c))

makeIV :: AES.BlockCipher c => ByteString -> ExceptT CryptoError IO (AES.IV c)
makeIV bs = maybeError CryptoIVError $ AES.makeIV bs

randomBytes :: Int -> ExceptT CryptoError IO ByteString
randomBytes n = ExceptT $ Right <$> getRandomBytes n

maybeError :: CryptoError -> Maybe a -> ExceptT CryptoError IO a
maybeError e = maybe (throwE e) return

authTagToBS :: AES.AuthTag -> ByteString
authTagToBS = B.pack . map w2c . BA.unpack . AES.unAuthTag

bsToAuthTag :: ByteString -> AES.AuthTag
bsToAuthTag = AES.AuthTag . BA.pack . map c2w . B.unpack

cryptoFailable :: CE.CryptoFailable a -> ExceptT CryptoError IO a
cryptoFailable = liftEither . first CryptoCipherError . CE.eitherCryptoError

oaepParams :: OAEP.OAEPParams SHA256 ByteString ByteString
oaepParams = OAEP.defaultOAEPParams SHA256

encryptOAEP :: PublicKey -> ByteString -> ExceptT CryptoError IO ByteString
encryptOAEP (PublicKey k) aesKey =
  liftEitherError CryptoRSAError $
    OAEP.encrypt oaepParams k aesKey

decryptOAEP :: PrivateKey -> ByteString -> ExceptT CryptoError IO ByteString
decryptOAEP pk encKey =
  liftEitherError CryptoRSAError $
    OAEP.decryptSafer oaepParams (rsaPrivateKey pk) encKey

pssParams :: PSS.PSSParams SHA256 ByteString ByteString
pssParams = PSS.defaultPSSParams SHA256

sign :: PrivateKey -> ByteString -> IO (Either R.Error Signature)
sign pk msg = Signature <$$> PSS.signSafer pssParams (rsaPrivateKey pk) msg

verify :: PublicKey -> Signature -> ByteString -> Bool
verify (PublicKey k) (Signature sig) msg = PSS.verify pssParams k msg sig

serializePubKey :: PublicKey -> ByteString
serializePubKey (PublicKey k) = serializeKey_ (R.public_size k, R.public_n k, R.public_e k)

serializePrivKey :: PrivateKey -> ByteString
serializePrivKey pk = serializeKey_ (private_size pk, private_n pk, private_d pk)

serializeKey_ :: (Int, Integer, Integer) -> ByteString
serializeKey_ (size, n, ex) = bshow size <> "," <> encInt n <> "," <> encInt ex
  where
    encInt = encode . i2osp

pubKeyP :: Parser PublicKey
pubKeyP = do
  (public_size, public_n, public_e) <- keyParser_
  return . PublicKey $ R.PublicKey {R.public_size, R.public_n, R.public_e}

privKeyP :: Parser PrivateKey
privKeyP = do
  (private_size, private_n, private_d) <- keyParser_
  return PrivateKey {private_size, private_n, private_d}

parsePubKey :: ByteString -> Either String PublicKey
parsePubKey = A.parseOnly (pubKeyP <* A.endOfInput)

parsePrivKey :: ByteString -> Either String PrivateKey
parsePrivKey = A.parseOnly (privKeyP <* A.endOfInput)

keyParser_ :: Parser (Int, Integer, Integer)
keyParser_ = (,,) <$> (A.decimal <* ",") <*> (intP <* ",") <*> intP
  where
    intP = os2ip <$> base64P

rsaPrivateKey :: PrivateKey -> R.PrivateKey
rsaPrivateKey pk =
  R.PrivateKey
    { R.private_pub =
        R.PublicKey
          { R.public_size = private_size pk,
            R.public_n = private_n pk,
            R.public_e = undefined
          },
      R.private_d = private_d pk,
      R.private_p = 0,
      R.private_q = 0,
      R.private_dP = undefined,
      R.private_dQ = undefined,
      R.private_qinv = undefined
    }
