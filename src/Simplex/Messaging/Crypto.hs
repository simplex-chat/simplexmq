{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

module Simplex.Messaging.Crypto where

import Crypto.Hash.Algorithms (SHA256 (..))
import Crypto.Number.Generate (generateMax)
import Crypto.Number.Prime (findPrimeFrom)
import Crypto.Number.Serialize (i2osp, os2ip)
import Crypto.PubKey.RSA (PublicKey (..))
import qualified Crypto.PubKey.RSA as C
import qualified Crypto.PubKey.RSA.PSS as PSS
import Crypto.Random (MonadRandom)
import Data.Attoparsec.ByteString.Char8 (Parser)
import qualified Data.Attoparsec.ByteString.Char8 as A
import Data.ByteString.Base64
import Data.ByteString.Char8 (ByteString)
import Simplex.Messaging.Agent.Transmission (base64P)
import Simplex.Messaging.Util (bshow, (<$$>))

data PrivateKey = PrivateKey
  { private_size :: Int,
    private_n :: Integer,
    private_d :: Integer
  }
  deriving (Show)

type KeyPair = (PublicKey, PrivateKey)

newtype Signature = Signature ByteString

newtype Verified = Verified ByteString

pubExpRange :: Integer
pubExpRange = 2 ^ (1024 :: Int)

generateKeyPair :: MonadRandom m => Int -> m KeyPair
generateKeyPair size = loop
  where
    loop = do
      (pub, priv) <- C.generate size =<< publicExponent
      let n = public_n pub
          d = C.private_d priv
       in if d * d < n
            then loop
            else
              return
                ( pub,
                  PrivateKey {private_size = public_size pub, private_n = n, private_d = d}
                )
    publicExponent = findPrimeFrom . (+ 3) <$> generateMax pubExpRange

pssParams :: PSS.PSSParams SHA256 ByteString ByteString
pssParams = PSS.defaultPSSParams SHA256

sign :: MonadRandom m => PrivateKey -> ByteString -> m (Either C.Error Signature)
sign pk msg = Signature <$$> PSS.signSafer pssParams (rsaPrivateKey pk) msg

verify :: PublicKey -> Signature -> ByteString -> Maybe Verified
verify k (Signature sig) msg =
  if PSS.verify pssParams k msg sig
    then Just $ Verified msg
    else Nothing

serializePubKey :: PublicKey -> ByteString
serializePubKey k = serializeKey_ (public_size k, public_n k, public_e k)

serializePrivKey :: PrivateKey -> ByteString
serializePrivKey pk = serializeKey_ (private_size pk, private_n pk, private_d pk)

serializeKey_ :: (Int, Integer, Integer) -> ByteString
serializeKey_ (size, n, ex) = bshow size <> "," <> encInt n <> "," <> encInt ex
  where
    encInt = encode . i2osp

pubKeyP :: Parser PublicKey
pubKeyP = do
  (public_size, public_n, public_e) <- keyParser_
  return PublicKey {public_size, public_n, public_e}

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

rsaPrivateKey :: PrivateKey -> C.PrivateKey
rsaPrivateKey pk =
  C.PrivateKey
    { C.private_pub =
        PublicKey
          { public_size = private_size pk,
            public_n = private_n pk,
            public_e = undefined
          },
      C.private_d = private_d pk,
      C.private_p = undefined,
      C.private_q = undefined,
      C.private_dP = undefined,
      C.private_dQ = undefined,
      C.private_qinv = undefined
    }
