{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

-- | BIP-32 HD derivation over secp256k1, private only: we hold the seed, so CKDpub, xpub and fingerprints are not implemented. An invalid master or child key is recomputed as SLIP-0010 specifies, up to two times.
module Simplex.Messaging.Crypto.BIP32
  ( ExtendedKey,
    xkKey,
    xkChainCode,
    masterKey,
    derivePath,
    derivePath_,
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
import qualified Crypto.MAC.HMAC as HMAC
import Crypto.Random (ChaChaDRG)
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
  | otherwise = go attempts seed
  where
    seedLen = BA.length seed
    go :: Int -> ScrubbedBytes -> Either String ExtendedKey
    go 0 _ = Left derivationFailed
    go n s = case S.mkPrivateKey il of
      Right k -> Right ExtendedKey {xkKey = k, xkChainCode = ir}
      Left _ -> go (n - 1) i
      where
        i = hmacSHA512 "Bitcoin seed" s
        (il, ir) = BA.splitAt 32 i

deriveChild :: S.Secp256k1Context -> ExtendedKey -> Word32 -> IO (Either String ExtendedKey)
deriveChild ctx ExtendedKey {xkKey, xkChainCode} i = do
  dat <-
    if isHardened i
      then pure $ BA.cons 0 (S.unPrivateKey xkKey)
      else BA.convert . S.serializePublicKey S.Compressed <$> S.secp256k1PublicKey_ ctx xkKey
  pure $ go attempts dat
  where
    go :: Int -> ScrubbedBytes -> Either String ExtendedKey
    go 0 _ = Left derivationFailed
    go n dat = case S.privateKeyTweakAdd xkKey il of
      Just k -> Right ExtendedKey {xkKey = k, xkChainCode = ir}
      Nothing -> go (n - 1) $ BA.cons 1 ir
      where
        (il, ir) = BA.splitAt 32 $ hmacSHA512 xkChainCode (dat <> BA.convert (smpEncode i))

derivePath :: TVar ChaChaDRG -> ExtendedKey -> [Word32] -> IO (Either String ExtendedKey)
derivePath g xk path = S.withContext g $ \ctx -> derivePath_ ctx xk path

derivePath_ :: S.Secp256k1Context -> ExtendedKey -> [Word32] -> IO (Either String ExtendedKey)
derivePath_ ctx xk = runExceptT . foldM (\k -> ExceptT . deriveChild ctx k) xk

attempts :: Int
attempts = 3

derivationFailed :: String
derivationFailed = "derivation failed after " <> show attempts <> " attempts"

renderPath :: [Word32] -> ByteString
renderPath is = BC.pack $ intercalate "/" ("m" : map component is)
  where
    component i
      | isHardened i = show (i - hardenedOffset) <> "'"
      | otherwise = show i

hmacSHA512 :: ScrubbedBytes -> ScrubbedBytes -> ScrubbedBytes
hmacSHA512 key msg = BA.convert (HMAC.hmac key msg :: HMAC.HMAC H.SHA512)

-- | Entropy with the master key it derives.
data WalletMaster = WalletMaster WalletEntropy ExtendedKey

masterEntropy :: WalletMaster -> WalletEntropy
masterEntropy (WalletMaster ent _) = ent

walletMasterKey :: WalletMaster -> ExtendedKey
walletMasterKey (WalletMaster _ k) = k

mkWalletMaster :: WalletEntropy -> Either String WalletMaster
mkWalletMaster ent = WalletMaster ent <$> masterKey (entropySeed ent "")

-- | From storage: the master bytes must be the ones the entropy derives.
parseWalletMaster :: ScrubbedBytes -> ScrubbedBytes -> Either String WalletMaster
parseWalletMaster entBytes mBytes = do
  m <- mkWalletMaster =<< mkEntropy entBytes
  if masterBytes m == mBytes then Right m else Left "wallet master: does not match the entropy"

masterBytes :: WalletMaster -> ScrubbedBytes
masterBytes (WalletMaster _ ExtendedKey {xkKey, xkChainCode}) = S.unPrivateKey xkKey <> xkChainCode
