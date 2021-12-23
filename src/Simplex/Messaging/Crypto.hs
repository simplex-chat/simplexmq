{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}
{-# OPTIONS_GHC -fno-warn-unticked-promoted-constructors #-}

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
  ( -- * Cryptographic keys
    Algorithm (..),
    SAlgorithm (..),
    Alg (..),
    SignAlg (..),
    DhAlgorithm,
    PrivateKey (..),
    PublicKey (..),
    APrivateKey (..),
    APublicKey (..),
    APrivateSignKey (..),
    APublicVerifyKey (..),
    APrivateDecryptKey (..),
    APublicEncryptKey (..),
    CryptoKey (..),
    CryptoPrivateKey (..),
    KeyPair,
    DhSecret (..),
    ADhSecret (..),
    CryptoDhSecret (..),
    KeyHash (..),
    generateKeyPair,
    generateKeyPair',
    generateSignatureKeyPair,
    generateEncryptionKeyPair,
    privateToX509,

    -- * E2E hybrid encryption scheme
    E2EEncryptionVersion,
    currentE2EVersion,
    encrypt,
    encrypt',
    decrypt,
    decrypt',

    -- * RSA OAEP encryption
    encryptOAEP,
    decryptOAEP,

    -- * sign/verify
    Signature (..),
    ASignature (..),
    CryptoSignature (..),
    SignatureSize (..),
    SignatureAlgorithm,
    AlgorithmI (..),
    sign,
    verify,
    verify',
    validSignatureSize,

    -- * DH derivation
    dh',
    dhSecret,
    dhSecret',

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
    ivSize,

    -- * NaCl crypto_box
    cbEncrypt,
    cbDecrypt,
    cbNonce,

    -- * Encoding of RSA keys
    publicKeyHash,

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
import qualified Crypto.Cipher.XSalsa as XSalsa
import qualified Crypto.Error as CE
import Crypto.Hash (Digest, SHA256 (..), hash)
import qualified Crypto.MAC.Poly1305 as Poly1305
import Crypto.Number.Generate (generateMax)
import Crypto.Number.Prime (findPrimeFrom)
import qualified Crypto.PubKey.Curve25519 as X25519
import qualified Crypto.PubKey.Curve448 as X448
import qualified Crypto.PubKey.Ed25519 as Ed25519
import qualified Crypto.PubKey.Ed448 as Ed448
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
import qualified Data.ByteString.Base64.URL as U
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.ByteString.Internal (c2w, w2c)
import Data.ByteString.Lazy (fromStrict, toStrict)
import Data.Constraint (Dict (..))
import Data.Kind (Constraint, Type)
import Data.String
import Data.Type.Equality
import Data.Typeable (Typeable)
import Data.Word (Word16)
import Data.X509
import Database.SQLite.Simple.FromField (FromField (..))
import Database.SQLite.Simple.ToField (ToField (..))
import GHC.TypeLits (ErrorMessage (..), TypeError)
import Network.Transport.Internal (decodeWord32, encodeWord32)
import Simplex.Messaging.Parsers (base64P, base64UriP, blobFieldParser, parseAll, parseE, parseString)
import Simplex.Messaging.Util (liftEitherError, (<$?>))

type E2EEncryptionVersion = Word16

currentE2EVersion :: E2EEncryptionVersion
currentE2EVersion = 1

-- | Cryptographic algorithms.
data Algorithm = RSA | Ed25519 | Ed448 | X25519 | X448

-- | Singleton types for 'Algorithm'.
data SAlgorithm :: Algorithm -> Type where
  SRSA :: SAlgorithm RSA
  SEd25519 :: SAlgorithm Ed25519
  SEd448 :: SAlgorithm Ed448
  SX25519 :: SAlgorithm X25519
  SX448 :: SAlgorithm X448

deriving instance Eq (SAlgorithm a)

deriving instance Show (SAlgorithm a)

data Alg = forall a. AlgorithmI a => Alg (SAlgorithm a)

data SignAlg
  = forall a.
    (AlgorithmI a, SignatureAlgorithm a) =>
    SignAlg (SAlgorithm a)

class AlgorithmI (a :: Algorithm) where sAlgorithm :: SAlgorithm a

instance AlgorithmI RSA where sAlgorithm = SRSA

instance AlgorithmI Ed25519 where sAlgorithm = SEd25519

instance AlgorithmI Ed448 where sAlgorithm = SEd448

instance AlgorithmI X25519 where sAlgorithm = SX25519

instance AlgorithmI X448 where sAlgorithm = SX448

instance TestEquality SAlgorithm where
  testEquality SRSA SRSA = Just Refl
  testEquality SEd25519 SEd25519 = Just Refl
  testEquality SEd448 SEd448 = Just Refl
  testEquality SX25519 SX25519 = Just Refl
  testEquality SX448 SX448 = Just Refl
  testEquality _ _ = Nothing

-- | GADT for public keys.
data PublicKey (a :: Algorithm) where
  PublicKeyRSA :: R.PublicKey -> PublicKey RSA
  PublicKeyEd25519 :: Ed25519.PublicKey -> PublicKey Ed25519
  PublicKeyEd448 :: Ed448.PublicKey -> PublicKey Ed448
  PublicKeyX25519 :: X25519.PublicKey -> PublicKey X25519
  PublicKeyX448 :: X448.PublicKey -> PublicKey X448

deriving instance Eq (PublicKey a)

deriving instance Show (PublicKey a)

data APublicKey
  = forall a.
    AlgorithmI a =>
    APublicKey (SAlgorithm a) (PublicKey a)

instance Eq APublicKey where
  APublicKey a k == APublicKey a' k' = case testEquality a a' of
    Just Refl -> k == k'
    Nothing -> False

deriving instance Show APublicKey

-- | GADT for private keys.
data PrivateKey (a :: Algorithm) where
  PrivateKeyRSA :: {privateKeyRSA :: R.PrivateKey} -> PrivateKey RSA
  PrivateKeyEd25519 :: Ed25519.SecretKey -> Ed25519.PublicKey -> PrivateKey Ed25519
  PrivateKeyEd448 :: Ed448.SecretKey -> Ed448.PublicKey -> PrivateKey Ed448
  PrivateKeyX25519 :: X25519.SecretKey -> PrivateKey X25519
  PrivateKeyX448 :: X448.SecretKey -> PrivateKey X448

deriving instance Eq (PrivateKey a)

deriving instance Show (PrivateKey a)

data APrivateKey
  = forall a.
    AlgorithmI a =>
    APrivateKey (SAlgorithm a) (PrivateKey a)

instance Eq APrivateKey where
  APrivateKey a k == APrivateKey a' k' = case testEquality a a' of
    Just Refl -> k == k'
    Nothing -> False

deriving instance Show APrivateKey

class AlgorithmPrefix k where
  algorithmPrefix :: k -> ByteString

instance AlgorithmPrefix (SAlgorithm a) where
  algorithmPrefix = \case
    SRSA -> "rsa"
    SEd25519 -> "ed25519"
    SEd448 -> "ed448"
    SX25519 -> "x25519"
    SX448 -> "x448"

instance AlgorithmI a => AlgorithmPrefix (PublicKey a) where
  algorithmPrefix _ = algorithmPrefix $ sAlgorithm @a

instance AlgorithmI a => AlgorithmPrefix (PrivateKey a) where
  algorithmPrefix _ = algorithmPrefix $ sAlgorithm @a

instance AlgorithmPrefix APublicKey where
  algorithmPrefix (APublicKey a _) = algorithmPrefix a

instance AlgorithmPrefix APrivateKey where
  algorithmPrefix (APrivateKey a _) = algorithmPrefix a

prefixAlgorithm :: ByteString -> Either String Alg
prefixAlgorithm = \case
  "rsa" -> Right $ Alg SRSA
  "ed25519" -> Right $ Alg SEd25519
  "ed448" -> Right $ Alg SEd448
  "x25519" -> Right $ Alg SX25519
  "x448" -> Right $ Alg SX448
  _ -> Left "unknown algorithm"

algP :: Parser Alg
algP = prefixAlgorithm <$?> A.takeTill (== ':')

type family SignatureAlgorithm (a :: Algorithm) :: Constraint where
  SignatureAlgorithm RSA = ()
  SignatureAlgorithm Ed25519 = ()
  SignatureAlgorithm Ed448 = ()
  SignatureAlgorithm a =
    (Int ~ Bool, TypeError (Text "Algorithm " :<>: ShowType a :<>: Text " cannot be used to sign/verify"))

signatureAlgorithm :: SAlgorithm a -> Maybe (Dict (SignatureAlgorithm a))
signatureAlgorithm = \case
  SRSA -> Just Dict
  SEd25519 -> Just Dict
  SEd448 -> Just Dict
  _ -> Nothing

data APrivateSignKey
  = forall a.
    (AlgorithmI a, SignatureAlgorithm a) =>
    APrivateSignKey (SAlgorithm a) (PrivateKey a)

instance Eq APrivateSignKey where
  APrivateSignKey a k == APrivateSignKey a' k' = case testEquality a a' of
    Just Refl -> k == k'
    Nothing -> False

deriving instance Show APrivateSignKey

data APublicVerifyKey
  = forall a.
    (AlgorithmI a, SignatureAlgorithm a) =>
    APublicVerifyKey (SAlgorithm a) (PublicKey a)

instance Eq APublicVerifyKey where
  APublicVerifyKey a k == APublicVerifyKey a' k' = case testEquality a a' of
    Just Refl -> k == k'
    Nothing -> False

deriving instance Show APublicVerifyKey

type family EncryptionAlgorithm (a :: Algorithm) :: Constraint where
  EncryptionAlgorithm RSA = ()
  EncryptionAlgorithm a =
    (Int ~ Bool, TypeError (Text "Algorithm " :<>: ShowType a :<>: Text " cannot be used to encrypt/decrypt"))

encryptionAlgorithm :: SAlgorithm a -> Maybe (Dict (EncryptionAlgorithm a))
encryptionAlgorithm = \case
  SRSA -> Just Dict
  _ -> Nothing

data APrivateDecryptKey
  = forall a.
    (AlgorithmI a, EncryptionAlgorithm a) =>
    APrivateDecryptKey (SAlgorithm a) (PrivateKey a)

instance Eq APrivateDecryptKey where
  APrivateDecryptKey a k == APrivateDecryptKey a' k' = case testEquality a a' of
    Just Refl -> k == k'
    Nothing -> False

deriving instance Show APrivateDecryptKey

data APublicEncryptKey
  = forall a.
    (AlgorithmI a, EncryptionAlgorithm a) =>
    APublicEncryptKey (SAlgorithm a) (PublicKey a)

instance Eq APublicEncryptKey where
  APublicEncryptKey a k == APublicEncryptKey a' k' = case testEquality a a' of
    Just Refl -> k == k'
    Nothing -> False

deriving instance Show APublicEncryptKey

data DhSecret (a :: Algorithm) where
  DhSecretX25519 :: X25519.DhSecret -> DhSecret X25519
  DhSecretX448 :: X448.DhSecret -> DhSecret X448

deriving instance Eq (DhSecret a)

deriving instance Show (DhSecret a)

data ADhSecret
  = forall a.
    (AlgorithmI a, DhAlgorithm a) =>
    ADhSecret (SAlgorithm a) (DhSecret a)

type family DhAlgorithm (a :: Algorithm) :: Constraint where
  DhAlgorithm X25519 = ()
  DhAlgorithm X448 = ()
  DhAlgorithm a =
    (Int ~ Bool, TypeError (Text "Algorithm " :<>: ShowType a :<>: Text " cannot be used for DH exchange"))

dhAlgorithm :: SAlgorithm a -> Maybe (Dict (DhAlgorithm a))
dhAlgorithm = \case
  SX25519 -> Just Dict
  SX448 -> Just Dict
  _ -> Nothing

class CryptoDhSecret s where
  serializeDhSecret :: s -> ByteString
  dhSecretBytes :: s -> ByteString
  strDhSecretP :: Parser s
  dhSecretP :: Parser s

instance AlgorithmI a => IsString (DhSecret a) where
  fromString = parseString $ dhSecret >=> dhSecret'

instance CryptoDhSecret ADhSecret where
  serializeDhSecret (ADhSecret _ s) = serializeDhSecret s
  dhSecretBytes (ADhSecret _ s) = dhSecretBytes s
  strDhSecretP = dhSecret <$?> base64P
  dhSecretP = dhSecret <$?> A.takeByteString

dhSecret :: ByteString -> Either String ADhSecret
dhSecret = cryptoPassed . secret
  where
    secret bs
      | B.length bs == x25519_size = ADhSecret SX25519 . DhSecretX25519 <$> X25519.dhSecret bs
      | B.length bs == x448_size = ADhSecret SX448 . DhSecretX448 <$> X448.dhSecret bs
      | otherwise = CE.CryptoFailed CE.CryptoError_SharedSecretSizeInvalid
    cryptoPassed = \case
      CE.CryptoPassed s -> Right s
      CE.CryptoFailed e -> Left $ show e

instance forall a. AlgorithmI a => CryptoDhSecret (DhSecret a) where
  serializeDhSecret = encode . dhSecretBytes
  dhSecretBytes = \case
    DhSecretX25519 s -> BA.convert s
    DhSecretX448 s -> BA.convert s
  strDhSecretP = dhSecret' <$?> strDhSecretP
  dhSecretP = dhSecret' <$?> dhSecretP

dhSecret' :: forall a. AlgorithmI a => ADhSecret -> Either String (DhSecret a)
dhSecret' (ADhSecret a s) = case testEquality a $ sAlgorithm @a of
  Just Refl -> Right s
  _ -> Left "bad DH secret algorithm"

-- | Class for all key types
class CryptoKey k where
  keySize :: k -> Int

  validKeySize :: k -> Bool

  -- | base64 X509 key encoding with algorithm prefix
  serializeKey :: k -> ByteString

  -- | base64url X509 key encoding with algorithm prefix
  serializeKeyUri :: k -> ByteString

  -- | binary X509 key encoding
  encodeKey :: k -> ByteString

  -- | base64 X509 (with algorithm prefix) key parser
  strKeyP :: Parser k

  -- | base64url X509 (with algorithm prefix) key parser
  strKeyUriP :: Parser k

  -- | binary X509 key parser
  binaryKeyP :: Parser k

-- | X509 encoding of any public key.
instance CryptoKey APublicKey where
  keySize (APublicKey _ k) = keySize k
  validKeySize (APublicKey _ k) = validKeySize k
  serializeKey (APublicKey _ k) = serializeKey k
  serializeKeyUri (APublicKey _ k) = serializeKeyUri k
  encodeKey (APublicKey _ k) = encodeKey k
  strKeyP = strPublicKeyP_ base64P
  strKeyUriP = strPublicKeyP_ base64UriP
  binaryKeyP = decodePubKey <$?> A.takeByteString

strPublicKeyP_ :: Parser ByteString -> Parser APublicKey
strPublicKeyP_ b64P = do
  Alg a <- algP <* A.char ':'
  k@(APublicKey a' _) <- decodePubKey <$?> b64P
  case testEquality a a' of
    Just Refl -> pure k
    _ -> fail $ "public key algorithm " <> show a <> " does not match prefix"

-- | X509 encoding of signature public key.
instance CryptoKey APublicVerifyKey where
  keySize (APublicVerifyKey _ k) = keySize k
  validKeySize (APublicVerifyKey _ k) = validKeySize k
  serializeKey (APublicVerifyKey _ k) = serializeKey k
  serializeKeyUri (APublicVerifyKey _ k) = serializeKeyUri k
  encodeKey (APublicVerifyKey _ k) = encodeKey k
  strKeyP = pubVerifyKey <$?> strKeyP
  strKeyUriP = pubVerifyKey <$?> strKeyUriP
  binaryKeyP = pubVerifyKey <$?> binaryKeyP

-- | X509 encoding of encryption public key.
instance CryptoKey APublicEncryptKey where
  keySize (APublicEncryptKey _ k) = keySize k
  validKeySize (APublicEncryptKey _ k) = validKeySize k
  serializeKey (APublicEncryptKey _ k) = serializeKey k
  serializeKeyUri (APublicEncryptKey _ k) = serializeKeyUri k
  encodeKey (APublicEncryptKey _ k) = encodeKey k
  strKeyP = pubEncryptKey <$?> strKeyP
  strKeyUriP = pubEncryptKey <$?> strKeyUriP
  binaryKeyP = pubEncryptKey <$?> binaryKeyP

-- | X509 encoding of 'PublicKey'.
instance forall a. AlgorithmI a => CryptoKey (PublicKey a) where
  keySize = \case
    PublicKeyRSA k -> R.public_size k
    PublicKeyEd25519 _ -> Ed25519.publicKeySize
    PublicKeyEd448 _ -> Ed448.publicKeySize
    PublicKeyX25519 _ -> x25519_size
    PublicKeyX448 _ -> x448_size
  validKeySize = \case
    PublicKeyRSA k -> validRSAKeySize $ R.public_size k
    _ -> True
  serializeKey k = algorithmPrefix k <> ":" <> encode (encodeKey k)
  serializeKeyUri k = algorithmPrefix k <> ":" <> U.encode (encodeKey k)
  encodeKey = encodeASNKey . publicToX509
  strKeyP = pubKey' <$?> strKeyP
  strKeyUriP = pubKey' <$?> strKeyUriP
  binaryKeyP = pubKey' <$?> binaryKeyP

-- | X509 encoding of any private key.
instance CryptoKey APrivateKey where
  keySize (APrivateKey _ k) = keySize k
  validKeySize (APrivateKey _ k) = validKeySize k
  serializeKey (APrivateKey _ k) = serializeKey k
  serializeKeyUri (APrivateKey _ k) = serializeKeyUri k
  encodeKey (APrivateKey _ k) = encodeKey k
  strKeyP = strPrivateKeyP_ base64P
  strKeyUriP = strPrivateKeyP_ base64UriP
  binaryKeyP = decodePrivKey <$?> A.takeByteString

strPrivateKeyP_ :: Parser ByteString -> Parser APrivateKey
strPrivateKeyP_ b64P = do
  Alg a <- algP <* A.char ':'
  k@(APrivateKey a' _) <- decodePrivKey <$?> b64P
  case testEquality a a' of
    Just Refl -> pure k
    _ -> fail $ "private key algorithm " <> show a <> " does not match prefix"

-- | X509 encoding of signature private key.
instance CryptoKey APrivateSignKey where
  keySize (APrivateSignKey _ k) = keySize k
  validKeySize (APrivateSignKey _ k) = validKeySize k
  serializeKey (APrivateSignKey _ k) = serializeKey k
  serializeKeyUri (APrivateSignKey _ k) = serializeKeyUri k
  encodeKey (APrivateSignKey _ k) = encodeKey k
  strKeyP = privSignKey <$?> strKeyP
  strKeyUriP = privSignKey <$?> strKeyUriP
  binaryKeyP = privSignKey <$?> binaryKeyP

-- | X509 encoding of encryption private key.
instance CryptoKey APrivateDecryptKey where
  keySize (APrivateDecryptKey _ k) = keySize k
  validKeySize (APrivateDecryptKey _ k) = validKeySize k
  serializeKey (APrivateDecryptKey _ k) = serializeKey k
  serializeKeyUri (APrivateDecryptKey _ k) = serializeKeyUri k
  encodeKey (APrivateDecryptKey _ k) = encodeKey k
  strKeyP = privDecryptKey <$?> strKeyP
  strKeyUriP = privDecryptKey <$?> strKeyUriP
  binaryKeyP = privDecryptKey <$?> binaryKeyP

-- | X509 encoding of 'PrivateKey'.
instance AlgorithmI a => CryptoKey (PrivateKey a) where
  keySize = \case
    PrivateKeyRSA k -> rsaPrivateKeySize k
    PrivateKeyEd25519 _ _ -> Ed25519.secretKeySize
    PrivateKeyEd448 _ _ -> Ed448.secretKeySize
    PrivateKeyX25519 _ -> x25519_size
    PrivateKeyX448 _ -> x448_size
  validKeySize = \case
    PrivateKeyRSA k -> validRSAKeySize $ rsaPrivateKeySize k
    _ -> True
  serializeKey k = algorithmPrefix k <> ":" <> encode (encodeKey k)
  serializeKeyUri k = algorithmPrefix k <> ":" <> U.encode (encodeKey k)
  encodeKey = encodeASNKey . privateToX509
  strKeyP = privKey' <$?> strKeyP
  strKeyUriP = privKey' <$?> strKeyUriP
  binaryKeyP = privKey' <$?> binaryKeyP

type family PublicKeyType pk where
  PublicKeyType APrivateKey = APublicKey
  PublicKeyType APrivateSignKey = APublicVerifyKey
  PublicKeyType APrivateDecryptKey = APublicEncryptKey
  PublicKeyType (PrivateKey a) = PublicKey a

class CryptoPrivateKey pk where publicKey :: pk -> PublicKeyType pk

instance CryptoPrivateKey APrivateKey where
  publicKey (APrivateKey a k) = APublicKey a $ publicKey k

instance CryptoPrivateKey APrivateSignKey where
  publicKey (APrivateSignKey a k) = APublicVerifyKey a $ publicKey k

instance CryptoPrivateKey APrivateDecryptKey where
  publicKey (APrivateDecryptKey a k) = APublicEncryptKey a $ publicKey k

instance CryptoPrivateKey (PrivateKey a) where
  publicKey = \case
    PrivateKeyRSA k -> PublicKeyRSA $ R.private_pub k
    PrivateKeyEd25519 _ k -> PublicKeyEd25519 k
    PrivateKeyEd448 _ k -> PublicKeyEd448 k
    PrivateKeyX25519 k -> PublicKeyX25519 $ X25519.toPublic k
    PrivateKeyX448 k -> PublicKeyX448 $ X448.toPublic k

instance AlgorithmI a => IsString (PrivateKey a) where
  fromString = parseString $ decode >=> decodePrivKey >=> privKey'

instance AlgorithmI a => IsString (PublicKey a) where
  fromString = parseString $ decode >=> decodePubKey >=> pubKey'

-- | Tuple of RSA 'PublicKey' and 'PrivateKey'.
type KeyPair a = (PublicKey a, PrivateKey a)

type AKeyPair = (APublicKey, APrivateKey)

type ASignatureKeyPair = (APublicVerifyKey, APrivateSignKey)

type AnEncryptionKeyPair = (APublicEncryptKey, APrivateDecryptKey)

generateKeyPair :: AlgorithmI a => Int -> SAlgorithm a -> IO AKeyPair
generateKeyPair size a = bimap (APublicKey a) (APrivateKey a) <$> generateKeyPair' size

generateSignatureKeyPair ::
  (AlgorithmI a, SignatureAlgorithm a) => Int -> SAlgorithm a -> IO ASignatureKeyPair
generateSignatureKeyPair size a =
  bimap (APublicVerifyKey a) (APrivateSignKey a) <$> generateKeyPair' size

generateEncryptionKeyPair ::
  (AlgorithmI a, EncryptionAlgorithm a) => Int -> SAlgorithm a -> IO AnEncryptionKeyPair
generateEncryptionKeyPair size a =
  bimap (APublicEncryptKey a) (APrivateDecryptKey a) <$> generateKeyPair' size

generateKeyPair' :: forall a. AlgorithmI a => Int -> IO (KeyPair a)
generateKeyPair' size = case sAlgorithm @a of
  SRSA -> generateKeyPairRSA size
  SEd25519 ->
    Ed25519.generateSecretKey >>= \pk ->
      let k = Ed25519.toPublic pk
       in pure (PublicKeyEd25519 k, PrivateKeyEd25519 pk k)
  SEd448 ->
    Ed448.generateSecretKey >>= \pk ->
      let k = Ed448.toPublic pk
       in pure (PublicKeyEd448 k, PrivateKeyEd448 pk k)
  SX25519 ->
    X25519.generateSecretKey >>= \pk ->
      let k = X25519.toPublic pk
       in pure (PublicKeyX25519 k, PrivateKeyX25519 pk)
  SX448 ->
    X448.generateSecretKey >>= \pk ->
      let k = X448.toPublic pk
       in pure (PublicKeyX448 k, PrivateKeyX448 pk)

instance ToField APrivateSignKey where toField = toField . encodeKey

instance ToField APublicVerifyKey where toField = toField . encodeKey

instance ToField APrivateDecryptKey where toField = toField . encodeKey

instance ToField APublicEncryptKey where toField = toField . encodeKey

instance (Typeable a, AlgorithmI a) => ToField (DhSecret a) where toField = toField . dhSecretBytes

instance FromField APrivateSignKey where fromField = blobFieldParser binaryKeyP

instance FromField APublicVerifyKey where fromField = blobFieldParser binaryKeyP

instance FromField APrivateDecryptKey where fromField = blobFieldParser binaryKeyP

instance FromField APublicEncryptKey where fromField = blobFieldParser binaryKeyP

instance (Typeable a, AlgorithmI a) => FromField (DhSecret a) where fromField = blobFieldParser dhSecretP

instance IsString (Maybe ASignature) where
  fromString = parseString $ decode >=> decodeSignature

data Signature (a :: Algorithm) where
  SignatureRSA :: ByteString -> Signature RSA
  SignatureEd25519 :: Ed25519.Signature -> Signature Ed25519
  SignatureEd448 :: Ed448.Signature -> Signature Ed448

deriving instance Eq (Signature a)

deriving instance Show (Signature a)

data ASignature
  = forall a.
    (AlgorithmI a, SignatureAlgorithm a) =>
    ASignature (SAlgorithm a) (Signature a)

instance Eq ASignature where
  ASignature a s == ASignature a' s' = case testEquality a a' of
    Just Refl -> s == s'
    _ -> False

deriving instance Show ASignature

class CryptoSignature s where
  serializeSignature :: s -> ByteString
  serializeSignature = encode . signatureBytes
  signatureBytes :: s -> ByteString
  decodeSignature :: ByteString -> Either String s

instance CryptoSignature ASignature where
  signatureBytes (ASignature _ sig) = signatureBytes sig
  decodeSignature s
    | l == Ed25519.signatureSize =
      ASignature SEd25519 . SignatureEd25519 <$> ed Ed25519.signature s
    | l == Ed448.signatureSize =
      ASignature SEd448 . SignatureEd448 <$> ed Ed448.signature s
    | l == 128 || l == 256 || l == 384 || l == 512 = rsa s
    | otherwise = Left "bad signature size"
    where
      l = B.length s
      ed alg = first show . CE.eitherCryptoError . alg
      rsa = Right . ASignature SRSA . SignatureRSA

instance CryptoSignature (Maybe ASignature) where
  signatureBytes = maybe "" signatureBytes
  decodeSignature s
    | B.null s = Right Nothing
    | otherwise = Just <$> decodeSignature s

instance AlgorithmI a => CryptoSignature (Signature a) where
  signatureBytes = \case
    SignatureRSA s -> s
    SignatureEd25519 s -> BA.convert s
    SignatureEd448 s -> BA.convert s
  decodeSignature s = do
    ASignature a sig <- decodeSignature s
    case testEquality a $ sAlgorithm @a of
      Just Refl -> Right sig
      _ -> Left "bad signature algorithm"

class SignatureSize s where signatureSize :: s -> Int

instance SignatureSize (Signature a) where
  signatureSize = \case
    SignatureRSA s -> B.length s
    SignatureEd25519 _ -> Ed25519.signatureSize
    SignatureEd448 _ -> Ed448.signatureSize

instance SignatureSize APrivateSignKey where
  signatureSize (APrivateSignKey _ k) = signatureSize k

instance SignatureSize APublicVerifyKey where
  signatureSize (APublicVerifyKey _ k) = signatureSize k

instance SignatureAlgorithm a => SignatureSize (PrivateKey a) where
  signatureSize = \case
    PrivateKeyRSA k -> rsaPrivateKeySize k
    PrivateKeyEd25519 _ _ -> Ed25519.signatureSize
    PrivateKeyEd448 _ _ -> Ed448.signatureSize

instance SignatureAlgorithm a => SignatureSize (PublicKey a) where
  signatureSize = \case
    PublicKeyRSA k -> R.public_size k
    PublicKeyEd25519 _ -> Ed25519.signatureSize
    PublicKeyEd448 _ -> Ed448.signatureSize

rsaPrivateKeySize :: R.PrivateKey -> Int
rsaPrivateKeySize = R.public_size . R.private_pub

-- | Various cryptographic or related errors.
data CryptoError
  = -- | RSA OAEP encryption error
    RSAEncryptError R.Error
  | -- | RSA OAEP decryption error
    RSADecryptError R.Error
  | -- | RSA PSS signature error
    RSASignError R.Error
  | -- | Unsupported signing algorithm
    UnsupportedAlgorithm
  | -- | AES initialization error
    AESCipherError CE.CryptoError
  | -- | IV generation error
    CryptoIVError
  | -- | AES decryption error
    AESDecryptError
  | -- CryptoBox decryption error
    CBDecryptError
  | -- | message does not fit in SMP block
    CryptoLargeMsgError
  | -- | failure parsing message header
    CryptoHeaderError String
  | -- | no sending chain key in ratchet state
    CERatchetState
  | -- | header decryption error (could indicate that another key should be tried)
    CERatchetHeader
  | -- | too many skipped messages
    CERatchetTooManySkipped
  | -- | skipped message was not decrypted in decryptSkipped
    CERatchetSkippedMessage
  deriving (Eq, Show, Exception)

pubExpRange :: Integer
pubExpRange = 2 ^ (1024 :: Int)

aesKeySize :: Int
aesKeySize = 256 `div` 8

authTagSize :: Int
authTagSize = 128 `div` 8

-- | Generate RSA key pair.
generateKeyPairRSA :: Int -> IO (KeyPair RSA)
generateKeyPairRSA size = loop
  where
    publicExponent = findPrimeFrom . (+ 3) <$> generateMax pubExpRange
    loop = do
      (k, pk) <- R.generate size =<< publicExponent
      let n = R.public_n k
          d = R.private_d pk
      if d * d < n
        then loop
        else pure (PublicKeyRSA k, PrivateKeyRSA pk)

x25519_size :: Int
x25519_size = 32

x448_size :: Int
x448_size = 448 `quot` 8

validRSAKeySize :: Int -> Bool
validRSAKeySize n = n == 128 || n == 256 || n == 384 || n == 512

validSignatureSize :: Int -> Bool
validSignatureSize n =
  n == Ed25519.signatureSize || n == Ed448.signatureSize || validRSAKeySize n

data Header = Header
  { aesKey :: Key,
    ivBytes :: IV,
    authTag :: AES.AuthTag,
    msgSize :: Int
  }

-- | AES key newtype.
newtype Key = Key {unKey :: ByteString}
  deriving (Eq, Ord)

-- | IV bytes newtype.
newtype IV = IV {unIV :: ByteString}

-- | Key hash newtype.
newtype KeyHash = KeyHash {unKeyHash :: ByteString} deriving (Eq, Ord, Show)

instance IsString KeyHash where
  fromString = parseString . parseAll $ KeyHash <$> base64P

instance ToField KeyHash where toField = toField . encode . unKeyHash

instance FromField KeyHash where fromField = blobFieldParser $ KeyHash <$> base64P

-- | Digest (hash) of binary X509 encoding of RSA public key.
publicKeyHash :: PublicKey RSA -> KeyHash
publicKeyHash = KeyHash . sha256Hash . encodeKey

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

parseHeader :: ByteString -> ExceptT CryptoError IO Header
parseHeader = parseE CryptoHeaderError headerP

-- * E2E hybrid encryption scheme

-- | Legacy hybrid E2E encryption of SMP agent messages (RSA-OAEP/AES-256-GCM-SHA256).
--
-- https://github.com/simplex-chat/simplexmq/blob/master/rfcs/2021-01-26-crypto.md#e2e-encryption
encrypt' :: PublicKey a -> Int -> ByteString -> ExceptT CryptoError IO ByteString
encrypt' k@(PublicKeyRSA _) paddedSize msg = do
  aesKey <- liftIO randomAesKey
  ivBytes <- liftIO randomIV
  (authTag, msg') <- encryptAES aesKey ivBytes paddedSize msg
  let header = Header {aesKey, ivBytes, authTag, msgSize = B.length msg}
  encHeader <- encryptOAEP k $ serializeHeader header
  return $ encHeader <> msg'
encrypt' _ _ _ = throwE UnsupportedAlgorithm

-- | Legacy hybrid E2E decryption of SMP agent messages (RSA-OAEP/AES-256-GCM-SHA256).
--
-- https://github.com/simplex-chat/simplexmq/blob/master/rfcs/2021-01-26-crypto.md#e2e-encryption
decrypt' :: PrivateKey a -> ByteString -> ExceptT CryptoError IO ByteString
decrypt' pk@(PrivateKeyRSA _) msg'' = do
  let (encHeader, msg') = B.splitAt (keySize pk) msg''
  header <- decryptOAEP pk encHeader
  Header {aesKey, ivBytes, authTag, msgSize} <- parseHeader header
  msg <- decryptAES aesKey ivBytes msg' authTag
  return $ B.take msgSize msg
decrypt' _ _ = throwE UnsupportedAlgorithm

encrypt :: APublicEncryptKey -> Int -> ByteString -> ExceptT CryptoError IO ByteString
encrypt (APublicEncryptKey _ k) = encrypt' k

decrypt :: APrivateDecryptKey -> ByteString -> ExceptT CryptoError IO ByteString
decrypt (APrivateDecryptKey _ pk) = decrypt' pk

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
      | len > paddedSize = throwE CryptoLargeMsgError
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
encryptOAEP :: PublicKey RSA -> ByteString -> ExceptT CryptoError IO ByteString
encryptOAEP (PublicKeyRSA k) aesKey =
  liftEitherError RSAEncryptError $
    OAEP.encrypt oaepParams k aesKey

-- | RSA OAEP decryption.
--
-- Used as part of hybrid E2E encryption scheme and for SMP transport handshake.
decryptOAEP :: PrivateKey RSA -> ByteString -> ExceptT CryptoError IO ByteString
decryptOAEP (PrivateKeyRSA pk) encKey =
  liftEitherError RSADecryptError $
    OAEP.decryptSafer oaepParams pk encKey

pssParams :: PSS.PSSParams SHA256 ByteString ByteString
pssParams = PSS.defaultPSSParams SHA256

-- | Message signing.
--
-- Used by SMP clients to sign SMP commands and by SMP agents to sign messages.
sign' :: SignatureAlgorithm a => PrivateKey a -> ByteString -> ExceptT CryptoError IO (Signature a)
sign' (PrivateKeyRSA pk) msg = ExceptT $ bimap RSASignError SignatureRSA <$> PSS.signSafer pssParams pk msg
sign' (PrivateKeyEd25519 pk k) msg = pure . SignatureEd25519 $ Ed25519.sign pk k msg
sign' (PrivateKeyEd448 pk k) msg = pure . SignatureEd448 $ Ed448.sign pk k msg

sign :: APrivateSignKey -> ByteString -> ExceptT CryptoError IO ASignature
sign (APrivateSignKey a k) = fmap (ASignature a) . sign' k

-- | Signature verification.
--
-- Used by SMP servers to authorize SMP commands and by SMP agents to verify messages.
verify' :: SignatureAlgorithm a => PublicKey a -> Signature a -> ByteString -> Bool
verify' (PublicKeyRSA k) (SignatureRSA sig) msg = PSS.verify pssParams k msg sig
verify' (PublicKeyEd25519 k) (SignatureEd25519 sig) msg = Ed25519.verify k msg sig
verify' (PublicKeyEd448 k) (SignatureEd448 sig) msg = Ed448.verify k msg sig

verify :: APublicVerifyKey -> ASignature -> ByteString -> Bool
verify (APublicVerifyKey a k) (ASignature a' sig) msg = case testEquality a a' of
  Just Refl -> verify' k sig msg
  _ -> False

dh' :: DhAlgorithm a => PublicKey a -> PrivateKey a -> DhSecret a
dh' (PublicKeyX25519 k) (PrivateKeyX25519 pk) = DhSecretX25519 $ X25519.dh k pk
dh' (PublicKeyX448 k) (PrivateKeyX448 pk) = DhSecretX448 $ X448.dh k pk

-- | NaCl @crypto_box@ encrypt with a shared DH secret and 192-bit nonce.
cbEncrypt :: DhSecret X25519 -> ByteString -> ByteString -> ByteString
cbEncrypt secret nonce msg = BA.convert tag `B.append` c
  where
    (rs, c) = xSalsa20 secret nonce msg
    tag = Poly1305.auth rs c

-- | NaCl @crypto_box@ decrypt with a shared DH secret and 192-bit nonce.
cbDecrypt :: DhSecret X25519 -> ByteString -> ByteString -> Either CryptoError ByteString
cbDecrypt secret nonce packet
  | B.length packet < 16 = Left CBDecryptError
  | BA.constEq tag' tag = Right msg
  | otherwise = Left CBDecryptError
  where
    (tag', c) = B.splitAt 16 packet
    (rs, msg) = xSalsa20 secret nonce c
    tag = Poly1305.auth rs c

cbNonce :: ByteString -> ByteString
cbNonce s
  | len == 24 = s
  | len > 24 = fst $ B.splitAt 24 s
  | otherwise = s <> B.replicate (24 - len) (toEnum 0)
  where
    len = B.length s

xSalsa20 :: DhSecret X25519 -> ByteString -> ByteString -> (ByteString, ByteString)
xSalsa20 (DhSecretX25519 shared) nonce msg = (rs, msg')
  where
    zero = B.replicate 16 $ toEnum 0
    (iv0, iv1) = B.splitAt 8 nonce
    state0 = XSalsa.initialize 20 shared (zero `B.append` iv0)
    state1 = XSalsa.derive state0 iv1
    (rs, state2) = XSalsa.generate state1 32
    (msg', _) = XSalsa.combine state2 msg

pubVerifyKey :: APublicKey -> Either String APublicVerifyKey
pubVerifyKey (APublicKey a k) = case signatureAlgorithm a of
  Just Dict -> Right $ APublicVerifyKey a k
  _ -> Left "key does not support signature algorithms"

pubEncryptKey :: APublicKey -> Either String APublicEncryptKey
pubEncryptKey (APublicKey a k) = case encryptionAlgorithm a of
  Just Dict -> Right $ APublicEncryptKey a k
  _ -> Left "key does not support encryption algorithms"

pubKey' :: forall a. AlgorithmI a => APublicKey -> Either String (PublicKey a)
pubKey' (APublicKey a k) = case testEquality a $ sAlgorithm @a of
  Just Refl -> Right k
  _ -> Left "bad key algorithm"

privSignKey :: APrivateKey -> Either String APrivateSignKey
privSignKey (APrivateKey a k) = case signatureAlgorithm a of
  Just Dict -> Right $ APrivateSignKey a k
  _ -> Left "key does not support signature algorithms"

privDecryptKey :: APrivateKey -> Either String APrivateDecryptKey
privDecryptKey (APrivateKey a k) = case encryptionAlgorithm a of
  Just Dict -> Right $ APrivateDecryptKey a k
  _ -> Left "key does not support encryption algorithms"

privKey' :: forall a. AlgorithmI a => APrivateKey -> Either String (PrivateKey a)
privKey' (APrivateKey a k) = case testEquality a $ sAlgorithm @a of
  Just Refl -> Right k
  _ -> Left "bad key algorithm"

publicToX509 :: PublicKey a -> PubKey
publicToX509 = \case
  PublicKeyRSA k -> PubKeyRSA k
  PublicKeyEd25519 k -> PubKeyEd25519 k
  PublicKeyEd448 k -> PubKeyEd448 k
  PublicKeyX25519 k -> PubKeyX25519 k
  PublicKeyX448 k -> PubKeyX448 k

privateToX509 :: PrivateKey a -> PrivKey
privateToX509 = \case
  PrivateKeyRSA k -> PrivKeyRSA k
  PrivateKeyEd25519 k _ -> PrivKeyEd25519 k
  PrivateKeyEd448 k _ -> PrivKeyEd448 k
  PrivateKeyX25519 k -> PrivKeyX25519 k
  PrivateKeyX448 k -> PrivKeyX448 k

encodeASNKey :: ASN1Object a => a -> ByteString
encodeASNKey k = toStrict . encodeASN1 DER $ toASN1 k []

-- Decoding of binary X509 'PublicKey'.
decodePubKey :: ByteString -> Either String APublicKey
decodePubKey =
  decodeKey >=> \case
    (PubKeyRSA k, []) -> Right . APublicKey SRSA $ PublicKeyRSA k
    (PubKeyEd25519 k, []) -> Right . APublicKey SEd25519 $ PublicKeyEd25519 k
    (PubKeyEd448 k, []) -> Right . APublicKey SEd448 $ PublicKeyEd448 k
    (PubKeyX25519 k, []) -> Right . APublicKey SX25519 $ PublicKeyX25519 k
    (PubKeyX448 k, []) -> Right . APublicKey SX448 $ PublicKeyX448 k
    r -> keyError r

-- Decoding of binary PKCS8 'PrivateKey'.
decodePrivKey :: ByteString -> Either String APrivateKey
decodePrivKey =
  decodeKey >=> \case
    (PrivKeyRSA pk, []) -> Right . APrivateKey SRSA $ PrivateKeyRSA pk
    (PrivKeyEd25519 k, []) -> Right . APrivateKey SEd25519 . PrivateKeyEd25519 k $ Ed25519.toPublic k
    (PrivKeyEd448 k, []) -> Right . APrivateKey SEd448 . PrivateKeyEd448 k $ Ed448.toPublic k
    (PrivKeyX25519 k, []) -> Right . APrivateKey SX25519 $ PrivateKeyX25519 k
    (PrivKeyX448 k, []) -> Right . APrivateKey SX448 $ PrivateKeyX448 k
    r -> keyError r

decodeKey :: ASN1Object a => ByteString -> Either String (a, [ASN1])
decodeKey = fromASN1 <=< first show . decodeASN1 DER . fromStrict

keyError :: (a, [ASN1]) -> Either String b
keyError = \case
  (_, []) -> Left "unknown key algorithm"
  _ -> Left "more than one key"
