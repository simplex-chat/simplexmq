{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

module Simplex.Messaging.Crypto
  ( PrivateKey (rsaPrivateKey),
    SafePrivateKey, -- constructor is not exported
    FullPrivateKey (..),
    PublicKey (..),
    Signature (..),
    CryptoError (..),
    SafeKeyPair,
    FullKeyPair,
    Key (..),
    IV (..),
    KeyHash (..),
    generateKeyPair,
    publicKey,
    publicKeySize,
    safePrivateKey,
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
    binaryEncodePubKey,
    serializeKeyHash,
    getKeyHash,
    privKeyP,
    pubKeyP,
    binaryPubKeyP,
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

import Control.Applicative ((<|>))
import Control.Exception (Exception)
import Control.Monad.Except
import Control.Monad.Trans.Except
import Crypto.Cipher.AES (AES256)
import qualified Crypto.Cipher.Types as AES
import qualified Crypto.Error as CE
import Crypto.Hash (Digest, SHA256 (..), digestFromByteString, hash)
import Crypto.Number.Generate (generateMax)
import Crypto.Number.Prime (findPrimeFrom)
import Crypto.Number.Serialize (os2ip)
import qualified Crypto.PubKey.RSA as R
import qualified Crypto.PubKey.RSA.OAEP as OAEP
import qualified Crypto.PubKey.RSA.PSS as PSS
import Crypto.Random (getRandomBytes)
import Data.ASN1.BinaryEncoding
import Data.ASN1.Encoding
import Data.ASN1.Types
import Data.Attoparsec.ByteString.Char8 (Parser)
import qualified Data.Attoparsec.ByteString.Char8 as A
import Data.Bifunctor (bimap, first)
import qualified Data.ByteArray as BA
import Data.ByteString.Base64
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.ByteString.Internal (c2w, w2c)
import Data.ByteString.Lazy (fromStrict, toStrict)
import Data.String
import Data.Typeable (Typeable)
import Data.X509
import Database.SQLite.Simple as DB
import Database.SQLite.Simple.FromField
import Database.SQLite.Simple.Internal (Field (..))
import Database.SQLite.Simple.Ok (Ok (Ok))
import Database.SQLite.Simple.ToField (ToField (..))
import Network.Transport.Internal (decodeWord32, encodeWord32)
import Simplex.Messaging.Parsers (base64P, base64StringP, parseAll)
import Simplex.Messaging.Util (liftEitherError)

newtype PublicKey = PublicKey {rsaPublicKey :: R.PublicKey} deriving (Eq, Show)

newtype SafePrivateKey = SafePrivateKey {unPrivateKey :: R.PrivateKey} deriving (Eq, Show)

newtype FullPrivateKey = FullPrivateKey {unPrivateKey :: R.PrivateKey} deriving (Eq, Show)

class PrivateKey k where
  rsaPrivateKey :: k -> R.PrivateKey
  _privateKey :: R.PrivateKey -> k
  mkPrivateKey :: R.PrivateKey -> k

instance PrivateKey SafePrivateKey where
  rsaPrivateKey = unPrivateKey
  _privateKey = SafePrivateKey
  mkPrivateKey R.PrivateKey {private_pub = k, private_d} =
    safePrivateKey (R.public_size k, R.public_n k, private_d)

instance PrivateKey FullPrivateKey where
  rsaPrivateKey = unPrivateKey
  _privateKey = FullPrivateKey
  mkPrivateKey = FullPrivateKey

instance IsString FullPrivateKey where
  fromString = parseString decodePrivKey

instance IsString PublicKey where
  fromString = parseString decodePubKey

parseString :: (ByteString -> Either String a) -> (String -> a)
parseString parse = either error id . parse . B.pack

instance ToField SafePrivateKey where toField = toField . serializePrivKey

instance ToField PublicKey where toField = toField . serializePubKey

instance FromField SafePrivateKey where fromField = keyFromField privKeyP

instance FromField PublicKey where fromField = keyFromField pubKeyP

keyFromField :: Typeable k => Parser k -> FieldParser k
keyFromField p = \case
  f@(Field (SQLBlob b) _) ->
    case parseAll p b of
      Right k -> Ok k
      Left e -> returnError ConversionFailed f ("couldn't parse key field: " ++ e)
  f -> returnError ConversionFailed f "expecting SQLBlob column type"

type KeyPair k = (PublicKey, k)

type SafeKeyPair = (PublicKey, SafePrivateKey)

type FullKeyPair = (PublicKey, FullPrivateKey)

newtype Signature = Signature {unSignature :: ByteString} deriving (Eq, Show)

instance IsString Signature where
  fromString = Signature . fromString

newtype Verified = Verified ByteString deriving (Show)

data CryptoError
  = RSAEncryptError R.Error
  | RSADecryptError R.Error
  | RSASignError R.Error
  | AESCipherError CE.CryptoError
  | CryptoIVError
  | AESDecryptError
  | CryptoLargeMsgError
  | CryptoHeaderError String
  deriving (Eq, Show, Exception)

pubExpRange :: Integer
pubExpRange = 2 ^ (1024 :: Int)

aesKeySize :: Int
aesKeySize = 256 `div` 8

authTagSize :: Int
authTagSize = 128 `div` 8

generateKeyPair :: PrivateKey k => Int -> IO (KeyPair k)
generateKeyPair size = loop
  where
    publicExponent = findPrimeFrom . (+ 3) <$> generateMax pubExpRange
    loop = do
      (k, pk) <- R.generate size =<< publicExponent
      let n = R.public_n k
          d = R.private_d pk
      if d * d < n
        then loop
        else pure (PublicKey k, mkPrivateKey pk)

privateKeySize :: PrivateKey k => k -> Int
privateKeySize = R.public_size . R.private_pub . rsaPrivateKey

publicKey :: FullPrivateKey -> PublicKey
publicKey = PublicKey . R.private_pub . rsaPrivateKey

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
  fromString = parseString $ parseAll keyHashP

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

decrypt :: PrivateKey k => k -> ByteString -> ExceptT CryptoError IO ByteString
decrypt pk msg'' = do
  let (encHeader, msg') = B.splitAt (privateKeySize pk) msg''
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
  maybeError AESDecryptError $ AES.aeadSimpleDecrypt aead B.empty msg authTag

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
cryptoFailable = liftEither . first AESCipherError . CE.eitherCryptoError

oaepParams :: OAEP.OAEPParams SHA256 ByteString ByteString
oaepParams = OAEP.defaultOAEPParams SHA256

encryptOAEP :: PublicKey -> ByteString -> ExceptT CryptoError IO ByteString
encryptOAEP (PublicKey k) aesKey =
  liftEitherError RSAEncryptError $
    OAEP.encrypt oaepParams k aesKey

decryptOAEP :: PrivateKey k => k -> ByteString -> ExceptT CryptoError IO ByteString
decryptOAEP pk encKey =
  liftEitherError RSADecryptError $
    OAEP.decryptSafer oaepParams (rsaPrivateKey pk) encKey

pssParams :: PSS.PSSParams SHA256 ByteString ByteString
pssParams = PSS.defaultPSSParams SHA256

sign :: PrivateKey k => k -> ByteString -> IO (Either CryptoError Signature)
sign pk msg = bimap RSASignError Signature <$> PSS.signSafer pssParams (rsaPrivateKey pk) msg

verify :: PublicKey -> Signature -> ByteString -> Bool
verify (PublicKey k) (Signature sig) msg = PSS.verify pssParams k msg sig

serializePubKey :: PublicKey -> ByteString
serializePubKey k = "rsa:" <> encodePubKey k

serializePrivKey :: PrivateKey k => k -> ByteString
serializePrivKey pk = "rsa:" <> encodePrivKey pk

pubKeyP :: Parser PublicKey
pubKeyP = keyP decodePubKey <|> legacyPubKeyP

binaryPubKeyP :: Parser PublicKey
binaryPubKeyP = either fail pure . binaryDecodePubKey =<< A.takeByteString

privKeyP :: PrivateKey k => Parser k
privKeyP = keyP decodePrivKey <|> legacyPrivKeyP

keyP :: (ByteString -> Either String k) -> Parser k
keyP dec = either fail pure . dec =<< ("rsa:" *> base64StringP)

legacyPubKeyP :: Parser PublicKey
legacyPubKeyP = do
  (public_size, public_n, public_e) <- legacyKeyParser_
  return . PublicKey $ R.PublicKey {public_size, public_n, public_e}

legacyPrivKeyP :: PrivateKey k => Parser k
legacyPrivKeyP = _privateKey . safeRsaPrivateKey <$> legacyKeyParser_

legacyKeyParser_ :: Parser (Int, Integer, Integer)
legacyKeyParser_ = (,,) <$> (A.decimal <* ",") <*> (intP <* ",") <*> intP
  where
    intP = os2ip <$> base64P

safePrivateKey :: (Int, Integer, Integer) -> SafePrivateKey
safePrivateKey = SafePrivateKey . safeRsaPrivateKey

safeRsaPrivateKey :: (Int, Integer, Integer) -> R.PrivateKey
safeRsaPrivateKey (size, n, d) =
  R.PrivateKey
    { private_pub =
        R.PublicKey
          { public_size = size,
            public_n = n,
            public_e = 0
          },
      private_d = d,
      private_p = 0,
      private_q = 0,
      private_dP = 0,
      private_dQ = 0,
      private_qinv = 0
    }

encodePubKey :: PublicKey -> ByteString
encodePubKey = encode . binaryEncodePubKey

binaryEncodePubKey :: PublicKey -> ByteString
binaryEncodePubKey = binaryEncodeKey . PubKeyRSA . rsaPublicKey

encodePrivKey :: PrivateKey k => k -> ByteString
encodePrivKey = encode . binaryEncodeKey . PrivKeyRSA . rsaPrivateKey

binaryEncodeKey :: ASN1Object a => a -> ByteString
binaryEncodeKey k = toStrict . encodeASN1 DER $ toASN1 k []

decodePubKey :: ByteString -> Either String PublicKey
decodePubKey = binaryDecodePubKey <=< decode

binaryDecodePubKey :: ByteString -> Either String PublicKey
binaryDecodePubKey =
  binaryDecodeKey >=> \case
    (PubKeyRSA k, []) -> Right $ PublicKey k
    r -> keyError r

decodePrivKey :: PrivateKey k => ByteString -> Either String k
decodePrivKey =
  decode >=> binaryDecodeKey >=> \case
    (PrivKeyRSA pk, []) -> Right $ mkPrivateKey pk
    r -> keyError r

binaryDecodeKey :: ASN1Object a => ByteString -> Either String (a, [ASN1])
binaryDecodeKey = fromASN1 <=< first show . decodeASN1 DER . fromStrict

keyError :: (a, [ASN1]) -> Either String b
keyError = \case
  (_, []) -> Left "not RSA key"
  _ -> Left "more than one key"
