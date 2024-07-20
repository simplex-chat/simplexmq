module Bench.SNTRUP761 where

import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Crypto.SNTRUP761.Bindings
import Test.Tasty.Bench

import Test.Tasty (withResource)

benchSNTRUP761 :: [Benchmark]
benchSNTRUP761 =
  [ bgroup
      "sntrup761Keypair"
      [ withResource C.newRandom (\_ -> pure ()) $ bench "current" . whnfAppIO (>>= sntrup761Keypair)
      ]
  ]
