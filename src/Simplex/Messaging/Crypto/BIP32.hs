{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

-- | BIP-32 HD derivation over secp256k1, private only: we hold the seed, so CKDpub, xpub and fingerprints are not implemented. An invalid master or child key is recomputed as SLIP-0010 specifies, so derivation cannot fail.
module Simplex.Messaging.Crypto.BIP32
  ( ExtendedKey,
    xkKey,
    xkChainCode,
    masterKey,
    derivePath,
    renderPath,
    hardened,
    isHardened,
    WalletMaster,
    masterEntropy,
    walletMasterKey,
    mkWalletMaster,
    parseWalletMaster,
    masterBytes,
  )
where

import Control.Concurrent.STM (TVar)
import Control.Monad (foldM)
import qualified Crypto.Hash as H
import Crypto.Random (ChaChaDRG)
import qualified Crypto.MAC.HMAC as HMAC
import Data.Bits ((.|.))
import Data.ByteArray (ScrubbedBytes)
import qualified Data.ByteArray as BA
import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as BC
import Data.List (intercalate)
import Data.Word (Word32)
import Simplex.Messaging.Crypto.BIP39 (WalletEntropy, entropySeed, mkEntropy)
import qualified Simplex.Messaging.Crypto.Secp256k1 as S
import Simplex.Messaging.Encoding (smpEncode)

data ExtendedKey = ExtendedKey
  { xkKey :: S.Secp256k1PrivateKey,
    xkChainCode :: ScrubbedBytes
  }
  deriving (Eq)

hardenedOffset :: Word32
hardenedOffset = 0x80000000

hardened :: Word32 -> Word32
hardened = (.|. hardenedOffset)

isHardened :: Word32 -> Bool
isHardened i = i >= hardenedOffset

masterKey :: ScrubbedBytes -> Either String ExtendedKey
masterKey seed
  | seedLen < 16 || seedLen > 64 = Left $ "seed: expected 16 to 64 bytes, got " <> show seedLen
  | otherwise = Right $ masterKey' seed
  where
    seedLen = BA.length seed

masterKey' :: ScrubbedBytes -> ExtendedKey
masterKey' = go
  where
    go s = case S.mkPrivateKey il of
      Right k -> ExtendedKey {xkKey = k, xkChainCode = ir}
      Left _ -> go i
      where
        i = hmacSHA512 "Bitcoin seed" s
        (il, ir) = BA.splitAt 32 i

deriveChild :: TVar ChaChaDRG -> ExtendedKey -> Word32 -> IO ExtendedKey
deriveChild g ExtendedKey {xkKey, xkChainCode} i = do
  dat <-
    if isHardened i
      then pure $ BA.cons 0 (S.unPrivateKey xkKey)
      else BA.convert <$> (S.serializePublicKey g S.Compressed =<< S.secp256k1PublicKey g xkKey)
  go dat
  where
    go dat = do
      let (il, ir) = BA.splitAt 32 $ hmacSHA512 xkChainCode (dat <> BA.convert (smpEncode i))
      S.privateKeyTweakAdd g xkKey il >>= \case
        Just k -> pure ExtendedKey {xkKey = k, xkChainCode = ir}
        Nothing -> go $ BA.cons 1 ir

derivePath :: TVar ChaChaDRG -> ExtendedKey -> [Word32] -> IO ExtendedKey
derivePath g = foldM (deriveChild g)

renderPath :: [Word32] -> ByteString
renderPath is = BC.pack $ intercalate "/" ("m" : map component is)
  where
    component i
      | isHardened i = show (i - hardenedOffset) <> "'"
      | otherwise = show i

hmacSHA512 :: ScrubbedBytes -> ScrubbedBytes -> ScrubbedBytes
hmacSHA512 key msg = BA.convert (HMAC.hmac key msg :: HMAC.HMAC H.SHA512)

-- | Entropy with the master key it derives, so no derivation from it can fail.
data WalletMaster = WalletMaster WalletEntropy ExtendedKey

masterEntropy :: WalletMaster -> WalletEntropy
masterEntropy (WalletMaster ent _) = ent

walletMasterKey :: WalletMaster -> ExtendedKey
walletMasterKey (WalletMaster _ k) = k

mkWalletMaster :: WalletEntropy -> WalletMaster
mkWalletMaster ent = WalletMaster ent $ masterKey' (entropySeed ent "")

-- | From storage: the master bytes must be the ones the entropy derives.
parseWalletMaster :: ScrubbedBytes -> ScrubbedBytes -> Either String WalletMaster
parseWalletMaster entBytes mBytes = do
  m <- mkWalletMaster <$> mkEntropy entBytes
  if masterBytes m == mBytes then Right m else Left "wallet master: does not match the entropy"

masterBytes :: WalletMaster -> ScrubbedBytes
masterBytes (WalletMaster _ ExtendedKey {xkKey, xkChainCode}) = S.unPrivateKey xkKey <> xkChainCode
