{-# LANGUAGE NamedFieldPuns #-}

module Simplex.Messaging.Crypto where

import Crypto.Hash.Algorithms (SHA256 (..))
import Crypto.Number.Generate (generateMax)
import Crypto.Number.Prime (findPrimeFrom)
import Crypto.PubKey.RSA (PublicKey (..))
import qualified Crypto.PubKey.RSA as C
import qualified Crypto.PubKey.RSA.PSS as PSS
import Crypto.Random (MonadRandom)
import Data.ByteString (ByteString)
import Simplex.Messaging.Util ((<$$>))

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
