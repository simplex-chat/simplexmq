{-# LANGUAGE PatternSynonyms #-}

module Simplex.Messaging.Version
  ( VersionRange (minVersion, maxVersion),
    pattern VersionRange,
    mkVersionRange,
    versionRange,
    compatibleVersion,
    isCompatible,
  )
where

import Data.Word (Word16)
import Simplex.Messaging.Encoding

pattern VersionRange :: Word16 -> Word16 -> VersionRange
pattern VersionRange v1 v2 <- VRange v1 v2

{-# COMPLETE VersionRange #-}

data VersionRange = VRange
  { minVersion :: Word16,
    maxVersion :: Word16
  }
  deriving (Eq, Show)

-- | construct valid version range, to be used in constants
mkVersionRange :: Word16 -> Word16 -> VersionRange
mkVersionRange v1 v2
  | v1 <= v2 = VRange v1 v2
  | otherwise = error "invalid version range"

versionRange :: Word16 -> Word16 -> Maybe VersionRange
versionRange v1 v2
  | v1 <= v2 = Just $ VRange v1 v2
  | otherwise = Nothing

instance Encoding VersionRange where
  smpEncode (VRange v1 v2) = smpEncode (v1, v2)
  smpP =
    maybe (fail "invalid version range") pure
      =<< versionRange <$> smpP <*> smpP

compatibleVersion :: VersionRange -> VersionRange -> Maybe Word16
compatibleVersion (VersionRange min1 max1) (VersionRange min2 max2)
  | min1 <= max2 && min2 <= max1 = Just $ min max1 max2
  | otherwise = Nothing

isCompatible :: Word16 -> VersionRange -> Bool
isCompatible v (VersionRange v1 v2) = v1 <= v && v <= v2
