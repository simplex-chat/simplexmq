{-# LANGUAGE OverloadedStrings #-}

-- | Compatibility wrappers for base64 package, Base64 (padded) variant.
module Simplex.Messaging.Encoding.Base64 where

import qualified Data.Attoparsec.ByteString.Char8 as A
import Data.Base64.Types (extractBase64)
import Data.Bifunctor (first)
import Data.ByteString.Base64 (decodeBase64Untyped, encodeBase64')
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import qualified Data.Text as T

encode :: ByteString -> ByteString
encode = extractBase64 . encodeBase64'
{-# INLINE encode #-}

decode :: ByteString -> Either String ByteString
decode = first T.unpack . decodeBase64Untyped
{-# INLINE decode #-}

base64P :: A.Parser ByteString
base64P = do
  str <- A.takeWhile1 (`B.elem` base64Alphabet)
  pad <- A.takeWhile (== '=') -- correct amount of padding can be derived from str length
  either (fail . T.unpack) pure $ decodeBase64Untyped (str <> pad)

base64Alphabet :: ByteString
base64Alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
