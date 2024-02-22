module Main where

import Test.Tasty.Bench
import Bench.TRcvQueues

main :: IO ()
main = defaultMain
  [ bgroup "TRcvQueues" benchTRcvQueues
  ]
