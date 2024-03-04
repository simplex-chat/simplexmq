{-# LANGUAGE ConstrainedClassMethods #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeSynonymInstances #-}

module Simplex.Messaging.Version
  ( Version (..),
    VersionRange (minVersion, maxVersion),
    VersionScope,
    pattern VersionRange,
    VersionI (..),
    VersionRangeI (..),
    Compatible,
    pattern Compatible,
    mkVersionRange,
    safeVersionRange,
    versionToRange,
    isCompatible,
    isCompatibleRange,
    proveCompatible,
    compatibleVersion,
  )
where

import Control.Applicative (optional)
import Data.Aeson (FromJSON (..), ToJSON (..))
import qualified Data.Attoparsec.ByteString.Char8 as A
import Data.Word (Word16)
import Simplex.Messaging.Encoding
import Simplex.Messaging.Encoding.String

pattern VersionRange :: Version v -> Version v -> VersionRange v
pattern VersionRange v1 v2 <- VRange v1 v2

{-# COMPLETE VersionRange #-}

newtype Version v = Version Word16
  deriving (Eq, Ord, Show)

data VersionRange v = VRange
  { minVersion :: Version v,
    maxVersion :: Version v
  }
  deriving (Eq, Show)

class VersionScope v

-- | construct valid version range, to be used in constants
mkVersionRange :: Version v -> Version v -> VersionRange v
mkVersionRange v1 v2
  | v1 <= v2 = VRange v1 v2
  | otherwise = error "invalid version range"

safeVersionRange :: Version v -> Version v -> Maybe (VersionRange v)
safeVersionRange v1 v2
  | v1 <= v2 = Just $ VRange v1 v2
  | otherwise = Nothing

versionToRange :: Version v -> VersionRange v
versionToRange v = VRange v v

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

instance VersionScope v => Encoding (VersionRange v) where
  smpEncode (VRange v1 v2) = smpEncode (v1, v2)
  smpP =
    maybe (fail "invalid version range") pure
      =<< safeVersionRange <$> smpP <*> smpP

instance VersionScope v => StrEncoding (VersionRange v) where
  strEncode (VRange v1 v2)
    | v1 == v2 = strEncode v1
    | otherwise = strEncode v1 <> "-" <> strEncode v2
  strP = do
    v1 <- strP
    v2 <- maybe (pure v1) (const strP) =<< optional (A.char '-')
    maybe (fail "invalid version range") pure $ safeVersionRange v1 v2

class VersionScope v => VersionI v a | a -> v where
  type VersionRangeT v a
  version :: a -> Version v
  toVersionRangeT :: a -> VersionRange v -> VersionRangeT v a

class VersionScope v => VersionRangeI v a | a -> v where
  type VersionT v a
  versionRange :: a -> VersionRange v
  toVersionT :: a -> Version v -> VersionT v a

instance VersionScope v => VersionI v (Version v) where
  type VersionRangeT v (Version v) = VersionRange v
  version = id
  toVersionRangeT _ vr = vr

instance VersionScope v => VersionRangeI v (VersionRange v) where
  type VersionT v (VersionRange v) = Version v
  versionRange = id
  toVersionT _ v = v

newtype Compatible a = Compatible_ a

pattern Compatible :: a -> Compatible a
pattern Compatible a <- Compatible_ a

{-# COMPLETE Compatible #-}

isCompatible :: VersionI v a => a -> VersionRange v -> Bool
isCompatible x (VRange v1 v2) = let v = version x in v1 <= v && v <= v2

isCompatibleRange :: VersionRangeI v a => a -> VersionRange v -> Bool
isCompatibleRange x (VRange min2 max2) = min1 <= max2 && min2 <= max1
  where
    VRange min1 max1 = versionRange x

proveCompatible :: VersionI v a => a -> VersionRange v -> Maybe (Compatible a)
proveCompatible x vr = x `mkCompatibleIf` (x `isCompatible` vr)

compatibleVersion :: VersionRangeI v a => a -> VersionRange v -> Maybe (Compatible (VersionT v a))
compatibleVersion x vr =
  toVersionT x (min max1 max2) `mkCompatibleIf` isCompatibleRange x vr
  where
    max1 = maxVersion $ versionRange x
    max2 = maxVersion vr

mkCompatibleIf :: a -> Bool -> Maybe (Compatible a)
x `mkCompatibleIf` cond = if cond then Just $ Compatible_ x else Nothing
