{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

module Simplex.Messaging.Crypto
  ( PrivateKey (..),
    PublicKey (..),
    Signature (..),
    CryptoError (..),
    KeyPair,
    Key (..),
    IV (..),
    KeyHash (..),
    generateKeyPair,
    validKeyPair,
    publicKeySize,
    sign,
    verify,
    encrypt,
    decrypt,
    encryptOAEP,
    decryptOAEP,
    encryptAES,
    decryptAES,
    serializePrivKey,
    serializePubKey,
    serializeKeyHash,
    getKeyHash,
    privKeyP,
    pubKeyP,
    keyHashP,
    authTagSize,
    authTagToBS,
    bsToAuthTag,
    randomAesKey,
    randomIV,
    aesKeyP,
    ivP,
  )
where

import Control.Exception (Exception)
import Control.Monad.Except
import Control.Monad.Trans.Except
import Crypto.Cipher.AES (AES256)
import qualified Crypto.Cipher.Types as AES
import qualified Crypto.Error as CE
import Crypto.Hash (Digest, SHA256 (..), digestFromByteString, hash)
import Crypto.Number.Generate (generateMax)
import Crypto.Number.ModArithmetic (expFast)
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
import Network.Transport.Internal (decodeWord32, encodeWord32)
import Simplex.Messaging.Parsers (base64P, parseAll)
import Simplex.Messaging.Util (bshow, liftEitherError, (<$$>))

newtype PublicKey = PublicKey {rsaPublicKey :: R.PublicKey} deriving (Eq, Show)

data PrivateKey = PrivateKey
  { private_size :: Int,
    private_n :: Integer,
    private_d :: Integer
  }
  deriving (Eq, Show)

instance IsString PrivateKey where
  fromString = parseString privKeyP

instance IsString PublicKey where
  fromString = parseString pubKeyP

parseString :: Parser a -> (String -> a)
parseString parser = either error id . parseAll parser . fromString

instance ToField PrivateKey where toField = toField . serializePrivKey

instance ToField PublicKey where toField = toField . serializePubKey

instance FromField PrivateKey where
  fromField f@(Field (SQLBlob b) _) =
    case parseAll privKeyP b of
      Right k -> Ok k
      Left e -> returnError ConversionFailed f ("couldn't parse PrivateKey field: " ++ e)
  fromField f = returnError ConversionFailed f "expecting SQLBlob column type"

instance FromField PublicKey where
  fromField f@(Field (SQLBlob b) _) =
    case parseAll pubKeyP b of
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
  | CryptoLargeMsgError
  | CryptoHeaderError String
  deriving (Eq, Show, Exception)

pubExpRange :: Integer
pubExpRange = 2 ^ (1024 :: Int)

aesKeySize :: Int
aesKeySize = 256 `div` 8

authTagSize :: Int
authTagSize = 128 `div` 8

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

validKeyPair :: KeyPair -> Bool
validKeyPair
  ( PublicKey R.PublicKey {public_size, public_n = n, public_e = e},
    PrivateKey {private_size, private_n, private_d = d}
    ) =
    let m = 30577
     in public_size == private_size
          && n == private_n
          && m == expFast (expFast m d n) e n

publicKeySize :: PublicKey -> Int
publicKeySize = R.public_size . rsaPublicKey

data Header = Header
  { aesKey :: Key,
    ivBytes :: IV,
    authTag :: AES.AuthTag,
    msgSize :: Int
  }

newtype Key = Key {unKey :: ByteString}

newtype IV = IV {unIV :: ByteString}

newtype KeyHash = KeyHash {unKeyHash :: Digest SHA256} deriving (Eq, Ord, Show)

instance IsString KeyHash where
  fromString = parseString keyHashP

instance ToField KeyHash where toField = toField . serializeKeyHash

instance FromField KeyHash where
  fromField f@(Field (SQLBlob b) _) =
    case parseAll keyHashP b of
      Right k -> Ok k
      Left e -> returnError ConversionFailed f ("couldn't parse KeyHash field: " ++ e)
  fromField f = returnError ConversionFailed f "expecting SQLBlob column type"

serializeKeyHash :: KeyHash -> ByteString
serializeKeyHash = encode . BA.convert . unKeyHash

keyHashP :: Parser KeyHash
keyHashP = do
  bs <- base64P
  case digestFromByteString bs of
    Just d -> pure $ KeyHash d
    _ -> fail "invalid digest"

getKeyHash :: ByteString -> KeyHash
getKeyHash = KeyHash . hash

serializeHeader :: Header -> ByteString
serializeHeader Header {aesKey, ivBytes, authTag, msgSize} =
  unKey aesKey <> unIV ivBytes <> authTagToBS authTag <> (encodeWord32 . fromIntegral) msgSize

headerP :: Parser Header
headerP = do
  aesKey <- aesKeyP
  ivBytes <- ivP
  authTag <- bsToAuthTag <$> A.take authTagSize
  msgSize <- fromIntegral . decodeWord32 <$> A.take 4
  return Header {aesKey, ivBytes, authTag, msgSize}

aesKeyP :: Parser Key
aesKeyP = Key <$> A.take aesKeySize

ivP :: Parser IV
ivP = IV <$> A.take (ivSize @AES256)

parseHeader :: ByteString -> Either CryptoError Header
parseHeader = first CryptoHeaderError . parseAll headerP

encrypt :: PublicKey -> Int -> ByteString -> ExceptT CryptoError IO ByteString
encrypt k paddedSize msg = do
  aesKey <- liftIO randomAesKey
  ivBytes <- liftIO randomIV
  (authTag, msg') <- encryptAES aesKey ivBytes paddedSize msg
  let header = Header {aesKey, ivBytes, authTag, msgSize = B.length msg}
  encHeader <- encryptOAEP k $ serializeHeader header
  return $ encHeader <> msg'

decrypt :: PrivateKey -> ByteString -> ExceptT CryptoError IO ByteString
decrypt pk msg'' = do
  let (encHeader, msg') = B.splitAt (private_size pk) msg''
  header <- decryptOAEP pk encHeader
  Header {aesKey, ivBytes, authTag, msgSize} <- except $ parseHeader header
  msg <- decryptAES aesKey ivBytes msg' authTag
  return $ B.take msgSize msg

encryptAES :: Key -> IV -> Int -> ByteString -> ExceptT CryptoError IO (AES.AuthTag, ByteString)
encryptAES aesKey ivBytes paddedSize msg = do
  aead <- initAEAD @AES256 aesKey ivBytes
  msg' <- paddedMsg
  return $ AES.aeadSimpleEncrypt aead B.empty msg' authTagSize
  where
    len = B.length msg
    paddedMsg
      | len >= paddedSize = throwE CryptoLargeMsgError
      | otherwise = return (msg <> B.replicate (paddedSize - len) '#')

decryptAES :: Key -> IV -> ByteString -> AES.AuthTag -> ExceptT CryptoError IO ByteString
decryptAES aesKey ivBytes msg authTag = do
  aead <- initAEAD @AES256 aesKey ivBytes
  maybeError CryptoDecryptError $ AES.aeadSimpleDecrypt aead B.empty msg authTag

initAEAD :: forall c. AES.BlockCipher c => Key -> IV -> ExceptT CryptoError IO (AES.AEAD c)
initAEAD (Key aesKey) (IV ivBytes) = do
  iv <- makeIV @c ivBytes
  cryptoFailable $ do
    cipher <- AES.cipherInit aesKey
    AES.aeadInit AES.AEAD_GCM cipher iv

randomAesKey :: IO Key
randomAesKey = Key <$> getRandomBytes aesKeySize

randomIV :: IO IV
randomIV = IV <$> getRandomBytes (ivSize @AES256)

ivSize :: forall c. AES.BlockCipher c => Int
ivSize = AES.blockSize (undefined :: c)

makeIV :: AES.BlockCipher c => ByteString -> ExceptT CryptoError IO (AES.IV c)
makeIV bs = maybeError CryptoIVError $ AES.makeIV bs

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

keyParser_ :: Parser (Int, Integer, Integer)
keyParser_ = (,,) <$> (A.decimal <* ",") <*> (intP <* ",") <*> intP
  where
    intP = os2ip <$> base64P

rsaPrivateKey :: PrivateKey -> R.PrivateKey
rsaPrivateKey pk =
  R.PrivateKey
    { private_pub =
        R.PublicKey
          { public_size = private_size pk,
            public_n = private_n pk,
            public_e = undefined
          },
      private_d = private_d pk,
      private_p = 0,
      private_q = 0,
      private_dP = undefined,
      private_dQ = undefined,
      private_qinv = undefined
    }
