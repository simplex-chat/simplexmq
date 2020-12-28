{-# LANGUAGE TemplateHaskell #-}

module Multiline (s) where

import GHC.Exts (IsString (..))
import Language.Haskell.TH.Quote

s :: QuasiQuoter
s =
  QuasiQuoter
    ((\a -> [|fromString a|]) . filter (/= '\r') . dropWhile (== '\n'))
    (error "pattern")
    (error "type")
    (error "dec")
