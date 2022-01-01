{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE OverloadedStrings #-}

module Simplex.Messaging.Encoding.String
  ( StrEncoding (..),
    Str (..),
    strP_,
  )
where

import Control.Applicative (optional)
import Data.Attoparsec.ByteString.Char8 (Parser)
import qualified Data.Attoparsec.ByteString.Char8 as A
import qualified Data.ByteString.Base64.URL as U
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.Char (isAlphaNum)
import Simplex.Messaging.Parsers (parseAll)
import Simplex.Messaging.Util ((<$?>))

-- | Serializing human-readable and (where possible) URI-friendly strings for SMP and SMP agent protocols
class StrEncoding a where
  {-# MINIMAL strEncode, (smpStrDecode | strP) #-}
  strEncode :: a -> ByteString
  smpStrDecode :: ByteString -> Either String a
  smpStrDecode = parseAll strP
  strP :: Parser a
  strP = smpStrDecode <$?> base64urlP

-- base64url encoding/decoding of ByteStrings - the parser only allows non-empty strings
instance StrEncoding ByteString where
  strEncode = U.encode
  strP = base64urlP

base64urlP :: Parser ByteString
base64urlP = do
  str <- A.takeWhile1 (\c -> isAlphaNum c || c == '-' || c == '_')
  pad <- A.takeWhile (== '=')
  either fail pure $ U.decode (str <> pad)

newtype Str = Str {unStr :: ByteString}

instance StrEncoding Str where
  strEncode = unStr
  strP = Str <$> A.takeTill (== ' ') <* optional A.space

instance StrEncoding a => StrEncoding (Maybe a) where
  strEncode = maybe "" strEncode
  strP = optional strP

instance (StrEncoding a, StrEncoding b) => StrEncoding (a, b) where
  strEncode (a, b) = B.unwords [strEncode a, strEncode b]
  strP = (,) <$> strP_ <*> strP

instance (StrEncoding a, StrEncoding b, StrEncoding c) => StrEncoding (a, b, c) where
  strEncode (a, b, c) = B.unwords [strEncode a, strEncode b, strEncode c]
  strP = (,,) <$> strP_ <*> strP_ <*> strP

instance (StrEncoding a, StrEncoding b, StrEncoding c, StrEncoding d) => StrEncoding (a, b, c, d) where
  strEncode (a, b, c, d) = B.unwords [strEncode a, strEncode b, strEncode c, strEncode d]
  strP = (,,,) <$> strP_ <*> strP_ <*> strP_ <*> strP

instance (StrEncoding a, StrEncoding b, StrEncoding c, StrEncoding d, StrEncoding e) => StrEncoding (a, b, c, d, e) where
  strEncode (a, b, c, d, e) = B.unwords [strEncode a, strEncode b, strEncode c, strEncode d, strEncode e]
  strP = (,,,,) <$> strP_ <*> strP_ <*> strP_ <*> strP_ <*> strP

strP_ :: StrEncoding a => Parser a
strP_ = strP <* A.space
