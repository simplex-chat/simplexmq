{- Benchmark harness

Run with: cabal bench -O2 simplexmq-bench

List cases: cabal bench -O2 simplexmq-bench --benchmark-options "-l"
Pick one or group: cabal bench -O2 simplexmq-bench --benchmark-options "-p TRcvQueues.getDelSessQueues"
-}

module Main where

import Test.Tasty.Bench
import Bench.TRcvQueues

main :: IO ()
main = defaultMain
  [ bgroup "TRcvQueues" benchTRcvQueues
  ]
