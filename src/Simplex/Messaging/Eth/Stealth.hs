{-# LANGUAGE OverloadedStrings #-}

-- | ERC-5564 stealth addresses on secp256k1, scheme id 1 ("with view tags").
--
-- A recipient publishes a __meta-address__: two public keys, spending and
-- viewing. A sender picks a random ephemeral key, derives a one-time address
-- from it and the meta-address, and publishes the ephemeral public key. Only
-- the recipient — who holds the viewing key — can tell which one-time addresses
-- are theirs, and only they can spend from them.
--
-- The meta-address is not an address and never appears on chain, so publishing
-- it discloses nothing beyond the ability to send to its owner.
--
-- == Interoperability
--
-- ERC-5564 specifies the algebra but /not/ how the shared-secret point is
-- serialized before hashing, nor which hash is used. Those come from the EIP
-- author's reference implementation
-- (<https://github.com/Nerolation/EIP-Stealth-Address-ERC> @minimal_poc.ipynb@):
--
--   * the shared secret point is serialized __uncompressed with no SEC1 prefix__,
--     as @x || y@, 64 bytes;
--   * it is hashed with __keccak256__, not SHA-256 — which is why this module
--     multiplies points directly rather than calling @secp256k1_ecdh@, whose
--     built-in hash is SHA-256;
--   * the __view tag is the first byte__ of that hash.
--
-- Encoding the point the same way an Ethereum address encodes a public key is
-- not a coincidence, and it means 'Simplex.Messaging.Eth.Address' already
-- performs the last step unchanged.
module Simplex.Messaging.Eth.Stealth
  ( StealthMetaAddress (..),
    ViewTag,
    StealthDestination (..),
    metaAddress,
    metaAddressBytes,
    parseMetaAddress,
    metaAddressSize,
    stealthDestination,
    stealthMatch,
    stealthPrivateKey,
    sharedSecretHash,
  )
where

import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import Data.Word (Word8)
import Simplex.Messaging.Eth.Address (Address, addressFromPublicKey)
import Simplex.Messaging.Eth.Keccak (keccak256)
import qualified Simplex.Messaging.Crypto.Secp256k1 as S

-- | A recipient's published key pair: spending key, then viewing key.
data StealthMetaAddress = StealthMetaAddress
  { smaSpend :: S.PublicKey,
    smaView :: S.PublicKey
  }
  deriving (Eq, Show)

-- | The first byte of the hashed shared secret. Lets a recipient discard about
-- 255 announcements in 256 with one point multiplication and one hash, instead
-- of also deriving an address for each.
type ViewTag = Word8

-- | What a sender produces and publishes.
data StealthDestination = StealthDestination
  { -- | Where to send. Unlinkable to the meta-address it came from.
    sdAddress :: Address,
    -- | The ephemeral public key, compressed. Must reach the recipient, either
    -- in an announcement event or a message, or the destination is
    -- undiscoverable.
    sdEphemeralPubKey :: ByteString,
    sdViewTag :: ViewTag
  }
  deriving (Eq, Show)

metaAddress :: S.PrivateKey -> S.PrivateKey -> StealthMetaAddress
metaAddress spend view =
  StealthMetaAddress {smaSpend = S.publicKey spend, smaView = S.publicKey view}

metaAddressSize :: Int
metaAddressSize = 2 * S.compressedSize

-- | Spending key then viewing key, both compressed. 66 bytes.
metaAddressBytes :: StealthMetaAddress -> ByteString
metaAddressBytes ma = pub (smaSpend ma) <> pub (smaView ma)
  where
    pub = S.serializePublicKey S.Compressed

parseMetaAddress :: ByteString -> Either String StealthMetaAddress
parseMetaAddress bs
  | B.length bs /= metaAddressSize =
      Left $ "meta-address: expected " <> show metaAddressSize <> " bytes, got " <> show (B.length bs)
  | otherwise = do
      let (spend, view) = B.splitAt S.compressedSize bs
      StealthMetaAddress <$> S.parsePublicKey spend <*> S.parsePublicKey view

-- | @keccak256(x || y)@ of @sk * P@ — the value both sides arrive at, the
-- sender from the ephemeral key and the recipient from the viewing key.
sharedSecretHash :: S.PrivateKey -> S.PublicKey -> Either String ByteString
sharedSecretHash sk pk =
  case S.publicKeyTweakMul pk (S.unPrivateKey sk) of
    Nothing -> Left "stealth: shared secret is not a valid point"
    Just p -> Right . keccak256 . B.drop 1 $ S.serializePublicKey S.Uncompressed p

-- | Sender side. @ephemeral@ must be freshly random and used once: reusing it
-- across recipients lets them link the destinations, and reusing it for one
-- recipient produces the same address twice.
stealthDestination :: S.PrivateKey -> StealthMetaAddress -> Either String StealthDestination
stealthDestination ephemeral ma = do
  sh <- sharedSecretHash ephemeral (smaView ma)
  stealthPub <- tweakSpend (smaSpend ma) sh
  pure
    StealthDestination
      { sdAddress = addressFromPublicKey stealthPub,
        sdEphemeralPubKey = S.serializePublicKey S.Compressed (S.publicKey ephemeral),
        sdViewTag = B.head sh
      }

-- | Recipient side. Returns the address when this announcement is ours.
--
-- The view tag is checked before the point addition, which is the whole reason
-- it exists — a non-match costs one multiplication and one hash.
stealthMatch :: S.PrivateKey -> S.PublicKey -> ByteString -> ViewTag -> Either String (Maybe Address)
stealthMatch view spend ephemeralPub tag = do
  eph <- S.parsePublicKey ephemeralPub
  sh <- sharedSecretHash view eph
  if B.head sh /= tag
    then pure Nothing
    else Just . addressFromPublicKey <$> tweakSpend spend sh

-- | Recipient side. The key that controls a matched destination: @p_spend + s_h@.
--
-- Needs the spending key, which is why a viewing key can be delegated for
-- scanning without granting the ability to spend.
stealthPrivateKey :: S.PrivateKey -> S.PrivateKey -> ByteString -> Either String S.PrivateKey
stealthPrivateKey spend view ephemeralPub = do
  eph <- S.parsePublicKey ephemeralPub
  sh <- sharedSecretHash view eph
  case S.privateKeyTweakAdd spend sh of
    Nothing -> Left "stealth: derived key out of range"
    Just sk -> Right sk

tweakSpend :: S.PublicKey -> ByteString -> Either String S.PublicKey
tweakSpend spend sh = case S.publicKeyTweakAdd spend sh of
  Nothing -> Left "stealth: derived point out of range"
  Just p -> Right p
