module Util where

import Test.Hspec

skip :: String -> SpecWith a -> SpecWith a
skip = before_ . pendingWith
