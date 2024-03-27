{-# LANGUAGE OverloadedStrings #-}

module Bench.BsConcat where

import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as B
import Test.Tasty.Bench

benchBsConcat :: [Benchmark]
benchBsConcat =
  [ bgroup "3 elements"
      [ bench "(3-tuple baseline)" $ nf (\(a, s, b) -> a `seq` s `seq` b `seq` "" :: ByteString) ("aaa" :: ByteString, " " :: ByteString, "bbb" :: ByteString),
        bench "a <> s <> b" $ nf (\(a, s, b) -> a <> s <> b :: ByteString) ("aaa", " ", "bbb"),
        bench "concat [a, s, b]" $ nf (\(a, s, b) -> B.concat [a, s, b] :: ByteString) ("aaa", " ", "bbb"),
        bench "unwords [a, b]" $ nf (\(a, b) -> B.unwords [a, b] :: ByteString) ("aaa", "bbb")
      ],
    bgroup "5 elements"
      [ bench "a <> s <> b <> s <> c" $ nf (\(a, s1, b, s2, c) -> a <> s1 <> b <> s2 <> c :: ByteString) ("aaa", " ", "bbb", " ", "ccc"),
        bench "(a <> s <> b) <> (s <> c)" $ nf (\(a, s1, b, s2, c) -> (a <> s1 <> b) <> (s2 <> c) :: ByteString) ("aaa", " ", "bbb", " ", "ccc"),
        bench "concat [a, s, b, s c]" $ nf (\(a, s1, b, s2, c) -> B.concat [a, s1, b, s2, c] :: ByteString) ("aaa", " ", "bbb", " ", "ccc"),
        bench "unwords [a, b, c]" $ nf (\(a, b, c) -> B.unwords [a, b, c] :: ByteString) ("aaa", "bbb", "ccc")
      ]
  ]
