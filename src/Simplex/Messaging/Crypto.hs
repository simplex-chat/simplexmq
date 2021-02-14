{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

module Simplex.Messaging.Crypto
  ( PrivateKey (..),
    PublicKey (..),
    Signature (..),
    generateKeyPair,
    sign,
    verify,
    serializePrivKey,
    serializePubKey,
    parsePrivKey,
    parsePubKey,
    privKeyP,
    pubKeyP,
  )
where

import Crypto.Hash.Algorithms (SHA256 (..))
import Crypto.Number.Generate (generateMax)
import Crypto.Number.Prime (findPrimeFrom)
import Crypto.Number.Serialize (i2osp, os2ip)
import qualified Crypto.PubKey.RSA as R
import qualified Crypto.PubKey.RSA.PSS as PSS
import Data.Attoparsec.ByteString.Char8 (Parser)
import qualified Data.Attoparsec.ByteString.Char8 as A
import Data.ByteString.Base64
import Data.ByteString.Char8 (ByteString)
import Data.String
import Database.SQLite.Simple as DB
import Database.SQLite.Simple.FromField
import Database.SQLite.Simple.Internal (Field (..))
import Database.SQLite.Simple.Ok (Ok (Ok))
import Database.SQLite.Simple.ToField (ToField (..))
import Simplex.Messaging.Parsers (base64P)
import Simplex.Messaging.Util (bshow, (<$$>))

newtype PublicKey = PublicKey R.PublicKey deriving (Eq, Show)

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

pubExpRange :: Integer
pubExpRange = 2 ^ (1024 :: Int)

generateKeyPair :: Int -> IO KeyPair
generateKeyPair size = loop
  where
    loop = do
      (pub, priv) <- R.generate size =<< publicExponent
      let n = R.public_n pub
          d = R.private_d priv
       in if d * d < n
            then loop
            else
              return
                ( PublicKey pub,
                  PrivateKey {private_size = R.public_size pub, private_n = n, private_d = d}
                )
    publicExponent = findPrimeFrom . (+ 3) <$> generateMax pubExpRange

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
