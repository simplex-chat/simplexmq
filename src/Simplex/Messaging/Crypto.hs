{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

module Simplex.Messaging.Crypto
  ( PrivateKey (..),
    PublicKey (..),
    Signature (..),
    generateKeyPair,
    sign,
    signStub,
    verify,
    verifyStub,
    serializePrivKey,
    serializePubKey,
    parsePrivKey,
    parsePubKey,
    privKeyP,
    pubKeyP,
    base64P,
  )
where

import Crypto.Hash.Algorithms (SHA256 (..))
import Crypto.Number.Generate (generateMax)
import Crypto.Number.Prime (findPrimeFrom)
import Crypto.Number.Serialize (i2osp, os2ip)
import qualified Crypto.PubKey.RSA as C
import qualified Crypto.PubKey.RSA.PSS as PSS
import Data.Attoparsec.ByteString.Char8 (Parser)
import qualified Data.Attoparsec.ByteString.Char8 as A
import Data.ByteString.Base64
import Data.ByteString.Char8 (ByteString)
import Data.Char (isAlphaNum)
import Database.SQLite.Simple as DB
import Database.SQLite.Simple.FromField
import Database.SQLite.Simple.Internal (Field (..))
import Database.SQLite.Simple.Ok (Ok (Ok))
import Database.SQLite.Simple.ToField (ToField (..))
import Simplex.Messaging.Util (bshow, (<$$>))

newtype PublicKey = PublicKey C.PublicKey deriving (Eq, Show)

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
      Left e -> returnError ConversionFailed f ("couldn't parse PrivateKey field: " ++ e)
  fromField f = returnError ConversionFailed f "expecting SQLBlob column type"

type KeyPair = (PublicKey, PrivateKey)

newtype Signature = Signature ByteString

newtype Verified = Verified ByteString

pubExpRange :: Integer
pubExpRange = 2 ^ (1024 :: Int)

generateKeyPair :: Int -> IO KeyPair
generateKeyPair size = loop
  where
    loop = do
      (pub, priv) <- C.generate size =<< publicExponent
      let n = C.public_n pub
          d = C.private_d priv
       in if d * d < n
            then loop
            else
              return
                ( PublicKey pub,
                  PrivateKey {private_size = C.public_size pub, private_n = n, private_d = d}
                )
    publicExponent = findPrimeFrom . (+ 3) <$> generateMax pubExpRange

pssParams :: PSS.PSSParams SHA256 ByteString ByteString
pssParams = PSS.defaultPSSParams SHA256

sign :: PrivateKey -> ByteString -> IO (Either C.Error Signature)
sign pk msg = Signature <$$> PSS.signSafer pssParams (rsaPrivateKey pk) msg

signStub :: PrivateKey -> ByteString -> IO (Either C.Error Signature)
signStub (PrivateKey _ n _) _ = return . Right . Signature $ i2osp n

verify :: PublicKey -> Signature -> ByteString -> Maybe Verified
verify (PublicKey k) (Signature sig) msg =
  if PSS.verify pssParams k msg sig
    then Just $ Verified msg
    else Nothing

verifyStub :: PublicKey -> Signature -> ByteString -> Maybe Verified
verifyStub (PublicKey (C.PublicKey _ n _)) (Signature sig) msg =
  if i2osp n == sig
    then Just $ Verified msg
    else Nothing

serializePubKey :: PublicKey -> ByteString
serializePubKey (PublicKey k) = serializeKey_ (C.public_size k, C.public_n k, C.public_e k)

serializePrivKey :: PrivateKey -> ByteString
serializePrivKey pk = serializeKey_ (private_size pk, private_n pk, private_d pk)

serializeKey_ :: (Int, Integer, Integer) -> ByteString
serializeKey_ (size, n, ex) = bshow size <> "," <> encInt n <> "," <> encInt ex
  where
    encInt = encode . i2osp

pubKeyP :: Parser PublicKey
pubKeyP = do
  (public_size, public_n, public_e) <- keyParser_
  return . PublicKey $ C.PublicKey {C.public_size, C.public_n, C.public_e}

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

base64P :: Parser ByteString
base64P = do
  str <- A.takeWhile1 (\c -> isAlphaNum c || c == '+' || c == '/')
  pad <- A.takeWhile (== '=')
  either fail pure $ decode (str <> pad)

rsaPrivateKey :: PrivateKey -> C.PrivateKey
rsaPrivateKey pk =
  C.PrivateKey
    { C.private_pub =
        C.PublicKey
          { C.public_size = private_size pk,
            C.public_n = private_n pk,
            C.public_e = undefined
          },
      C.private_d = private_d pk,
      C.private_p = 0,
      C.private_q = 0,
      C.private_dP = undefined,
      C.private_dQ = undefined,
      C.private_qinv = undefined
    }
