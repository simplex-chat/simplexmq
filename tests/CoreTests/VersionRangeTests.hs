{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}

module CoreTests.VersionRangeTests where

import Data.Word (Word16)
import GHC.Generics (Generic)
import Generic.Random (genericArbitraryU)
import Simplex.Messaging.Version
import Simplex.Messaging.Version.Internal
import Test.Hspec
import Test.Hspec.QuickCheck (modifyMaxSuccess)
import Test.QuickCheck

data V = V1 | V2 | V3 | V4 | V5 deriving (Eq, Enum, Ord, Generic, Show)

instance Arbitrary V where arbitrary = genericArbitraryU

data T

instance VersionScope T

versionRangeTests :: Spec
versionRangeTests = modifyMaxSuccess (const 1000) $ do
  describe "VersionRange construction" $ do
    it "should fail on invalid range" $ do
      vr 1 1 `shouldBe` vr 1 1
      vr 1 2 `shouldBe` vr 1 2
      (pure $! vr 2 1) `shouldThrow` anyErrorCall
  describe "compatible version" $ do
    it "should choose mutually compatible max version" $ do
      (vr 1 1, vr 1 1) `compatible` Just (Version 1)
      (vr 1 1, vr 1 2) `compatible` Just (Version 1)
      (vr 1 2, vr 1 2) `compatible` Just (Version 2)
      (vr 1 2, vr 2 3) `compatible` Just (Version 2)
      (vr 1 3, vr 2 3) `compatible` Just (Version 3)
      (vr 1 3, vr 2 4) `compatible` Just (Version 3)
      (vr 1 2, vr 3 4) `compatible` Nothing
    it "should choose mutually compatible version range (range intersection)" $ do
      (vr 1 1, vr 1 1) `compatibleVR` Just (vr 1 1)
      (vr 1 1, vr 1 2) `compatibleVR` Just (vr 1 1)
      (vr 1 2, vr 1 2) `compatibleVR` Just (vr 1 2)
      (vr 1 2, vr 2 3) `compatibleVR` Just (vr 2 2)
      (vr 1 3, vr 2 3) `compatibleVR` Just (vr 2 3)
      (vr 1 3, vr 2 4) `compatibleVR` Just (vr 2 3)
      (vr 1 2, vr 3 4) `compatibleVR` Nothing
    it "should choose compatible version range with changed max version (capped range)" $ do
      (vr 1 1, 1) `compatibleVR'` Just (vr 1 1)
      (vr 1 1, 2) `compatibleVR'` Nothing
      (vr 1 2, 2) `compatibleVR'` Just (vr 1 2)
      (vr 1 2, 3) `compatibleVR'` Nothing
      (vr 1 3, 2) `compatibleVR'` Just (vr 1 2)
      (vr 1 3, 3) `compatibleVR'` Just (vr 1 3)
      (vr 1 3, 4) `compatibleVR'` Nothing
      (vr 2 3, 1) `compatibleVR'` Nothing
      (vr 2 3, 2) `compatibleVR'` Just (vr 2 2)
      (vr 2 3, 3) `compatibleVR'` Just (vr 2 3)
      (vr 2 4, 1) `compatibleVR'` Nothing
      (vr 2 4, 3) `compatibleVR'` Just (vr 2 3)
      (vr 2 4, 4) `compatibleVR'` Just (vr 2 4)
    it "should check if version is compatible" $ do
      isCompatible @T (Version 1) (vr 1 2) `shouldBe` True
      isCompatible @T (Version 2) (vr 1 2) `shouldBe` True
      isCompatible @T (Version 2) (vr 1 1) `shouldBe` False
      isCompatible @T (Version 1) (vr 2 2) `shouldBe` False
    it "compatibleVersion should pass isCompatible check" . property $
      \((min1, max1) :: (V, V)) ((min2, max2) :: (V, V)) ->
        min1 > max1
          || min2 > max2 -- one of ranges is invalid, skip testing it
          || let w = Version . fromIntegral . fromEnum
                 vr1 = mkVersionRange (w min1) (w max1) :: VersionRange T
                 vr2 = mkVersionRange (w min2) (w max2) :: VersionRange T
              in case compatibleVersion vr1 vr2 of
                  Just (Compatible v) -> v `isCompatible` vr1 && v `isCompatible` vr2
                  _ -> True
  where
    vr v1 v2 = mkVersionRange (Version v1) (Version v2)
    compatible :: (VersionRange T, VersionRange T) -> Maybe (Version T) -> Expectation
    (vr1, vr2) `compatible` v = do
      (vr1, vr2) `checkCompatible` v
      (vr2, vr1) `checkCompatible` v
    (vr1, vr2) `checkCompatible` v =
      case compatibleVersion vr1 vr2 of
        Just (Compatible v') -> Just v' `shouldBe` v
        Nothing -> Nothing `shouldBe` v
    compatibleVR :: (VersionRange T, VersionRange T) -> Maybe (VersionRange T) -> Expectation
    (vr1, vr2) `compatibleVR` vr' = do
      (vr1, vr2) `checkCompatibleVR` vr'
      (vr2, vr1) `checkCompatibleVR` vr'
    (vr1, vr2) `checkCompatibleVR` vr' =
      case compatibleVRange vr1 vr2 of
        Just (Compatible vr'') -> Just vr'' `shouldBe` vr'
        Nothing -> Nothing `shouldBe` vr'
    compatibleVR' :: (VersionRange T, Word16) -> Maybe (VersionRange T) -> Expectation
    (vr1, v2) `compatibleVR'` vr' =
      case compatibleVRange' vr1 (Version v2) of
        Just (Compatible vr'') -> Just vr'' `shouldBe` vr'
        Nothing -> Nothing `shouldBe` vr'
