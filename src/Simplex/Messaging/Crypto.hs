{-# LANGUAGE NamedFieldPuns #-}

module Simplex.Messaging.Crypto where

import Crypto.Number.Generate (generateMax)
import Crypto.Number.Prime (findPrimeFrom)
import Crypto.PubKey.RSA hiding (PrivateKey, PublicKey)
import qualified Crypto.PubKey.RSA as RSA
import Crypto.PubKey.RSA.Types (private_n)
import Crypto.Random (MonadRandom)

data PublicKey = PublicKey
  { pub_size :: Int,
    pub_n :: Integer,
    pub_e :: Integer
  }
  deriving (Show)

data PrivateKey = PrivateKey
  { priv_size :: Int,
    priv_n :: Integer,
    priv_d :: Integer
  }
  deriving (Show)

type KeyPair = (PublicKey, PrivateKey)

pubExpRange :: Integer
pubExpRange = 2 ^ (1024 :: Int)

generateKeyPair :: MonadRandom m => Int -> m (KeyPair, Int)
generateKeyPair size = loop 1
  where
    loop i = do
      (pub, priv) <- RSA.generate size =<< publicExponent
      if smallPrivateExponent priv
        then loop (i + 1)
        else
          let s = public_size pub
              n = public_n pub
           in return
                ( ( PublicKey {pub_size = s, pub_n = n, pub_e = public_e pub},
                    PrivateKey {priv_size = s, priv_n = n, priv_d = private_d priv}
                  ),
                  i
                )
    publicExponent = findPrimeFrom . (+ 3) <$> generateMax pubExpRange
    smallPrivateExponent pk = let d = private_d pk in d * d < private_n pk
