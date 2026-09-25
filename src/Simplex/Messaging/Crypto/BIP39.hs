{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | BIP-39 mnemonics, English only: every word is ASCII, any Unicode space character separates words, and full NFKD normalization is not applied; a passphrase is bytes the caller normalizes.
module Simplex.Messaging.Crypto.BIP39
  ( WalletEntropy (unEntropy),
    WalletSeed (unSeed),
    Mnemonic, -- ???
    EntropyStrength (..),
    -- mnemonicWords,
    mnemonicPhrase,
    entropyToMnemonic,
    mnemonicToEntropy,
    parseMnemonic,
    mnemonicToSeed,
    -- randomMnemonic,
    strengthWordCount, -- ???
  )
where

import Control.Concurrent.STM
import Crypto.Hash (Digest, SHA256, SHA512 (..), hash)
import qualified Crypto.KDF.PBKDF2 as PBKDF2
import Crypto.Number.Serialize (i2ospOf_, os2ip)
import Crypto.Random (ChaChaDRG, randomBytesGenerate)
import qualified Data.Attoparsec.Text as A
import Data.Bits (shiftL, shiftR, (.&.), (.|.))
import Data.ByteArray (ScrubbedBytes)
import qualified Data.ByteArray as BA
import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as BC
import Data.Char (isSpace)
import Data.IntMap.Strict (IntMap)
import qualified Data.IntMap.Strict as IM
import Data.List (foldl')
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Encoding (encodeUtf8)
import Simplex.Messaging.Crypto.BIP39.English (englishWordList)

newtype WalletSeed =
  WalletSeed
    { entropy :: ScrubbedBytes, -- multi-size
      seed :: ScrubbedBytes -- 64 bytes
    }
  deriving (ToField)

mkWalletSeed :: ScrubbedBytes -> ScrubbedBytes -> Either String WalletSeed
mkWalletSeed entropy seed
  | seed /= seedSize = Left "bad WalletSeed: seed size"
  | s `notElem` validEntropySizes =  Left "bad WalletSeed: entropy size"
  | ... = Left "..." -- establish consistency
  | oehRight $ WalletSeed s

mkEntropy :: ScrubbedBytes -> Either String WalletEntropy
mkEntropy s
  | s `elem` validEntropySizes = Right $ WalletEntropy s
  | otherwise = Left "bad WalletEntropy"

getWalletEntropy :: TVar ChaChaDRG -> EntropyStrength -> STM WalletEntropy
getWalletEntropy gVar = stateTVar gVar . randomBytesGenerate . strengthBytes

newtype Mnemonic = Mnemonic {mnemonicIndexes :: [Int]}
  deriving (Eq, Show)

data EntropyStrength = ES128 | ES160 | ES192 | ES224 | ES256
  deriving (Eq, Show, Bounded, Enum)

strengthBytes :: EntropyStrength -> Int
strengthBytes = \case
  ES128 -> 16
  ES160 -> 20
  ES192 -> 24
  ES224 -> 28
  ES256 -> 32

strengthWordCount :: EntropyStrength -> Int
strengthWordCount s = (entBits + entBits `div` 32) `div` 11
  where
    entBits = strengthBytes s * 8

newtype WalletSeed = WalletSeed {unSeed :: ScrubbedBytes}

seedSize :: Int
seedSize = 64

validEntropySizes :: [Int]
validEntropySizes = map strengthBytes [minBound .. maxBound]

validWordCounts :: [Int]
validWordCounts = map strengthWordCount [minBound .. maxBound]

wordByIndex :: IntMap ByteString
wordByIndex = IM.fromList $ zip [0 ..] englishWordList

indexByWord :: Map ByteString Int
indexByWord = M.fromList $ zip englishWordList [0 ..]

-- | Indexes are in @[0, 2047]@: they are masked to 11 bits or looked up in the wordlist.
mnemonicWords :: Mnemonic -> [ByteString]
mnemonicWords = map (wordByIndex IM.!) . mnemonicIndexes

-- | The words joined by single spaces, the PBKDF2 password BIP-39 specifies.
mnemonicPhrase :: WalletEntropy -> ByteString
mnemonicPhrase = BC.unwords . mnemonicWords

-- entropyToMnemonic :: WalletEntropy -> Mnemonic
-- entropyToMnemonic = Mnemonic . entropyToIndexes

-- entropyToMnemonic :: ScrubbedBytes -> Either String Mnemonic
-- entropyToMnemonic ent
--   | entLen `notElem` validEntropySizes =
--       Left $ "entropy: expected 16, 20, 24, 28 or 32 bytes, got " <> show entLen
--   | otherwise = Right $ Mnemonic $ entropyToIndexes ent
--   where
--     entLen = BA.length ent

entropyToIndexes :: WalletEntropy -> Mnemonic
entropyToIndexes (WalletEntropy ent) =
  [fromIntegral ((combined `shiftR` (11 * (n - 1 - i))) .&. 0x7FF) | i <- [0 .. n - 1]]
  where
    entBits = BA.length ent * 8
    csBits = entBits `div` 32
    -- csBits is at most 8 (256/32), so the first checksum byte always suffices.
    csByte = BA.index (hash ent :: Digest SHA256) 0
    combined = os2ip ent `shiftL` csBits .|. fromIntegral (csByte `shiftR` (8 - csBits))
    n = (entBits + csBits) `div` 11

mnemonicToEntropy :: Mnemonic -> ScrubbedBytes
mnemonicToEntropy idxs = i2ospOf_ (entBits `div` 8) (combined `shiftR` csBits)
  where
    totalBits = length idxs * 11
    entBits = totalBits * 32 `div` 33
    csBits = totalBits - entBits
    combined = foldl' (\acc i -> acc `shiftL` 11 .|. fromIntegral i) (0 :: Integer) idxs

parseMnemonic :: Text -> Either String Mnemonic
parseMnemonic = A.parseOnly (mnemonicP <* A.endOfInput)

mnemonicP :: A.Parser Mnemonic
mnemonicP = do
  ws <- A.skipSpace *> (wordP `A.sepBy'` A.takeWhile1 isSpace) <* A.skipSpace
  let n = length ws
  if n `notElem` validWordCounts
    then fail $ "mnemonic: expected 12, 15, 18, 21 or 24 words, got " <> show n
    else do
      idxs <- traverse lookupWord ws
      let m = Mnemonic idxs
      -- recomputing the checksum bits from the decoded entropy rejects wrong checksum bits
      if entropyToIndexes (mnemonicToEntropy m) == idxs
        then pure m
        else fail "mnemonic: checksum mismatch"
  where
    wordP = T.toLower <$> A.takeWhile1 (not . isSpace)
    lookupWord w = maybe (fail $ "mnemonic: not in wordlist: " <> T.unpack w) pure $ M.lookup (encodeUtf8 w) indexByWord

walletEntropyToSeed :: WalletEntropy -> ByteString -> ScrubbedBytes -- Either String WalletSeed ?
walletEntropyToSeed ent passphrase =
  PBKDF2.generate
    (PBKDF2.prfHMAC SHA512)
    PBKDF2.Parameters {PBKDF2.iterCounts = 2048, PBKDF2.outputLength = seedSize}
    (mnemonicPhrase ent)
    ("mnemonic" <> passphrase :: ByteString)

-- randomMnemonic :: EntropyStrength -> TVar ChaChaDRG -> STM Mnemonic
-- randomMnemonic s gVar = Mnemonic . entropyToIndexes <$> stateTVar gVar (randomBytesGenerate $ strengthBytes s)
