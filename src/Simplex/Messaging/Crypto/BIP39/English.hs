{-# LANGUAGE TemplateHaskell #-}

-- | The BIP-39 English wordlist, embedded verbatim from <https://github.com/bitcoin/bips/blob/master/bip-0039/english.txt>, pinned by a checksum test.
module Simplex.Messaging.Crypto.BIP39.English (englishWordList) where

import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as BC
import Data.FileEmbed (embedFile)

-- | All 2048 words, in BIP-39 index order (index 0 is @abandon@).
englishWordList :: [ByteString]
englishWordList = BC.words $(embedFile "src/Simplex/Messaging/Crypto/BIP39/english.txt")
