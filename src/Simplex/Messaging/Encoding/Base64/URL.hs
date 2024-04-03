{-# LANGUAGE CPP #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PackageImports #-}

-- | Compatibility wrappers for base64 package, Base64URL-padded variant.
module Simplex.Messaging.Encoding.Base64.URL
  ( encode,
    encodeUnpadded,
    decode,
    decodeLenient,
    base64urlP,
    base64AlphabetURL
  ) where

#if MIN_VERSION_bytestring(0,11,0)

import qualified Data.Attoparsec.ByteString.Char8 as A
import Data.Base64.Types (extractBase64)
import Data.Bifunctor (first)
import Data.ByteString.Base64.URL (decodeBase64Untyped, decodeBase64Lenient, encodeBase64', encodeBase64Unpadded')
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import qualified Data.Text as T

encode :: ByteString -> ByteString
encode = extractBase64 . encodeBase64'
{-# INLINE encode #-}

encodeUnpadded :: ByteString -> ByteString
encodeUnpadded = extractBase64 . encodeBase64Unpadded'
{-# INLINE encodeUnpadded #-}

decode :: ByteString -> Either String ByteString
decode = first T.unpack . decodeBase64Untyped
{-# INLINE decode #-}

decodeLenient :: ByteString -> ByteString
decodeLenient = decodeBase64Lenient

#else

import qualified Data.Attoparsec.ByteString.Char8 as A
import Data.ByteString.Base64.URL (decode, decodeLenient, encode, encodeUnpadded)
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B

#endif

base64urlP :: A.Parser ByteString
base64urlP = do
  str <- A.takeWhile1 (`B.elem` base64AlphabetURL)
  _pad <- A.takeWhile (== '=') -- correct amount of padding can be derived from str length
  either fail pure $ decode str

base64AlphabetURL :: ByteString
base64AlphabetURL = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
