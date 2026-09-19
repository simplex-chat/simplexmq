{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | BIP-39 mnemonics over the English wordlist.
--
-- Scope is deliberately narrow: English only. Every English word is ASCII, so
-- the Unicode NFKD normalization BIP-39 mandates is a no-op on the mnemonic
-- side and this module needs no normalization dependency. A passphrase, if
-- used, is taken as bytes and is the caller's responsibility to normalize.
--
-- A mnemonic is the root secret for name ownership, so 'Mnemonic' has a
-- redacting 'Show'.
module Simplex.Messaging.Crypto.BIP39
  ( Mnemonic,
    MnemonicStrength (..),
    mnemonicIndexes,
    mnemonicWords,
    mnemonicPhrase,
    entropyToMnemonic,
    mnemonicToEntropy,
    parseMnemonic,
    mnemonicToSeed,
    randomMnemonic,
    strengthBytes,
    strengthWordCount,
    seedSize,
    wordListSize,
  )
where

import Control.Concurrent.STM
import Crypto.Hash (Digest, SHA256, SHA512 (..), hash)
import qualified Crypto.KDF.PBKDF2 as PBKDF2
import Crypto.Random (ChaChaDRG, randomBytesGenerate)
import qualified Data.ByteArray as BA
import Data.Bits (shiftL, shiftR, (.&.), (.|.))
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as BC
import Data.Char (toLower)
import Data.IntMap.Strict (IntMap)
import qualified Data.IntMap.Strict as IM
import Data.List (foldl')
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import Simplex.Messaging.Crypto.BIP39.English (englishWordList)

-- | A validated BIP-39 mnemonic. Indexes and words are always consistent
-- because the constructor is private and every index is in @[0, 2047]@.
data Mnemonic = Mnemonic
  { mnemonicIndexes :: [Int],
    mnemonicWords :: [ByteString]
  }
  deriving (Eq)

instance Show Mnemonic where
  show m = "Mnemonic <" <> show (length (mnemonicIndexes m)) <> " words, redacted>"

-- | Entropy size, named by bit length as BIP-39 does.
data MnemonicStrength = MS128 | MS160 | MS192 | MS224 | MS256
  deriving (Eq, Show, Bounded, Enum)

strengthBytes :: MnemonicStrength -> Int
strengthBytes = \case
  MS128 -> 16
  MS160 -> 20
  MS192 -> 24
  MS224 -> 28
  MS256 -> 32

-- | 12, 15, 18, 21 or 24.
strengthWordCount :: MnemonicStrength -> Int
strengthWordCount s = (entBits + entBits `div` 32) `div` 11
  where
    entBits = strengthBytes s * 8

-- | BIP-39 seeds are always 64 bytes, whatever the entropy size.
seedSize :: Int
seedSize = 64

wordListSize :: Int
wordListSize = 2048

validEntropySizes :: [Int]
validEntropySizes = [16, 20, 24, 28, 32]

validWordCounts :: [Int]
validWordCounts = [12, 15, 18, 21, 24]

-- Wordlist indexes

wordByIndex :: IntMap ByteString
wordByIndex = IM.fromList $ zip [0 ..] englishWordList
{-# NOINLINE wordByIndex #-}

indexByWord :: Map ByteString Int
indexByWord = M.fromList $ zip englishWordList [0 ..]
{-# NOINLINE indexByWord #-}

-- | The mnemonic as one space-separated phrase — the exact bytes BIP-39 feeds
-- to PBKDF2.
mnemonicPhrase :: Mnemonic -> ByteString
mnemonicPhrase = BC.unwords . mnemonicWords

-- | Build a mnemonic from raw entropy of 16, 20, 24, 28 or 32 bytes.
entropyToMnemonic :: ByteString -> Either String Mnemonic
entropyToMnemonic ent
  | entLen `notElem` validEntropySizes =
      Left $ "entropy: expected 16, 20, 24, 28 or 32 bytes, got " <> show entLen
  | otherwise = Right $ mnemonicFromIndexes $ entropyToIndexes ent
  where
    entLen = B.length ent

-- | Entropy to 11-bit word indexes. Assumes a validated entropy length; every
-- result is masked to 11 bits, so all indexes are in @[0, 2047]@.
entropyToIndexes :: ByteString -> [Int]
entropyToIndexes ent =
  [fromIntegral ((combined `shiftR` (11 * (n - 1 - i))) .&. 0x7FF) | i <- [0 .. n - 1]]
  where
    entBits = B.length ent * 8
    csBits = entBits `div` 32
    -- csBits is at most 8 (256/32), so the first checksum byte always suffices.
    csByte = B.head (sha256 ent)
    combined = beToInteger ent `shiftL` csBits .|. fromIntegral (csByte `shiftR` (8 - csBits))
    n = (entBits + csBits) `div` 11

-- | Total: a 'Mnemonic' can only hold a valid word count and valid indexes.
mnemonicToEntropy :: Mnemonic -> ByteString
mnemonicToEntropy m = integerToBE (entBits `div` 8) (combined `shiftR` csBits)
  where
    idxs = mnemonicIndexes m
    totalBits = length idxs * 11
    entBits = totalBits * 32 `div` 33
    csBits = totalBits - entBits
    combined = foldl' (\acc i -> acc `shiftL` 11 .|. fromIntegral i) (0 :: Integer) idxs

-- | Parse and fully validate a phrase: word count, wordlist membership, and the
-- BIP-39 checksum. Words may be separated by any whitespace, and input is
-- lower-cased first, so a user retyping their recovery key does not get an
-- unhelpful failure for capitalising a word. This does not change the derived
-- seed: 'mnemonicPhrase' always rebuilds the canonical lowercase sentence from
-- the wordlist, and that is what 'mnemonicToSeed' hashes.
parseMnemonic :: ByteString -> Either String Mnemonic
parseMnemonic phrase
  | n `notElem` validWordCounts =
      Left $ "mnemonic: expected 12, 15, 18, 21 or 24 words, got " <> show n
  | otherwise = do
      idxs <- traverse lookupWord ws
      let m = mnemonicFromIndexes idxs
      -- Stripping the checksum bits and recomputing them is the checksum check:
      -- if the supplied bits were wrong, the round trip cannot reproduce them.
      if entropyToIndexes (mnemonicToEntropy m) == idxs
        then Right m
        else Left "mnemonic: checksum mismatch"
  where
    ws = BC.words $ BC.map toLower phrase
    n = length ws
    lookupWord w =
      maybe (Left $ "mnemonic: not in wordlist: " <> BC.unpack w) Right $ M.lookup w indexByWord

-- | PBKDF2-HMAC-SHA512, 2048 iterations, salt @\"mnemonic\" <> passphrase@.
-- Pass an empty passphrase for the common case.
mnemonicToSeed :: Mnemonic -> ByteString -> ByteString
mnemonicToSeed m passphrase =
  PBKDF2.generate
    (PBKDF2.prfHMAC SHA512)
    PBKDF2.Parameters {PBKDF2.iterCounts = 2048, PBKDF2.outputLength = seedSize}
    (mnemonicPhrase m)
    ("mnemonic" <> passphrase :: ByteString)

-- | Generate a fresh mnemonic. Shaped like 'Simplex.Messaging.Crypto.randomBytes'
-- so it composes with the agent's DRG instead of reaching for system entropy.
randomMnemonic :: MnemonicStrength -> TVar ChaChaDRG -> STM Mnemonic
randomMnemonic s gVar = do
  ent <- stateTVar gVar $ randomBytesGenerate (strengthBytes s)
  pure $ mnemonicFromIndexes $ entropyToIndexes ent

-- Internal

-- | Indexes must be in @[0, 2047]@; both call paths guarantee that (an 11-bit
-- mask, or a lookup in the wordlist itself). The default is the empty word so
-- that a violation would fail loudly downstream rather than silently produce a
-- different valid mnemonic.
mnemonicFromIndexes :: [Int] -> Mnemonic
mnemonicFromIndexes idxs =
  Mnemonic {mnemonicIndexes = idxs, mnemonicWords = map wordAt idxs}
  where
    wordAt i = IM.findWithDefault "" i wordByIndex

sha256 :: ByteString -> ByteString
sha256 bs = BA.convert (hash bs :: Digest SHA256)

beToInteger :: ByteString -> Integer
beToInteger = B.foldl' (\acc w -> acc `shiftL` 8 .|. fromIntegral w) 0

integerToBE :: Int -> Integer -> ByteString
integerToBE n x = B.pack [fromIntegral (x `shiftR` (8 * (n - 1 - i))) | i <- [0 .. n - 1]]
