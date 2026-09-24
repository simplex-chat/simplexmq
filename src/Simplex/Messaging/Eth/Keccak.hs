-- | Keccak-256, the hash Ethereum uses. Not SHA3-256: they differ in the padding byte and produce entirely different digests.
module Simplex.Messaging.Eth.Keccak
  ( keccak256,
  )
where

import Crypto.Hash (Digest, Keccak_256, hash)
import qualified Data.ByteArray as BA
import Data.ByteString (ByteString)

keccak256 :: ByteString -> ByteString
keccak256 bs = BA.convert (hash bs :: Digest Keccak_256)
