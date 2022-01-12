{-# LANGUAGE OverloadedStrings #-}

module CoreTests.EncodingTests where

import Data.Bits (shiftR)
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.ByteString.Internal (w2c)
import Data.Int (Int64)
import Data.Time.Clock.System (SystemTime (..), getSystemTime, utcToSystemTime)
import Data.Time.ISO8601 (parseISO8601)
import Simplex.Messaging.Encoding
import Simplex.Messaging.Parsers (parseAll)
import Test.Hspec
import Test.Hspec.QuickCheck (modifyMaxSuccess)
import Test.QuickCheck

int64 :: Int64
int64 = 1234567890123456789

s64 :: ByteString
s64 = B.pack $ map (w2c . fromIntegral . (int64 `shiftR`)) [56, 48, 40, 32, 24, 16, 8, 0]

encodingTests :: Spec
encodingTests = modifyMaxSuccess (const 1000) $ do
  describe "Encoding Int64" $ do
    it "should encode and decode Int64 example" $ do
      s64 `shouldBe` "\17\34\16\244\125\233\129\21"
      smpEncode int64 `shouldBe` s64
      parseAll smpP s64 `shouldBe` Right int64
    it "parse(encode(Int64) should equal the same Int64" . property $
      \i -> parseAll smpP (smpEncode i) == Right (i :: Int64)
  describe "Encoding SystemTime" $ do
    it "should encode and decode SystemTime" $ do
      t <- getSystemTime
      testSystemTime t
      Just t' <- pure $ utcToSystemTime <$> parseISO8601 "2022-01-01T10:24:05.000Z"
      systemSeconds t' `shouldBe` 1641032645
      testSystemTime t'
    it "parse(encode(SystemTime) should equal the same Int64" . property $
      \i -> parseAll smpP (smpEncode i) == Right (i :: Int64)
  where
    testSystemTime :: SystemTime -> Expectation
    testSystemTime t = do
      smpEncode t `shouldBe` smpEncode (systemSeconds t)
      parseAll smpP (smpEncode t) `shouldBe` Right t {systemNanoseconds = 0}
