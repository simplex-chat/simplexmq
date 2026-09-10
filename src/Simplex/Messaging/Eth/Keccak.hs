-- | Keccak-256 — the hash Ethereum uses everywhere.
--
-- This is *not* SHA3-256. The two differ only in the padding byte (0x01 vs
-- 0x06) and produce completely different digests, and crypton exposes both as
-- @Keccak_256@ and @SHA3_256@. Confusing them is the classic way to write an
-- Ethereum implementation that is wrong in a way nothing catches until a
-- signature is rejected on-chain, so every Ethereum hash in this codebase goes
-- through this module rather than reaching for @Crypto.Hash@ directly.
module Simplex.Messaging.Eth.Keccak
  ( keccak256,
    keccak256Size,
  )
where

import Crypto.Hash (Digest, Keccak_256, hash)
import qualified Data.ByteArray as BA
import Data.ByteString (ByteString)

keccak256 :: ByteString -> ByteString
keccak256 bs = BA.convert (hash bs :: Digest Keccak_256)

keccak256Size :: Int
keccak256Size = 32
