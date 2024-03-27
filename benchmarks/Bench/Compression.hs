{-# LANGUAGE OverloadedStrings #-}

module Bench.Compression where

import qualified Codec.Compression.Zstd as Z
import Data.Aeson
import qualified Data.ByteString.Char8 as B
import qualified Data.ByteString.Lazy as LB
import Simplex.Messaging.Compression
import Test.Tasty
import Test.Tasty.Bench
import Simplex.Messaging.Encoding (smpEncode)
import Control.Monad (replicateM)
-- import qualified Codec.Compression.Zstd.FFI as Z

benchCompression :: [Benchmark]
benchCompression =
  [ bgroup
      "stateless"
      [ bench "1" $ nf (Z.compress 1) testJson,
        bench "3" $ nf (Z.compress 3) testJson,
        bench "5" $ nf (Z.compress 5) testJson,
        bench "9" $ nf (Z.compress 9) testJson,
        bench "15" $ nf (Z.compress 19) testJson
      ],
    bgroup
      "context"
        [ withCtxRes $ bench "batch-1" . nfAppIO (>>= replicateM 1 . fmap smpEncode . flip compress testJson),
          withCtxRes $ bench "batch-1-pass" . nfAppIO (>>= replicateM 1 . fmap smpEncode . flip compress shortJson),
          withCtxRes $ bench "batch-10" . nfAppIO (>>= replicateM 10 . fmap smpEncode . flip compress testJson),
          withCtxRes $ bcompare "batch-10" . bench "native-10" . nfAppIO (const . replicateM 10 $ pure $! smpEncode $ Z.compress 3 testJson)
        ]
  ]

withCtxRes :: (IO CompressCtx -> TestTree) -> TestTree
withCtxRes = withResource (createCompressCtx 16384) freeCompressCtx

shortJson :: B.ByteString
shortJson = B.take maxLengthPassthrough testJson

testJson :: B.ByteString
testJson = LB.toStrict . encode $ object ["some stuff" .= [obj, obj, obj, obj]]
  where
    obj = object ["test" .= [True, False, True], "arr" .= [0 :: Int .. 50], "loooooooooong key" .= String "is loooooooooooooooooooooooong-ish"]
