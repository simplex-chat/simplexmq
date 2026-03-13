{-# LANGUAGE OverloadedStrings #-}

module WebTests where

import Simplex.Messaging.Server.Web (render, section_, item_, timedTTLText)
import Test.Hspec

webTests :: Spec
webTests = describe "Web module" $ do
  describe "item_" $ do
    it "replaces single placeholder" $
      item_ "name" "Alice" "Hello, ${name}!" `shouldBe` "Hello, Alice!"
    it "replaces multiple occurrences" $
      item_ "x" "1" "${x}+${x}" `shouldBe` "1+1"
    it "returns source unchanged when no placeholder found" $
      item_ "missing" "val" "no placeholder here" `shouldBe` "no placeholder here"
    it "handles empty content" $
      item_ "x" "" "a${x}b" `shouldBe` "ab"
    it "handles empty source" $
      item_ "x" "val" "" `shouldBe` ""

  describe "section_" $ do
    it "keeps section and replaces items when content is Just" $
      section_ "s" (Just "val") "<x-s>${s}</x-s>" `shouldBe` "val"
    it "removes section when content is Nothing" $
      section_ "s" Nothing "before<x-s>inside</x-s>after" `shouldBe` "beforeafter"
    it "keeps section when content is Just empty" $
      section_ "s" (Just "") "before<x-s>inside</x-s>after" `shouldBe` "beforeinsideafter"
    it "handles multiple sections with same label" $
      section_ "s" (Just "X") "<x-s>${s}</x-s>mid<x-s>${s}</x-s>"
        `shouldBe` "XmidX"
    it "falls back to item replacement when no section markers" $
      section_ "s" (Just "val") "just ${s} here" `shouldBe` "just val here"
    it "preserves surrounding content" $
      section_ "s" (Just "Y") "aaa<x-s>${s}</x-s>bbb" `shouldBe` "aaaYbbb"
    it "removes Nothing section preserving surroundings" $
      section_ "s" Nothing "aaa<x-s>gone</x-s>bbb" `shouldBe` "aaabbb"
    it "removes multiple Nothing sections" $
      section_ "s" Nothing "<x-s>first</x-s>mid<x-s>second</x-s>end"
        `shouldBe` "midend"

  describe "render" $ do
    it "applies multiple substitutions" $
      render "Hello ${name}, you are ${age}." [("name", Just "Bob"), ("age", Just "30")]
        `shouldBe` "Hello Bob, you are 30."
    it "removes sections with Nothing" $
      render "<x-opt>optional: ${opt}</x-opt>kept" [("opt", Nothing)]
        `shouldBe` "kept"
    it "handles mixed present and absent substitutions" $
      render "<x-a>${a}</x-a><x-b>${b}</x-b>" [("a", Just "yes"), ("b", Nothing)]
        `shouldBe` "yes"
    it "returns source unchanged with empty substitutions" $
      render "unchanged" [] `shouldBe` "unchanged"

  describe "timedTTLText" $ do
    it "formats zero" $
      timedTTLText (0 :: Int) `shouldBe` "0 sec"
    it "formats seconds" $
      timedTTLText (45 :: Int) `shouldBe` "45 sec"
    it "formats minutes and seconds" $
      timedTTLText (90 :: Int) `shouldBe` "1 min 30 sec"
    it "formats hours" $
      timedTTLText (3600 :: Int) `shouldBe` "1 hour"
    it "formats multiple hours" $
      timedTTLText (7200 :: Int) `shouldBe` "2 hours"
    it "formats days" $
      timedTTLText (86400 :: Int) `shouldBe` "1 day"
    it "formats weeks" $
      timedTTLText (604800 :: Int) `shouldBe` "1 week"
    it "formats months" $
      timedTTLText (2592000 :: Int) `shouldBe` "1 month"
    it "formats compound duration" $
      timedTTLText (90061 :: Int) `shouldBe` "1 day 1 hour 1 min 1 sec"
