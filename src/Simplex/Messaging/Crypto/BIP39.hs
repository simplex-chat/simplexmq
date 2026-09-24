{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | BIP-39 mnemonics, English only: every word is ASCII, so BIP-39's NFKD normalization is a no-op; a passphrase is bytes the caller normalizes.
module Simplex.Messaging.Crypto.BIP39
  ( Mnemonic,
    MnemonicStrength (..),
    mnemonicWords,
    mnemonicPhrase,
    entropyToMnemonic,
    mnemonicToEntropy,
    parseMnemonic,
    mnemonicToSeed,
    randomMnemonic,
    strengthWordCount,
  )
where

import Control.Concurrent.STM
import Crypto.Hash (Digest, SHA256, SHA512 (..), hash)
import qualified Crypto.KDF.PBKDF2 as PBKDF2
import Crypto.Number.Serialize (i2ospOf_, os2ip)
import Crypto.Random (ChaChaDRG)
import qualified Data.Attoparsec.ByteString.Char8 as A
import Data.Bits (shiftL, shiftR, (.&.), (.|.))
import Data.ByteArray (ScrubbedBytes)
import qualified Data.ByteArray as BA
import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as BC
import Data.Char (isSpace, toLower)
import Data.IntMap.Strict (IntMap)
import qualified Data.IntMap.Strict as IM
import Data.List (foldl')
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Crypto.BIP39.English (englishWordList)
import Simplex.Messaging.Parsers (parseAll)

data Mnemonic = Mnemonic
  { mnemonicIndexes :: [Int],
    mnemonicWords :: [ByteString]
  }
  deriving (Eq, Show)

data MnemonicStrength = MS128 | MS160 | MS192 | MS224 | MS256
  deriving (Eq, Show, Bounded, Enum)

strengthBytes :: MnemonicStrength -> Int
strengthBytes = \case
  MS128 -> 16
  MS160 -> 20
  MS192 -> 24
  MS224 -> 28
  MS256 -> 32

strengthWordCount :: MnemonicStrength -> Int
strengthWordCount s = (entBits + entBits `div` 32) `div` 11
  where
    entBits = strengthBytes s * 8

seedSize :: Int
seedSize = 64

validEntropySizes :: [Int]
validEntropySizes = map strengthBytes [minBound .. maxBound]

validWordCounts :: [Int]
validWordCounts = map strengthWordCount [minBound .. maxBound]

-- Wordlist indexes

wordByIndex :: IntMap ByteString
wordByIndex = IM.fromList $ zip [0 ..] englishWordList

indexByWord :: Map ByteString Int
indexByWord = M.fromList $ zip englishWordList [0 ..]

-- | The words joined by single spaces, the PBKDF2 password BIP-39 specifies.
mnemonicPhrase :: Mnemonic -> ByteString
mnemonicPhrase = BC.unwords . mnemonicWords

entropyToMnemonic :: ScrubbedBytes -> Either String Mnemonic
entropyToMnemonic ent
  | entLen `notElem` validEntropySizes =
      Left $ "entropy: expected 16, 20, 24, 28 or 32 bytes, got " <> show entLen
  | otherwise = Right $ mnemonicFromIndexes $ entropyToIndexes ent
  where
    entLen = BA.length ent

entropyToIndexes :: BA.ByteArrayAccess ba => ba -> [Int]
entropyToIndexes ent =
  [fromIntegral ((combined `shiftR` (11 * (n - 1 - i))) .&. 0x7FF) | i <- [0 .. n - 1]]
  where
    entBits = BA.length ent * 8
    csBits = entBits `div` 32
    -- csBits is at most 8 (256/32), so the first checksum byte always suffices.
    csByte = BA.index (hash ent :: Digest SHA256) 0
    combined = os2ip ent `shiftL` csBits .|. fromIntegral (csByte `shiftR` (8 - csBits))
    n = (entBits + csBits) `div` 11

mnemonicToEntropy :: Mnemonic -> ScrubbedBytes
mnemonicToEntropy m = i2ospOf_ (entBits `div` 8) (combined `shiftR` csBits)
  where
    idxs = mnemonicIndexes m
    totalBits = length idxs * 11
    entBits = totalBits * 32 `div` 33
    csBits = totalBits - entBits
    combined = foldl' (\acc i -> acc `shiftL` 11 .|. fromIntegral i) (0 :: Integer) idxs

parseMnemonic :: ByteString -> Either String Mnemonic
parseMnemonic = parseAll mnemonicP

mnemonicP :: A.Parser Mnemonic
mnemonicP = do
  ws <- A.skipWhile isSpace *> (wordP `A.sepBy'` A.takeWhile1 isSpace) <* A.skipWhile isSpace
  let n = length ws
  if n `notElem` validWordCounts
    then fail $ "mnemonic: expected 12, 15, 18, 21 or 24 words, got " <> show n
    else do
      idxs <- traverse lookupWord ws
      let m = mnemonicFromIndexes idxs
      -- recomputing the checksum bits from the decoded entropy rejects wrong checksum bits
      if entropyToIndexes (mnemonicToEntropy m) == idxs
        then pure m
        else fail "mnemonic: checksum mismatch"
  where
    wordP = BC.map toLower <$> A.takeWhile1 (not . isSpace)
    lookupWord w = maybe (fail $ "mnemonic: not in wordlist: " <> BC.unpack w) pure $ M.lookup w indexByWord

mnemonicToSeed :: Mnemonic -> ByteString -> ScrubbedBytes
mnemonicToSeed m passphrase =
  PBKDF2.generate
    (PBKDF2.prfHMAC SHA512)
    PBKDF2.Parameters {PBKDF2.iterCounts = 2048, PBKDF2.outputLength = seedSize}
    (mnemonicPhrase m)
    ("mnemonic" <> passphrase :: ByteString)

randomMnemonic :: MnemonicStrength -> TVar ChaChaDRG -> STM Mnemonic
randomMnemonic s gVar = mnemonicFromIndexes . entropyToIndexes <$> C.randomBytes (strengthBytes s) gVar

-- Internal

-- | Indexes are in @[0, 2047]@: an 11-bit mask, or a lookup in the wordlist itself.
mnemonicFromIndexes :: [Int] -> Mnemonic
mnemonicFromIndexes idxs =
  Mnemonic {mnemonicIndexes = idxs, mnemonicWords = map (wordByIndex IM.!) idxs}
