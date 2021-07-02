{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

-- |
-- Module      : Simplex.Messaging.Crypto
-- Copyright   : (c) simplex.chat
-- License     : AGPL-3
--
-- Maintainer  : chat@simplex.chat
-- Stability   : experimental
-- Portability : non-portable
--
-- This module provides cryptography implementation for SMP protocols based on
-- <https://hackage.haskell.org/package/cryptonite cryptonite package>.
module Simplex.Messaging.Crypto
  ( -- * RSA keys
    PrivateKey (rsaPrivateKey, publicKey),
    SafePrivateKey, -- constructor is not exported
    FullPrivateKey (..),
    APrivateKey,
    PublicKey (..),
    SafeKeyPair,
    FullKeyPair,
    KeyHash (..),
    generateKeyPair,
    publicKey',
    publicKeySize,
    validKeySize,
    safePrivateKey,
    removePublicKey,

    -- * E2E hybrid encryption scheme
    encrypt,
    decrypt,

    -- * RSA OAEP encryption
    encryptOAEP,
    decryptOAEP,

    -- * RSA PSS signing
    Signature (..),
    sign,
    verify,

    -- * AES256 AEAD-GCM scheme
    Key (..),
    IV (..),
    encryptAES,
    decryptAES,
    authTagSize,
    authTagToBS,
    bsToAuthTag,
    randomAesKey,
    randomIV,
    aesKeyP,
    ivP,

    -- * Encoding of RSA keys
    serializePrivKey,
    serializePubKey,
    encodePubKey,
    publicKeyHash,
    privKeyP,
    pubKeyP,
    binaryPubKeyP,

    -- * SHA256 hash
    sha256Hash,

    -- * Cryptography error type
    CryptoError (..),
  )
where

import Control.Exception (Exception)
import Control.Monad.Except
import Control.Monad.Trans.Except
import Crypto.Cipher.AES (AES256)
import qualified Crypto.Cipher.Types as AES
import qualified Crypto.Error as CE
import Crypto.Hash (Digest, SHA256 (..), hash)
import Crypto.Number.Generate (generateMax)
import Crypto.Number.Prime (findPrimeFrom)
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
import Data.ByteString.Base64 (decode, encode)
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.ByteString.Internal (c2w, w2c)
import Data.ByteString.Lazy (fromStrict, toStrict)
import Data.String
import Data.X509
import Database.SQLite.Simple.FromField (FromField (..))
import Database.SQLite.Simple.ToField (ToField (..))
import Network.Transport.Internal (decodeWord32, encodeWord32)
import Simplex.Messaging.Parsers (base64P, blobFieldParser, parseAll, parseString)
import Simplex.Messaging.Util (liftEitherError, (<$?>))

-- | A newtype of 'Crypto.PubKey.RSA.PublicKey'.
newtype PublicKey = PublicKey {rsaPublicKey :: R.PublicKey} deriving (Eq, Show)

-- | A newtype of 'Crypto.PubKey.RSA.PrivateKey', with PublicKey removed.
--
-- It is not possible to recover PublicKey from SafePrivateKey.
-- The constructor of this type is not exported.
newtype SafePrivateKey = SafePrivateKey {unPrivateKey :: R.PrivateKey} deriving (Eq, Show)

-- | A newtype of 'Crypto.PubKey.RSA.PrivateKey' (with PublicKey inside).
newtype FullPrivateKey = FullPrivateKey {unPrivateKey :: R.PrivateKey} deriving (Eq, Show)

-- | A newtype of 'Crypto.PubKey.RSA.PrivateKey' (PublicKey may be inside).
newtype APrivateKey = APrivateKey {unPrivateKey :: R.PrivateKey} deriving (Eq, Show)

-- | Type-class used for both private key types: SafePrivateKey and FullPrivateKey.
class PrivateKey k where
  -- unwraps 'Crypto.PubKey.RSA.PrivateKey'
  rsaPrivateKey :: k -> R.PrivateKey

  -- equivalent to data type constructor, not exported
  _privateKey :: R.PrivateKey -> k

  -- smart constructor removing public key from SafePrivateKey but keeping it in FullPrivateKey
  mkPrivateKey :: R.PrivateKey -> k

  -- extracts public key from private key
  publicKey :: k -> Maybe PublicKey

removePublicKey :: APrivateKey -> APrivateKey
removePublicKey (APrivateKey R.PrivateKey {private_pub = k, private_d}) =
  APrivateKey $ unPrivateKey (safePrivateKey (R.public_size k, R.public_n k, private_d) :: SafePrivateKey)

instance PrivateKey SafePrivateKey where
  rsaPrivateKey = unPrivateKey
  _privateKey = SafePrivateKey
  mkPrivateKey R.PrivateKey {private_pub = k, private_d} =
    safePrivateKey (R.public_size k, R.public_n k, private_d)
  publicKey _ = Nothing

instance PrivateKey FullPrivateKey where
  rsaPrivateKey = unPrivateKey
  _privateKey = FullPrivateKey
  mkPrivateKey = FullPrivateKey
  publicKey = Just . PublicKey . R.private_pub . rsaPrivateKey

instance PrivateKey APrivateKey where
  rsaPrivateKey = unPrivateKey
  _privateKey = APrivateKey
  mkPrivateKey = APrivateKey
  publicKey pk =
    let k = R.private_pub $ rsaPrivateKey pk
     in if R.public_e k == 0
          then Nothing
          else Just $ PublicKey k

instance IsString FullPrivateKey where
  fromString = parseString (decode >=> decodePrivKey)

instance IsString PublicKey where
  fromString = parseString (decode >=> decodePubKey)

instance ToField SafePrivateKey where toField = toField . encodePrivKey

instance ToField APrivateKey where toField = toField . encodePrivKey

instance ToField PublicKey where toField = toField . encodePubKey

instance FromField SafePrivateKey where fromField = blobFieldParser binaryPrivKeyP

instance FromField APrivateKey where fromField = blobFieldParser binaryPrivKeyP

instance FromField PublicKey where fromField = blobFieldParser binaryPubKeyP

-- | Tuple of RSA 'PublicKey' and 'PrivateKey'.
type KeyPair k = (PublicKey, k)

-- | Tuple of RSA 'PublicKey' and 'SafePrivateKey'.
type SafeKeyPair = (PublicKey, SafePrivateKey)

-- | Tuple of RSA 'PublicKey' and 'FullPrivateKey'.
type FullKeyPair = (PublicKey, FullPrivateKey)

-- | RSA signature newtype.
newtype Signature = Signature {unSignature :: ByteString} deriving (Eq, Show)

instance IsString Signature where
  fromString = Signature . fromString

-- | Various cryptographic or related errors.
data CryptoError
  = -- | RSA OAEP encryption error
    RSAEncryptError R.Error
  | -- | RSA OAEP decryption error
    RSADecryptError R.Error
  | -- | RSA PSS signature error
    RSASignError R.Error
  | -- | AES initialization error
    AESCipherError CE.CryptoError
  | -- | IV generation error
    CryptoIVError
  | -- | AES decryption error
    AESDecryptError
  | -- | message does not fit in SMP block
    CryptoLargeMsgError
  | -- | failure parsing RSA-encrypted message header
    CryptoHeaderError String
  deriving (Eq, Show, Exception)

pubExpRange :: Integer
pubExpRange = 2 ^ (1024 :: Int)

aesKeySize :: Int
aesKeySize = 256 `div` 8

authTagSize :: Int
authTagSize = 128 `div` 8

-- | Generate RSA key pair with either SafePrivateKey or FullPrivateKey.
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

publicKey' :: FullPrivateKey -> PublicKey
publicKey' = PublicKey . R.private_pub . rsaPrivateKey

publicKeySize :: PublicKey -> Int
publicKeySize = R.public_size . rsaPublicKey

validKeySize :: Int -> Bool
validKeySize = \case
  128 -> True
  256 -> True
  512 -> True
  _ -> False

data Header = Header
  { aesKey :: Key,
    ivBytes :: IV,
    authTag :: AES.AuthTag,
    msgSize :: Int
  }

-- | AES key newtype.
newtype Key = Key {unKey :: ByteString}

-- | IV bytes newtype.
newtype IV = IV {unIV :: ByteString}

-- | Key hash newtype.
newtype KeyHash = KeyHash {unKeyHash :: ByteString} deriving (Eq, Ord, Show)

instance IsString KeyHash where
  fromString = parseString . parseAll $ KeyHash <$> base64P

instance ToField KeyHash where toField = toField . encode . unKeyHash

instance FromField KeyHash where fromField = blobFieldParser $ KeyHash <$> base64P

-- | Digest (hash) of binary X509 encoding of RSA public key.
publicKeyHash :: PublicKey -> KeyHash
publicKeyHash = KeyHash . sha256Hash . encodePubKey

-- | SHA256 digest.
sha256Hash :: ByteString -> ByteString
sha256Hash = BA.convert . (hash :: ByteString -> Digest SHA256)

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

-- | AES256 key parser.
aesKeyP :: Parser Key
aesKeyP = Key <$> A.take aesKeySize

-- | IV bytes parser.
ivP :: Parser IV
ivP = IV <$> A.take (ivSize @AES256)

parseHeader :: ByteString -> Either CryptoError Header
parseHeader = first CryptoHeaderError . parseAll headerP

-- * E2E hybrid encryption scheme

-- | E2E encrypt SMP agent messages.
--
-- https://github.com/simplex-chat/simplexmq/blob/master/rfcs/2021-01-26-crypto.md#e2e-encryption
encrypt :: PublicKey -> Int -> ByteString -> ExceptT CryptoError IO ByteString
encrypt k paddedSize msg = do
  aesKey <- liftIO randomAesKey
  ivBytes <- liftIO randomIV
  (authTag, msg') <- encryptAES aesKey ivBytes paddedSize msg
  let header = Header {aesKey, ivBytes, authTag, msgSize = B.length msg}
  encHeader <- encryptOAEP k $ serializeHeader header
  return $ encHeader <> msg'

-- | E2E decrypt SMP agent messages.
--
-- https://github.com/simplex-chat/simplexmq/blob/master/rfcs/2021-01-26-crypto.md#e2e-encryption
decrypt :: PrivateKey k => k -> ByteString -> ExceptT CryptoError IO ByteString
decrypt pk msg'' = do
  let (encHeader, msg') = B.splitAt (privateKeySize pk) msg''
  header <- decryptOAEP pk encHeader
  Header {aesKey, ivBytes, authTag, msgSize} <- except $ parseHeader header
  msg <- decryptAES aesKey ivBytes msg' authTag
  return $ B.take msgSize msg

-- | AEAD-GCM encryption.
--
-- Used as part of hybrid E2E encryption scheme and for SMP transport blocks encryption.
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

-- | AEAD-GCM decryption.
--
-- Used as part of hybrid E2E encryption scheme and for SMP transport blocks decryption.
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

-- | Random AES256 key.
randomAesKey :: IO Key
randomAesKey = Key <$> getRandomBytes aesKeySize

-- | Random IV bytes for AES256 encryption.
randomIV :: IO IV
randomIV = IV <$> getRandomBytes (ivSize @AES256)

ivSize :: forall c. AES.BlockCipher c => Int
ivSize = AES.blockSize (undefined :: c)

makeIV :: AES.BlockCipher c => ByteString -> ExceptT CryptoError IO (AES.IV c)
makeIV bs = maybeError CryptoIVError $ AES.makeIV bs

maybeError :: CryptoError -> Maybe a -> ExceptT CryptoError IO a
maybeError e = maybe (throwE e) return

-- | Convert AEAD 'AuthTag' to ByteString.
authTagToBS :: AES.AuthTag -> ByteString
authTagToBS = B.pack . map w2c . BA.unpack . AES.unAuthTag

-- | Convert ByteString to AEAD 'AuthTag'.
bsToAuthTag :: ByteString -> AES.AuthTag
bsToAuthTag = AES.AuthTag . BA.pack . map c2w . B.unpack

cryptoFailable :: CE.CryptoFailable a -> ExceptT CryptoError IO a
cryptoFailable = liftEither . first AESCipherError . CE.eitherCryptoError

oaepParams :: OAEP.OAEPParams SHA256 ByteString ByteString
oaepParams = OAEP.defaultOAEPParams SHA256

-- | RSA OAEP encryption.
--
-- Used as part of hybrid E2E encryption scheme and for SMP transport handshake.
encryptOAEP :: PublicKey -> ByteString -> ExceptT CryptoError IO ByteString
encryptOAEP (PublicKey k) aesKey =
  liftEitherError RSAEncryptError $
    OAEP.encrypt oaepParams k aesKey

-- | RSA OAEP decryption.
--
-- Used as part of hybrid E2E encryption scheme and for SMP transport handshake.
decryptOAEP :: PrivateKey k => k -> ByteString -> ExceptT CryptoError IO ByteString
decryptOAEP pk encKey =
  liftEitherError RSADecryptError $
    OAEP.decryptSafer oaepParams (rsaPrivateKey pk) encKey

pssParams :: PSS.PSSParams SHA256 ByteString ByteString
pssParams = PSS.defaultPSSParams SHA256

-- | RSA PSS message signing.
--
-- Used by SMP clients to sign SMP commands and by SMP agents to sign messages.
sign :: PrivateKey k => k -> ByteString -> ExceptT CryptoError IO Signature
sign pk msg = ExceptT $ bimap RSASignError Signature <$> PSS.signSafer pssParams (rsaPrivateKey pk) msg

-- | RSA PSS signature verification.
--
-- Used by SMP servers to authorize SMP commands and by SMP agents to verify messages.
verify :: PublicKey -> Signature -> ByteString -> Bool
verify (PublicKey k) (Signature sig) msg = PSS.verify pssParams k msg sig

-- | Base-64 X509 encoding of RSA public key.
--
-- Used as part of SMP queue information (out-of-band message).
serializePubKey :: PublicKey -> ByteString
serializePubKey = ("rsa:" <>) . encode . encodePubKey

-- | Base-64 PKCS8 encoding of PSA private key.
--
-- Not used as part of SMP protocols.
serializePrivKey :: PrivateKey k => k -> ByteString
serializePrivKey = ("rsa:" <>) . encode . encodePrivKey

-- Base-64 X509 RSA public key parser.
pubKeyP :: Parser PublicKey
pubKeyP = decodePubKey <$?> ("rsa:" *> base64P)

-- Binary X509 RSA public key parser.
binaryPubKeyP :: Parser PublicKey
binaryPubKeyP = decodePubKey <$?> A.takeByteString

-- Base-64 PKCS8 RSA private key parser.
privKeyP :: PrivateKey k => Parser k
privKeyP = decodePrivKey <$?> ("rsa:" *> base64P)

-- Binary PKCS8 RSA private key parser.
binaryPrivKeyP :: PrivateKey k => Parser k
binaryPrivKeyP = decodePrivKey <$?> A.takeByteString

-- | Construct 'SafePrivateKey' from three numbers - used internally and in the tests.
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

-- Binary X509 encoding of 'PublicKey'.
encodePubKey :: PublicKey -> ByteString
encodePubKey = encodeKey . PubKeyRSA . rsaPublicKey

-- Binary PKCS8 encoding of 'PrivateKey'.
encodePrivKey :: PrivateKey k => k -> ByteString
encodePrivKey = encodeKey . PrivKeyRSA . rsaPrivateKey

encodeKey :: ASN1Object a => a -> ByteString
encodeKey k = toStrict . encodeASN1 DER $ toASN1 k []

-- Decoding of binary X509 'PublicKey'.
decodePubKey :: ByteString -> Either String PublicKey
decodePubKey =
  decodeKey >=> \case
    (PubKeyRSA k, []) -> Right $ PublicKey k
    r -> keyError r

-- Decoding of binary PKCS8 'PrivateKey'.
decodePrivKey :: PrivateKey k => ByteString -> Either String k
decodePrivKey =
  decodeKey >=> \case
    (PrivKeyRSA pk, []) -> Right $ mkPrivateKey pk
    r -> keyError r

decodeKey :: ASN1Object a => ByteString -> Either String (a, [ASN1])
decodeKey = fromASN1 <=< first show . decodeASN1 DER . fromStrict

keyError :: (a, [ASN1]) -> Either String b
keyError = \case
  (_, []) -> Left "not RSA key"
  _ -> Left "more than one key"
