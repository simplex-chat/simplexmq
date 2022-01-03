{-# LANGUAGE ConstrainedClassMethods #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeSynonymInstances #-}

module Simplex.Messaging.Version
  ( Version,
    VersionRange (minVersion, maxVersion),
    pattern VersionRange,
    VersionI (..),
    VersionRangeI (..),
    mkVersionRange,
    safeVersionRange,
    isCompatible,
    compatibleVersion,
  )
where

import Control.Applicative (optional)
import qualified Data.Attoparsec.ByteString.Char8 as A
import Data.Word (Word16)
import Simplex.Messaging.Encoding
import Simplex.Messaging.Encoding.String

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

safeVersionRange :: Version -> Version -> Maybe VersionRange
safeVersionRange v1 v2
  | v1 <= v2 = Just $ VRange v1 v2
  | otherwise = Nothing

instance Encoding VersionRange where
  smpEncode (VRange v1 v2) = smpEncode (v1, v2)
  smpP =
    maybe (fail "invalid version range") pure
      =<< safeVersionRange <$> smpP <*> smpP

instance StrEncoding VersionRange where
  strEncode (VRange v1 v2)
    | v1 == v2 = strEncode v1
    | otherwise = strEncode v1 <> "-" <> strEncode v2
  strP = do
    v1 <- strP
    v2 <- maybe (pure v1) (const strP) =<< optional (A.char '-')
    maybe (fail "invalid version range") pure $ safeVersionRange v1 v2

class VersionI a where
  type VersionRangeT a
  version :: a -> Version
  toVersionRangeT :: a -> VersionRange -> VersionRangeT a

isCompatible :: VersionI a => a -> VersionRange -> Bool
isCompatible x (VRange v1 v2) = let v = version x in v1 <= v && v <= v2

compatibleVersion :: VersionRangeI a => a -> VersionRange -> Maybe (VersionT a)
compatibleVersion x (VRange min2 max2)
  | min1 <= max2 && min2 <= max1 = Just . toVersionT x $ min max1 max2
  | otherwise = Nothing
  where
    VRange min1 max1 = versionRange x

class VersionRangeI a where
  type VersionT a
  versionRange :: a -> VersionRange
  toVersionT :: a -> Version -> VersionT a

instance VersionI Version where
  type VersionRangeT Version = VersionRange
  version = id
  toVersionRangeT _ vr = vr

instance VersionRangeI VersionRange where
  type VersionT VersionRange = Version
  versionRange = id
  toVersionT _ v = v
