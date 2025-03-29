{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

module AgentTests.ShortLinkTests (shortLinkTests) where

import AgentTests.ConnectionRequestTests (contactConnRequest, invConnRequest)
import Control.Concurrent.STM
import Simplex.Messaging.Agent.Protocol (supportedSMPAgentVRange)
import qualified Simplex.Messaging.Crypto as C
import qualified Simplex.Messaging.Crypto.ShortLink as SL
import Test.Hspec

-- TODO [short tests] tests failures
shortLinkTests :: Spec
shortLinkTests = do
  it "should encrypt and decrypt invitation short link data" testInvShortLink
  it "should encrypt and decrypt contact short link data" testContactShortLink

testInvShortLink :: IO ()
testInvShortLink = do
  -- encrypt
  g <- C.newRandom
  sigKeys <- atomically $ C.generateKeyPair @'C.Ed25519 g
  let userData = "some user data"
      (linkKey, linkData) = SL.encodeSignLinkData sigKeys supportedSMPAgentVRange invConnRequest userData
      k = SL.invShortLinkKdf linkKey
  srvData <- SL.encryptLinkData g k linkData
  -- decrypt
  Right (connReq, userData') <- pure $ SL.decryptLinkData linkKey k srvData
  connReq `shouldBe` invConnRequest
  userData' `shouldBe` userData

testContactShortLink :: IO ()
testContactShortLink = do
  -- encrypt
  g <- C.newRandom
  sigKeys <- atomically $ C.generateKeyPair @'C.Ed25519 g
  let userData = "some user data"
      (linkKey, linkData) = SL.encodeSignLinkData sigKeys supportedSMPAgentVRange contactConnRequest userData
      (_linkId, k) = SL.contactShortLinkKdf linkKey
  srvData <- SL.encryptLinkData g k linkData
  -- decrypt
  Right (connReq, userData') <- pure $ SL.decryptLinkData linkKey k srvData
  connReq `shouldBe` contactConnRequest
  userData' `shouldBe` userData
