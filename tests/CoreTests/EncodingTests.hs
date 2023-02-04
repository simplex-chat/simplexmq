{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

module CoreTests.EncodingTests where

import Data.Bits (shiftR)
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.ByteString.Internal (w2c)
import Data.Int (Int64)
import Data.Time.Clock.System (SystemTime (..), getSystemTime, utcToSystemTime)
import Data.Time.ISO8601 (parseISO8601)
import Simplex.Messaging.Encoding
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Parsers (parseAll)
import Simplex.Messaging.Transport.Client (TransportHost (..))
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
  describe "Encoding transport hosts" $ do
    describe "domain name hosts" $ do
      it "should encode / decode domain name" $ THDomainName "smp.simplex.im" #==# "smp.simplex.im"
      it "should not allow whitespace or punctuation" $ do
        shouldNotParse @TransportHost "smp,simplex.im" "endOfInput"
        shouldNotParse @TransportHost "smp:simplex.im" "endOfInput"
        shouldNotParse @TransportHost "smp#simplex.im" "endOfInput"
        shouldNotParse @TransportHost "smp simplex.im" "endOfInput"
        shouldNotParse @TransportHost "smp\nsimplex.im" "endOfInput"
    describe "onion hosts" $ do
      it "should encode / decode onion host" $ THOnionHost "beccx4yfxxbvyhqypaavemqurytl6hozr47wfc7uuecacjqdvwpw2xid.onion" #==# "beccx4yfxxbvyhqypaavemqurytl6hozr47wfc7uuecacjqdvwpw2xid.onion"
      it "should only allow latin letters and digits" $ do
        shouldNotParse @TransportHost "beccx4yfxxbvyhqypaavemqurytl 6hozr47wfc7uuecacjqdvwpw2xid.onion" "endOfInput"
        shouldNotParse @TransportHost "beccx4yfxxbvyhqypaavemqurytl\n6hozr47wfc7uuecacjqdvwpw2xid.onion" "endOfInput"
        shouldNotParse @TransportHost "bèccx4yfxxbvyhqypaavemqurytl6hozr47wfc7uuecacjqdvwpw2xid.onion" "Failed reading: empty"
    describe "IP address hosts" $ do
      it "should encode / decode IP address" $ THIPv4 (192, 168, 0, 1) #==# "192.168.0.1"
      it "should be valid" $ do
        THDomainName "192.168.1" #==# "192.168.1"
        THDomainName "192.256.0.1" #==# "192.256.0.1"
        THDomainName "192.168.0.-1" #==# "192.168.0.-1"
        shouldNotParse @TransportHost "192.168.0.0.1" "endOfInput"
  where
    testSystemTime :: SystemTime -> Expectation
    testSystemTime t = do
      smpEncode t `shouldBe` smpEncode (systemSeconds t)
      smpDecode (smpEncode t) `shouldBe` Right t {systemNanoseconds = 0}
    (#==#) :: (StrEncoding s, Eq s, Show s) => s -> ByteString -> Expectation
    (#==#) x s = do
      strEncode x `shouldBe` s
      strDecode s `shouldBe` Right x
    shouldNotParse :: forall s. (StrEncoding s, Eq s, Show s) => ByteString -> String -> Expectation
    shouldNotParse s err = strDecode s `shouldBe` (Left err :: Either String s)
