{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

module AgentTests.ShortLinkTests (shortLinkTests) where

import AgentTests.ConnectionRequestTests (contactConnRequest, invConnRequest)
import AgentTests.EqInstances ()
import Control.Concurrent.STM
import Control.Monad.Except
import Simplex.Messaging.Agent.Protocol (AgentErrorType (..), ConnectionMode (..), LinkKey (..), SConnectionMode (..), SMPAgentError (..), UserLinkData (..), linkUserData, supportedSMPAgentVRange)
import qualified Simplex.Messaging.Crypto as C
import qualified Simplex.Messaging.Crypto.ShortLink as SL
import Test.Hspec hiding (fit, it)
import Util

shortLinkTests :: Spec
shortLinkTests = do
  describe "invitation short link" $ do
    it "should encrypt and decrypt link data" testInvShortLink
    it "should fail to decrypt invitation data with bad hash" testInvShortLinkBadDataHash
  describe "contact short link" $ do
    it "should encrypt and decrypt data" testContactShortLink
    it "should encrypt updated user data" testUpdateContactShortLink
    it "should fail to decrypt contact data with bad hash" testContactShortLinkBadDataHash
    it "should fail to decrypt contact data with bad signature" testContactShortLinkBadSignature

testInvShortLink :: IO ()
testInvShortLink = do
  -- encrypt
  g <- C.newRandom
  sigKeys <- atomically $ C.generateKeyPair @'C.Ed25519 g
  let userData = UserLinkData "some user data"
      (linkKey, linkData) = SL.encodeSignLinkData sigKeys supportedSMPAgentVRange invConnRequest userData
      k = SL.invShortLinkKdf linkKey
  Right srvData <- runExceptT $ SL.encryptLinkData g k linkData
  -- decrypt
  Right (connReq, connData') <- pure $ SL.decryptLinkData linkKey k srvData
  connReq `shouldBe` invConnRequest
  linkUserData connData' `shouldBe` userData

testInvShortLinkBadDataHash :: IO ()
testInvShortLinkBadDataHash = do
  -- encrypt
  g <- C.newRandom
  sigKeys <- atomically $ C.generateKeyPair @'C.Ed25519 g
  let userData = UserLinkData "some user data"
      (_linkKey, linkData) = SL.encodeSignLinkData sigKeys supportedSMPAgentVRange invConnRequest userData
  -- different key
  linkKey <- LinkKey <$> atomically (C.randomBytes 32 g)
  let k = SL.invShortLinkKdf linkKey
  Right srvData <- runExceptT $ SL.encryptLinkData g k linkData
  -- decryption fails
  SL.decryptLinkData @'CMInvitation linkKey k srvData
    `shouldBe` Left (AGENT (A_LINK "link data hash"))

testContactShortLink :: IO ()
testContactShortLink = do
  -- encrypt
  g <- C.newRandom
  sigKeys <- atomically $ C.generateKeyPair @'C.Ed25519 g
  let userData = UserLinkData "some user data"
      (linkKey, linkData) = SL.encodeSignLinkData sigKeys supportedSMPAgentVRange contactConnRequest userData
      (_linkId, k) = SL.contactShortLinkKdf linkKey
  Right srvData <- runExceptT $ SL.encryptLinkData g k linkData
  -- decrypt
  Right (connReq, connData') <- pure $ SL.decryptLinkData linkKey k srvData
  connReq `shouldBe` contactConnRequest
  linkUserData connData' `shouldBe` userData

testUpdateContactShortLink :: IO ()
testUpdateContactShortLink = do
  -- encrypt
  g <- C.newRandom
  sigKeys <- atomically $ C.generateKeyPair @'C.Ed25519 g
  let userData = UserLinkData "some user data"
      (linkKey, linkData) = SL.encodeSignLinkData sigKeys supportedSMPAgentVRange contactConnRequest userData
      (_linkId, k) = SL.contactShortLinkKdf linkKey
  Right (fd, _ud) <- runExceptT $ SL.encryptLinkData g k linkData
  -- encrypt updated user data
  let updatedUserData = UserLinkData "updated user data"
      signed = SL.encodeSignUserData SCMContact (snd sigKeys) supportedSMPAgentVRange updatedUserData
  Right ud' <- runExceptT $ SL.encryptUserData g k signed
  -- decrypt
  Right (connReq, connData') <- pure $ SL.decryptLinkData linkKey k (fd, ud')
  connReq `shouldBe` contactConnRequest
  linkUserData connData' `shouldBe` updatedUserData

testContactShortLinkBadDataHash :: IO ()
testContactShortLinkBadDataHash = do
  -- encrypt
  g <- C.newRandom
  sigKeys <- atomically $ C.generateKeyPair @'C.Ed25519 g
  let userData = UserLinkData "some user data"
      (_linkKey, linkData) = SL.encodeSignLinkData sigKeys supportedSMPAgentVRange contactConnRequest userData
  -- different key
  linkKey <- LinkKey <$> atomically (C.randomBytes 32 g)
  let (_linkId, k) = SL.contactShortLinkKdf linkKey
  Right srvData <- runExceptT $ SL.encryptLinkData g k linkData
  -- decryption fails
  SL.decryptLinkData @'CMContact linkKey k srvData
    `shouldBe` Left (AGENT (A_LINK "link data hash"))

testContactShortLinkBadSignature :: IO ()
testContactShortLinkBadSignature = do
  -- encrypt
  g <- C.newRandom
  sigKeys <- atomically $ C.generateKeyPair @'C.Ed25519 g
  let userData = UserLinkData "some user data"
      (linkKey, linkData) = SL.encodeSignLinkData sigKeys supportedSMPAgentVRange contactConnRequest userData
      (_linkId, k) = SL.contactShortLinkKdf linkKey
  Right (fd, _ud) <- runExceptT $ SL.encryptLinkData g k linkData
  -- encrypt updated user data
  let updatedUserData = UserLinkData "updated user data"
  -- another signature key
  (_, pk) <- atomically $ C.generateKeyPair @'C.Ed25519 g
  let signed = SL.encodeSignUserData SCMContact pk supportedSMPAgentVRange updatedUserData
  Right ud' <- runExceptT $ SL.encryptUserData g k signed
  -- decryption fails
  SL.decryptLinkData @'CMContact linkKey k (fd, ud')
    `shouldBe` Left (AGENT (A_LINK "user data signature"))
