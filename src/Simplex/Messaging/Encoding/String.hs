module Simplex.Messaging.Encoding.String (StrEncoding (..)) where

import Data.Attoparsec.ByteString.Char8 (Parser)
import qualified Data.Attoparsec.ByteString.Char8 as A
import qualified Data.ByteString.Base64.URL as U
import Data.ByteString.Char8 (ByteString)
import Data.Char (isAlphaNum)
import Simplex.Messaging.Parsers (parseAll)
import Simplex.Messaging.Util ((<$?>))

-- | Serializing human-readable and (where possible) URI-friendly strings for SMP and SMP agent protocols
class StrEncoding a where
  {-# MINIMAL smpStrEncode, (smpStrDecode | smpStrP) #-}
  smpStrEncode :: a -> ByteString
  smpStrDecode :: ByteString -> Either String a
  smpStrDecode = parseAll smpStrP
  smpStrP :: Parser a
  smpStrP = smpStrDecode <$?> base64urlP

-- base64url encoding/decoding of ByteStrings - the parser only allows non-empty strings
instance StrEncoding ByteString where
  smpStrEncode = U.encode
  smpStrP = base64urlP

base64urlP :: Parser ByteString
base64urlP = do
  str <- A.takeWhile1 (\c -> isAlphaNum c || c == '-' || c == '_')
  pad <- A.takeWhile (== '=')
  either fail pure $ U.decodePadded (str <> pad)
