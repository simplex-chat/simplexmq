{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | BIP-39 mnemonics, English only: every word is ASCII, any Unicode space character separates words, and full NFKD normalization is not applied; a passphrase is bytes the caller normalizes.
module Simplex.Messaging.Crypto.BIP39
  ( WalletEntropy,
    unEntropy,
    EntropyStrength (..),
    mkEntropy,
    randomEntropy,
    parsePhrase,
    entropyPhrase,
    entropyStrength,
    entropySeed,
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

-- | 16, 20, 24, 28 or 32 bytes of entropy: a valid BIP-39 phrase in another encoding.
newtype WalletEntropy = WalletEntropy ScrubbedBytes
  deriving (Eq, Show)

unEntropy :: WalletEntropy -> ScrubbedBytes
unEntropy (WalletEntropy ent) = ent

data EntropyStrength = ES128 | ES160 | ES192 | ES224 | ES256
  deriving (Eq, Show, Bounded, Enum)

newtype Mnemonic = Mnemonic [Int]
  deriving (Eq)

strengthBytes :: EntropyStrength -> Int
strengthBytes = \case
  ES128 -> 16
  ES160 -> 20
  ES192 -> 24
  ES224 -> 28
  ES256 -> 32

wordCount :: Int -> Int
wordCount entBytes = (entBits + entBits `div` 32) `div` 11
  where
    entBits = entBytes * 8

seedSize :: Int
seedSize = 64

validEntropySizes :: [Int]
validEntropySizes = map strengthBytes [minBound .. maxBound]

validWordCounts :: [Int]
validWordCounts = map wordCount validEntropySizes

wordByIndex :: IntMap ByteString
wordByIndex = IM.fromList $ zip [0 ..] englishWordList

indexByWord :: Map ByteString Int
indexByWord = M.fromList $ zip englishWordList [0 ..]

mkEntropy :: ScrubbedBytes -> Either String WalletEntropy
mkEntropy ent
  | entLen `elem` validEntropySizes = Right $ WalletEntropy ent
  | otherwise = Left $ "entropy: expected 16, 20, 24, 28 or 32 bytes, got " <> show entLen
  where
    entLen = BA.length ent

randomEntropy :: EntropyStrength -> TVar ChaChaDRG -> STM WalletEntropy
randomEntropy s gVar = WalletEntropy <$> stateTVar gVar (randomBytesGenerate $ strengthBytes s)

-- | The words joined by single spaces, the PBKDF2 password BIP-39 specifies.
entropyPhrase :: WalletEntropy -> ByteString
entropyPhrase = BC.unwords . mnemonicWords . entropyToMnemonic

entropyStrength :: WalletEntropy -> EntropyStrength
entropyStrength (WalletEntropy ent) = toEnum $ (BA.length ent - 16) `div` 4

-- | Indexes are in @[0, 2047]@: they are masked to 11 bits or looked up in the wordlist.
mnemonicWords :: Mnemonic -> [ByteString]
mnemonicWords (Mnemonic idxs) = map (wordByIndex IM.!) idxs

entropyToMnemonic :: WalletEntropy -> Mnemonic
entropyToMnemonic (WalletEntropy ent) =
  Mnemonic [fromIntegral ((combined `shiftR` (11 * (n - 1 - i))) .&. 0x7FF) | i <- [0 .. n - 1]]
  where
    entBits = BA.length ent * 8
    csBits = entBits `div` 32
    -- csBits is at most 8 (256/32), so the first checksum byte always suffices.
    csByte = BA.index (hash ent :: Digest SHA256) 0
    combined = os2ip ent `shiftL` csBits .|. fromIntegral (csByte `shiftR` (8 - csBits))
    n = (entBits + csBits) `div` 11

mnemonicToEntropy :: Mnemonic -> WalletEntropy
mnemonicToEntropy (Mnemonic idxs) = WalletEntropy $ i2ospOf_ (entBits `div` 8) (combined `shiftR` csBits)
  where
    totalBits = length idxs * 11
    entBits = totalBits * 32 `div` 33
    csBits = totalBits - entBits
    combined = foldl' (\acc i -> acc `shiftL` 11 .|. fromIntegral i) (0 :: Integer) idxs

parsePhrase :: Text -> Either String WalletEntropy
parsePhrase = A.parseOnly (phraseP <* A.endOfInput)

phraseP :: A.Parser WalletEntropy
phraseP = do
  ws <- A.skipSpace *> (wordP `A.sepBy'` A.takeWhile1 isSpace) <* A.skipSpace
  let n = length ws
  if n `notElem` validWordCounts
    then fail $ "mnemonic: expected 12, 15, 18, 21 or 24 words, got " <> show n
    else do
      m <- Mnemonic <$> traverse lookupWord ws
      let ent = mnemonicToEntropy m
      -- recomputing the checksum bits from the decoded entropy rejects wrong checksum bits
      if entropyToMnemonic ent == m
        then pure ent
        else fail "mnemonic: checksum mismatch"
  where
    wordP = T.toLower <$> A.takeWhile1 (not . isSpace)
    lookupWord w = maybe (fail $ "mnemonic: not in wordlist: " <> T.unpack w) pure $ M.lookup (encodeUtf8 w) indexByWord

entropySeed :: WalletEntropy -> ByteString -> ScrubbedBytes
entropySeed ent passphrase =
  PBKDF2.generate
    (PBKDF2.prfHMAC SHA512)
    PBKDF2.Parameters {PBKDF2.iterCounts = 2048, PBKDF2.outputLength = seedSize}
    (entropyPhrase ent)
    ("mnemonic" <> passphrase)
