{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}

module Simplex.Messaging.Version
  ( Version,
    VersionRange (minVersion, maxVersion),
    pattern VersionRange,
    mkVersionRange,
    versionRange,
    compatibleVersion,
    isCompatible,
  )
where

import qualified Data.Attoparsec.ByteString.Char8 as A
import Data.Word (Word16)
import Simplex.Messaging.Encoding
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Util (bshow)

pattern VersionRange :: Word16 -> Word16 -> VersionRange
pattern VersionRange v1 v2 <- VRange v1 v2

{-# COMPLETE VersionRange #-}

type Version = Word16

data VersionRange = VRange
  { minVersion :: Version,
    maxVersion :: Version
  }
  deriving (Eq, Show)

-- | construct valid version range, to be used in constants
mkVersionRange :: Version -> Version -> VersionRange
mkVersionRange v1 v2
  | v1 <= v2 = VRange v1 v2
  | otherwise = error "invalid version range"

versionRange :: Version -> Version -> Maybe VersionRange
versionRange v1 v2
  | v1 <= v2 = Just $ VRange v1 v2
  | otherwise = Nothing

instance Encoding VersionRange where
  smpEncode (VRange v1 v2) = smpEncode (v1, v2)
  smpP =
    maybe (fail "invalid version range") pure
      =<< versionRange <$> smpP <*> smpP

instance StrEncoding VersionRange where
  strEncode (VRange v1 v2) = bshow v1 <> "-" <> bshow v2
  strP =
    maybe (fail "invalid version range") pure
      =<< versionRange <$> A.decimal <* A.char '-' <*> A.decimal

compatibleVersion :: VersionRange -> VersionRange -> Maybe Word16
compatibleVersion (VersionRange min1 max1) (VersionRange min2 max2)
  | min1 <= max2 && min2 <= max1 = Just $ min max1 max2
  | otherwise = Nothing

isCompatible :: Version -> VersionRange -> Bool
isCompatible v (VersionRange v1 v2) = v1 <= v && v <= v2
