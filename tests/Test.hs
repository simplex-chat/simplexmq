{-# LANGUAGE BlockArguments #-}

import ServerTests
import Test.Hspec

main :: IO ()
main = hspec do
  describe "SMP Server" serverTests
