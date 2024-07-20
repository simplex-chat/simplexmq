{-# LANGUAGE OverloadedStrings #-}

module Bench.Compression where

import qualified Codec.Compression.Zstd as Z
import Data.Aeson
import qualified Data.ByteString.Char8 as B
import qualified Data.ByteString.Lazy as LB
import Simplex.Messaging.Compression
import Test.Tasty.Bench

benchCompression :: [Benchmark]
benchCompression =
  [ bgroup
      "stateless"
      [ bench "1" $ nf (Z.compress 1) testJson,
        bench "3" $ nf (Z.compress 3) testJson,
        bench "5" $ nf (Z.compress 5) testJson,
        bench "9" $ nf (Z.compress 9) testJson,
        bench "15" $ nf (Z.compress 19) testJson
      ]
  ]

shortJson :: B.ByteString
shortJson = B.take maxLengthPassthrough testJson

testJson :: B.ByteString
testJson = LB.toStrict . encode $ object ["some stuff" .= [obj, obj, obj, obj]]
  where
    obj = object ["test" .= [True, False, True], "arr" .= [0 :: Int .. 50], "loooooooooong key" .= String "is loooooooooooooooooooooooong-ish"]
