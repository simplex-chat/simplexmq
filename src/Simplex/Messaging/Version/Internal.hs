module Simplex.Messaging.Version.Internal where

import Data.Aeson (FromJSON (..), ToJSON (..))
import Data.Word (Word16)
import Simplex.Messaging.Encoding
import Simplex.Messaging.Encoding.String

-- Do not use constructor of this type directry
newtype Version v = Version Word16
  deriving (Eq, Ord, Show)

instance Encoding (Version v) where
  smpEncode (Version v) = smpEncode v
  smpP = Version <$> smpP

instance StrEncoding (Version v) where
  strEncode (Version v) = strEncode v
  strP = Version <$> strP

instance ToJSON (Version v) where
  toEncoding (Version v) = toEncoding v
  toJSON (Version v) = toJSON v

instance FromJSON (Version v) where
  parseJSON v = Version <$> parseJSON v
