{-# LANGUAGE TemplateHaskell #-}

-- | The BIP-39 English wordlist, embedded verbatim from <https://github.com/bitcoin/bips/blob/master/bip-0039/english.txt>, pinned by a checksum test.
module Simplex.Messaging.Crypto.BIP39.English (englishWordList) where

import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as BC
import Data.FileEmbed (embedFile)

englishWordList :: [ByteString]
englishWordList = BC.words $(embedFile "src/Simplex/Messaging/Crypto/BIP39/english.txt")
