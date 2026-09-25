{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

-- | BIP-32 HD derivation over secp256k1, private only: we hold the seed, so CKDpub, xpub and fingerprints are not implemented.
module Simplex.Messaging.Crypto.BIP32
  ( ExtendedKey (..),
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
import Control.Monad.Trans.Except (ExceptT (..), runExceptT)
import qualified Crypto.Hash as H
import Crypto.Random (ChaChaDRG)
import qualified Crypto.MAC.HMAC as HMAC
import Data.Bifunctor (bimap)
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
  | seedLen < 16 || seedLen > 64 =
      Left $ "seed: expected 16 to 64 bytes, got " <> show seedLen
  | otherwise =
      bimap (const "seed: invalid master key, use a different seed") (\k -> ExtendedKey {xkKey = k, xkChainCode = ir}) $
        S.mkPrivateKey il
  where
    seedLen = BA.length seed
    (il, ir) = BA.splitAt 32 $ hmacSHA512 "Bitcoin seed" seed

deriveChild :: TVar ChaChaDRG -> ExtendedKey -> Word32 -> IO (Either String ExtendedKey)
deriveChild g ExtendedKey {xkKey, xkChainCode} i = do
  dat <-
    if isHardened i
      then pure $ BA.cons 0 (S.unPrivateKey xkKey)
      else BA.convert <$> (S.serializePublicKey g S.Compressed =<< S.secp256k1PublicKey g xkKey)
  let (il, ir) = BA.splitAt 32 $ hmacSHA512 xkChainCode (dat <> BA.convert (smpEncode i))
  maybe (Left $ "derivation: invalid child at index " <> show i <> ", use the next index") (\k -> Right ExtendedKey {xkKey = k, xkChainCode = ir})
    <$> S.privateKeyTweakAdd g xkKey il

derivePath :: TVar ChaChaDRG -> ExtendedKey -> [Word32] -> IO (Either String ExtendedKey)
derivePath g xk = runExceptT . foldM (\k -> ExceptT . deriveChild g k) xk

renderPath :: [Word32] -> ByteString
renderPath is = BC.pack $ intercalate "/" ("m" : map component is)
  where
    component i
      | isHardened i = show (i - hardenedOffset) <> "'"
      | otherwise = show i

hmacSHA512 :: ScrubbedBytes -> ScrubbedBytes -> ScrubbedBytes
hmacSHA512 key msg = BA.convert (HMAC.hmac key msg :: HMAC.HMAC H.SHA512)

-- | Entropy with the master key it derives, so no derivation from it can fail.
data WalletMaster = WalletMaster
  { masterEntropy :: WalletEntropy,
    walletMasterKey :: ExtendedKey
  }

mkWalletMaster :: WalletEntropy -> ByteString -> Either String WalletMaster
mkWalletMaster ent passphrase = WalletMaster ent <$> masterKey (entropySeed ent passphrase)

-- | From storage: the master bytes must be the ones the entropy derives with an empty passphrase.
parseWalletMaster :: ScrubbedBytes -> ScrubbedBytes -> Either String WalletMaster
parseWalletMaster entBytes mBytes = do
  m <- (`mkWalletMaster` "") =<< mkEntropy entBytes
  if masterBytes m == mBytes then Right m else Left "wallet master: does not match the entropy"

masterBytes :: WalletMaster -> ScrubbedBytes
masterBytes WalletMaster {walletMasterKey = ExtendedKey {xkKey, xkChainCode}} = S.unPrivateKey xkKey <> xkChainCode
