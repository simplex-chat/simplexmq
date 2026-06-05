{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

module CoreTests.ConnectTargetTests where

import AgentTests.ConnectionRequestTests (contactConnRequest, invConnRequest)
import qualified Data.Aeson as J
import Data.Either (isLeft)
import Data.Text.Encoding (decodeUtf8)
import Simplex.Messaging.Agent.Protocol (AConnectionLink (..), ConnectTarget (..), ConnectionLink (..), SConnectionMode (..))
import Simplex.Messaging.Encoding.String (strDecode, strEncode)
import Test.Hspec hiding (fit, it)
import Util (it)

connectTargetTests :: Spec
connectTargetTests = describe "ConnectTarget" $ do
  describe "CTName (SimpleX name) — canonical wire form prefixes simplex:/name" $ do
    it "@alice.simplex encodes as simplex:/name@alice.simplex" $
      "@alice.simplex" `encodesAs` "simplex:/name@alice.simplex"
    it "#privacy (bare TLD-less channel) encodes as simplex:/name#privacy.simplex" $
      "#privacy" `encodesAs` "simplex:/name#privacy.simplex"
    it "#privacy.simplex encodes as simplex:/name#privacy.simplex" $
      "#privacy.simplex" `encodesAs` "simplex:/name#privacy.simplex"
    it "#support.acme.simplex preserves subdomain" $
      "#support.acme.simplex" `encodesAs` "simplex:/name#support.acme.simplex"
    it "#PRIVACY (bare uppercase) lowercases to match #privacy" $
      strDecode @ConnectTarget "#PRIVACY" `shouldBe` strDecode @ConnectTarget "#privacy"
    it "simplex:/name@alice.simplex round-trips" $
      "simplex:/name@alice.simplex" `encodesAs` "simplex:/name@alice.simplex"
    it "simplex:/name#privacy.simplex round-trips" $
      "simplex:/name#privacy.simplex" `encodesAs` "simplex:/name#privacy.simplex"

  describe "CTLink (connection link) round-trips" $ do
    it "parses simplex:/contact#… as CTLink and round-trips" $ do
      let s = strEncode (ACL SCMContact (CLFull contactConnRequest))
      decodesSuccessfully s
      s `encodesAs` s
    it "parses simplex:/invitation#… as CTLink" $ do
      let s = strEncode (ACL SCMInvitation (CLFull invConnRequest))
      decodesSuccessfully s

  describe "rejects ambiguous bare input at this layer" $ do
    it "rejects bare 'alice' — no @, no #, no simplex:/name prefix" $
      strDecode @ConnectTarget "alice" `shouldSatisfy` isLeft
    it "rejects empty input" $
      strDecode @ConnectTarget "" `shouldSatisfy` isLeft
    it "rejects whitespace input" $
      strDecode @ConnectTarget " " `shouldSatisfy` isLeft

  describe "JSON shape mirrors AConnectionLink (plain string, not tagged sum)" $ do
    it "encodes @alice.simplex as a JSON string" $
      case strDecode @ConnectTarget "@alice.simplex" of
        Right ct -> J.toJSON ct `shouldBe` J.String "simplex:/name@alice.simplex"
        Left e -> expectationFailure $ "strDecode failed: " <> e
    it "encodes a CTLink as the canonical link JSON string" $ do
      let s = strEncode (ACL SCMContact (CLFull contactConnRequest))
      case strDecode @ConnectTarget s of
        Right ct -> J.toJSON ct `shouldBe` J.String (decodeUtf8 s)
        Left e -> expectationFailure $ "strDecode failed: " <> e
    it "parses JSON string back to ConnectTarget" $
      J.eitherDecode @ConnectTarget "\"@alice.simplex\""
        `shouldSatisfy` either (const False) (const True)
  where
    encodesAs input canonical =
      (strEncode <$> strDecode @ConnectTarget input) `shouldBe` Right canonical
    decodesSuccessfully s =
      strDecode @ConnectTarget s `shouldSatisfy` either (const False) (const True)
