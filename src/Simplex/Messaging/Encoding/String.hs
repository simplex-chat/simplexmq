{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE OverloadedStrings #-}

module Simplex.Messaging.Encoding.String
  ( TextEncoding (..),
    StrEncoding (..),
    Str (..),
    strP_,
    _strP,
    strToJSON,
    strToJEncoding,
    strParseJSON,
    base64urlP,
    strEncodeList,
    strListP,
  )
where

import Control.Applicative (optional)
import Data.Aeson (FromJSON (..), ToJSON (..))
import qualified Data.Aeson as J
import qualified Data.Aeson.Encoding as JE
import qualified Data.Aeson.Types as JT
import Data.Attoparsec.ByteString.Char8 (Parser)
import qualified Data.Attoparsec.ByteString.Char8 as A
import qualified Data.ByteString.Base64.URL as U
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.Char (isAlphaNum)
import Data.Int (Int64)
import qualified Data.List.NonEmpty as L
import Data.Set (Set)
import qualified Data.Set as S
import Data.Text (Text)
import Data.Text.Encoding (decodeLatin1, encodeUtf8)
import Data.Time.Clock (UTCTime)
import Data.Time.Clock.System (SystemTime (..))
import Data.Time.Format.ISO8601
import Data.Word (Word16, Word32)
import Simplex.Messaging.Encoding
import Simplex.Messaging.Parsers (parseAll)
import Simplex.Messaging.Util ((<$?>))

class TextEncoding a where
  textEncode :: a -> Text
  textDecode :: Text -> Maybe a

-- | Serializing human-readable and (where possible) URI-friendly strings for SMP and SMP agent protocols
class StrEncoding a where
  {-# MINIMAL strEncode, (strDecode | strP) #-}
  strEncode :: a -> ByteString

  -- Please note - if you only specify strDecode, it will use base64urlP as default parser before decoding the string
  strDecode :: ByteString -> Either String a
  strDecode = parseAll strP
  strP :: Parser a
  strP = strDecode <$?> base64urlP

-- base64url encoding/decoding of ByteStrings - the parser only allows non-empty strings
instance StrEncoding ByteString where
  strEncode = U.encode
  strDecode = U.decode
  strP = base64urlP

base64urlP :: Parser ByteString
base64urlP = do
  str <- A.takeWhile1 (\c -> isAlphaNum c || c == '-' || c == '_')
  pad <- A.takeWhile (== '=')
  either fail pure $ U.decode (str <> pad)

newtype Str = Str {unStr :: ByteString}
  deriving (Eq, Show)

instance StrEncoding Str where
  strEncode = unStr
  strP = Str <$> A.takeTill (== ' ') <* optional A.space

instance StrEncoding String where
  strEncode = strEncode . B.pack
  strP = B.unpack <$> strP

instance ToJSON Str where
  toJSON (Str s) = strToJSON s
  toEncoding (Str s) = strToJEncoding s

instance FromJSON Str where
  parseJSON = fmap Str . strParseJSON "Str"

instance StrEncoding a => StrEncoding (Maybe a) where
  strEncode = maybe "" strEncode
  {-# INLINE strEncode #-}
  strP = optional strP
  {-# INLINE strP #-}

instance StrEncoding Word16 where
  strEncode = B.pack . show
  {-# INLINE strEncode #-}
  strP = A.decimal
  {-# INLINE strP #-}

instance StrEncoding Word32 where
  strEncode = B.pack . show
  {-# INLINE strEncode #-}
  strP = A.decimal
  {-# INLINE strP #-}

instance StrEncoding Char where
  strEncode = smpEncode
  {-# INLINE strEncode #-}
  strP = smpP
  {-# INLINE strP #-}

instance StrEncoding Bool where
  strEncode = smpEncode
  {-# INLINE strEncode #-}
  strP = smpP
  {-# INLINE strP #-}

instance StrEncoding Int where
  strEncode = B.pack . show
  {-# INLINE strEncode #-}
  strP = A.decimal
  {-# INLINE strP #-}

instance StrEncoding Int64 where
  strEncode = B.pack . show
  {-# INLINE strEncode #-}
  strP = A.decimal
  {-# INLINE strP #-}

instance StrEncoding SystemTime where
  strEncode = strEncode . systemSeconds
  strP = MkSystemTime <$> strP <*> pure 0

instance StrEncoding UTCTime where
  strEncode = B.pack . iso8601Show
  strP = maybe (Left "bad UTCTime") Right . iso8601ParseM . B.unpack <$?> A.takeTill (\c -> c == ' ' || c == '\n')

-- lists encode/parse as comma-separated strings
strEncodeList :: StrEncoding a => [a] -> ByteString
strEncodeList = B.intercalate "," . map strEncode

strListP :: StrEncoding a => Parser [a]
strListP = listItem `A.sepBy'` A.char ','

-- relies on sepBy1 never returning an empty list
instance StrEncoding a => StrEncoding (L.NonEmpty a) where
  strEncode = strEncodeList . L.toList
  strP = L.fromList <$> listItem `A.sepBy1'` A.char ','

instance (StrEncoding a, Ord a) => StrEncoding (Set a) where
  strEncode = strEncodeList . S.toList
  strP = S.fromList <$> listItem `A.sepBy'` A.char ','

listItem :: StrEncoding a => Parser a
listItem = parseAll strP <$?> A.takeTill (\c -> c == ',' || c == ' ' || c == '\n')

instance (StrEncoding a, StrEncoding b) => StrEncoding (a, b) where
  strEncode (a, b) = B.unwords [strEncode a, strEncode b]
  {-# INLINE strEncode #-}
  strP = (,) <$> strP_ <*> strP
  {-# INLINE strP #-}

instance (StrEncoding a, StrEncoding b, StrEncoding c) => StrEncoding (a, b, c) where
  strEncode (a, b, c) = B.unwords [strEncode a, strEncode b, strEncode c]
  {-# INLINE strEncode #-}
  strP = (,,) <$> strP_ <*> strP_ <*> strP
  {-# INLINE strP #-}

instance (StrEncoding a, StrEncoding b, StrEncoding c, StrEncoding d) => StrEncoding (a, b, c, d) where
  strEncode (a, b, c, d) = B.unwords [strEncode a, strEncode b, strEncode c, strEncode d]
  {-# INLINE strEncode #-}
  strP = (,,,) <$> strP_ <*> strP_ <*> strP_ <*> strP
  {-# INLINE strP #-}

instance (StrEncoding a, StrEncoding b, StrEncoding c, StrEncoding d, StrEncoding e) => StrEncoding (a, b, c, d, e) where
  strEncode (a, b, c, d, e) = B.unwords [strEncode a, strEncode b, strEncode c, strEncode d, strEncode e]
  {-# INLINE strEncode #-}
  strP = (,,,,) <$> strP_ <*> strP_ <*> strP_ <*> strP_ <*> strP
  {-# INLINE strP #-}

strP_ :: StrEncoding a => Parser a
strP_ = strP <* A.space

_strP :: StrEncoding a => Parser a
_strP = A.space *> strP

strToJSON :: StrEncoding a => a -> J.Value
strToJSON = J.String . decodeLatin1 . strEncode

strToJEncoding :: StrEncoding a => a -> J.Encoding
strToJEncoding = JE.text . decodeLatin1 . strEncode

strParseJSON :: StrEncoding a => String -> J.Value -> JT.Parser a
strParseJSON name = J.withText name $ either fail pure . parseAll strP . encodeUtf8
