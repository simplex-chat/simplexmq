{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

module AgentTests.ShortLinkTests (shortLinkTests) where

import AgentTests.ConnectionRequestTests (contactConnRequest, invConnRequest)
import AgentTests.EqInstances ()
import Control.Concurrent.STM
import Control.Monad.Except
import Crypto.Random (ChaChaDRG)
import qualified Data.ByteString.Char8 as B
import qualified Data.ByteString.Base64.URL as B64
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Agent.Protocol
import qualified Simplex.Messaging.Crypto as C
import qualified Simplex.Messaging.Crypto.ShortLink as SL
import Simplex.Messaging.Protocol (EncFixedDataBytes)
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
  describe "contact link with additional owners" $ do
    it "should encrypt and decrypt data with additional owner" testContactShortLinkOwner
    it "should encrypt and decrypt data with many additional owners" testContactShortLinkManyOwners
    it "should fail to decrypt contact data with invalid or unauthorized owners" testContactShortLinkInvalidOwners

testInvShortLink :: IO ()
testInvShortLink = do
  -- encrypt
  g <- C.newRandom
  sigKeys <- atomically $ C.generateKeyPair @'C.Ed25519 g
  let userData = UserLinkData "some user data"
      userLinkData = UserInvLinkData userData
      (linkKey, linkData) = SL.encodeSignLinkData sigKeys supportedSMPAgentVRange invConnRequest userLinkData
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
      userLinkData = UserInvLinkData userData
      (_linkKey, linkData) = SL.encodeSignLinkData sigKeys supportedSMPAgentVRange invConnRequest userLinkData
  -- different key
  linkKey <- LinkKey <$> atomically (C.randomBytes 32 g)
  let k = SL.invShortLinkKdf linkKey
  Right srvData <- runExceptT $ SL.encryptLinkData g k linkData
  -- decryption fails
  SL.decryptLinkData @'CMInvitation linkKey k srvData
    `shouldBe` Left (AGENT (A_LINK "link data hash"))

relayLink1 :: ConnShortLink 'CMContact
relayLink1 = either error id $ strDecode "https://localhost/a#4AkRDmhf64tdRlN406g8lJRg5OCmhD6ynIhi6glOcCM?p=7001&c=LcJUMfVhwD8yxjAiSaDzzGF3-kLG4Uh0Fl_ZIjrRwjI"

relayLink2 :: ConnShortLink 'CMContact
relayLink2 = either error id $ strDecode "https://localhost/a#4AkRDmhf64tdRlN406g8lJRg5OCmhD6ynIhi6glOcCM"

testContactShortLink :: IO ()
testContactShortLink = do
  -- encrypt
  g <- C.newRandom
  sigKeys <- atomically $ C.generateKeyPair @'C.Ed25519 g
  let userData = UserLinkData "some user data"
      userCtData = UserContactData {direct = True, owners = [], relays = [], userData}
      userLinkData = UserContactLinkData userCtData
      (linkKey, linkData) = SL.encodeSignLinkData sigKeys supportedSMPAgentVRange contactConnRequest userLinkData
      (_linkId, k) = SL.contactShortLinkKdf linkKey
  Right srvData <- runExceptT $ SL.encryptLinkData g k linkData
  -- decrypt
  Right (connReq, ContactLinkData _ userCtData') <- pure $ SL.decryptLinkData @'CMContact linkKey k srvData
  connReq `shouldBe` contactConnRequest
  userCtData' `shouldBe` userCtData

testUpdateContactShortLink :: IO ()
testUpdateContactShortLink = do
  -- encrypt
  g <- C.newRandom
  sigKeys <- atomically $ C.generateKeyPair @'C.Ed25519 g
  let userData = UserLinkData "some user data"
      userCtData = UserContactData {direct = True, owners = [], relays = [], userData}
      userLinkData = UserContactLinkData userCtData
      (linkKey, linkData) = SL.encodeSignLinkData sigKeys supportedSMPAgentVRange contactConnRequest userLinkData
      (_linkId, k) = SL.contactShortLinkKdf linkKey
  Right (fd, _ud) <- runExceptT $ SL.encryptLinkData g k linkData
  -- encrypt updated user data
  let updatedUserData = UserLinkData "updated user data"
      userCtData' = UserContactData {direct = False, owners = [], relays = [relayLink1, relayLink2], userData = updatedUserData}
      userLinkData' = UserContactLinkData userCtData'
      signed = SL.encodeSignUserData SCMContact (snd sigKeys) supportedSMPAgentVRange userLinkData'
  Right ud' <- runExceptT $ SL.encryptUserData g k signed
  -- decrypt
  Right (connReq, ContactLinkData _ userCtData'') <- pure $ SL.decryptLinkData @'CMContact linkKey k (fd, ud')
  connReq `shouldBe` contactConnRequest
  userCtData'' `shouldBe` userCtData'

testContactShortLinkBadDataHash :: IO ()
testContactShortLinkBadDataHash = do
  -- encrypt
  g <- C.newRandom
  sigKeys <- atomically $ C.generateKeyPair @'C.Ed25519 g
  let userData = UserLinkData "some user data"
      userLinkData = UserContactLinkData UserContactData {direct = True, owners = [], relays = [], userData}
      (_linkKey, linkData) = SL.encodeSignLinkData sigKeys supportedSMPAgentVRange contactConnRequest userLinkData
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
      userLinkData = UserContactLinkData UserContactData {direct = True, owners = [], relays = [], userData}
      (linkKey, linkData) = SL.encodeSignLinkData sigKeys supportedSMPAgentVRange contactConnRequest userLinkData
      (_linkId, k) = SL.contactShortLinkKdf linkKey
  Right (fd, _ud) <- runExceptT $ SL.encryptLinkData g k linkData
  -- encrypt updated user data
  let updatedUserData = UserLinkData "updated user data"
      userLinkData' = UserContactLinkData UserContactData {direct = True, owners = [], relays = [], userData = updatedUserData}
  -- another signature key
  (_, pk) <- atomically $ C.generateKeyPair @'C.Ed25519 g
  let signed = SL.encodeSignUserData SCMContact pk supportedSMPAgentVRange userLinkData'
  Right ud' <- runExceptT $ SL.encryptUserData g k signed
  -- decryption fails
  SL.decryptLinkData @'CMContact linkKey k (fd, ud')
    `shouldBe` Left (AGENT (A_LINK "user data signature"))
    
testContactShortLinkOwner :: IO ()
testContactShortLinkOwner = do
  -- encrypt
  g <- C.newRandom
  (pk, lnk) <- encryptLink g
  -- encrypt updated user data
  (ownerPK, owner) <- authNewOwner g pk
  let ud = UserContactData {direct = True, owners = [owner], relays = [], userData = UserLinkData "updated user data"}
  testEncDec g pk lnk ud
  testEncDec g ownerPK lnk ud
  (_, wrongKey) <- atomically $ C.generateKeyPair @'C.Ed25519 g
  testEncDecFail g wrongKey lnk ud $ A_LINK "user data signature"

encryptLink :: TVar ChaChaDRG -> IO (C.PrivateKeyEd25519, (EncFixedDataBytes, LinkKey, C.SbKey))
encryptLink g = do
  sigKeys@(_, pk) <- atomically $ C.generateKeyPair @'C.Ed25519 g
  let userData = UserLinkData "some user data"
      userLinkData = UserContactLinkData UserContactData {direct = True, owners = [], relays = [], userData}
      (linkKey, linkData) = SL.encodeSignLinkData sigKeys supportedSMPAgentVRange contactConnRequest userLinkData
      (_linkId, k) = SL.contactShortLinkKdf linkKey
  Right (fd, _ud) <- runExceptT $ SL.encryptLinkData g k linkData
  pure (pk, (fd, linkKey, k))

authNewOwner :: TVar ChaChaDRG -> C.PrivateKeyEd25519 -> IO (C.PrivateKeyEd25519, OwnerAuth)
authNewOwner g pk = do
  (ownerKey, ownerPK) <- atomically $ C.generateKeyPair @'C.Ed25519 g
  ownerId <- atomically $ C.randomBytes 16 g
  let authOwnerSig = C.sign' pk $ ownerId <> C.encodePubKey ownerKey
  pure (ownerPK, OwnerAuth {ownerId, ownerKey, authOwnerSig})

testEncDec :: TVar ChaChaDRG -> C.PrivateKeyEd25519 -> (EncFixedDataBytes, LinkKey, C.SbKey) -> UserContactData -> IO ()
testEncDec g pk (fd, linkKey, k) ctData = do
  let signed = SL.encodeSignUserData SCMContact pk supportedSMPAgentVRange $ UserContactLinkData ctData
  Right ud <- runExceptT $ SL.encryptUserData g k signed
  Right (connReq', ContactLinkData _ ctData') <- pure $ SL.decryptLinkData @'CMContact linkKey k (fd, ud)
  connReq' `shouldBe` contactConnRequest
  ctData' `shouldBe` ctData

testContactShortLinkManyOwners :: IO ()
testContactShortLinkManyOwners = do
  -- encrypt
  g <- C.newRandom
  (pk, lnk) <- encryptLink g
  -- encrypt updated user data
  (ownerPK1, owner1) <- authNewOwner g pk
  (ownerPK2, owner2) <- authNewOwner g pk
  (ownerPK3, owner3) <- authNewOwner g ownerPK1
  (ownerPK4, owner4) <- authNewOwner g ownerPK1
  (ownerPK5, owner5) <- authNewOwner g ownerPK3
  let owners = [owner1, owner2, owner3, owner4, owner5]
      ud = UserContactData {direct = True, owners, relays = [], userData = UserLinkData "updated user data"}
  testEncDec g pk lnk ud
  testEncDec g ownerPK1 lnk ud
  testEncDec g ownerPK2 lnk ud
  testEncDec g ownerPK3 lnk ud
  testEncDec g ownerPK4 lnk ud
  testEncDec g ownerPK5 lnk ud
  (_, wrongKey) <- atomically $ C.generateKeyPair @'C.Ed25519 g
  testEncDecFail g wrongKey lnk ud $ A_LINK "user data signature"

testContactShortLinkInvalidOwners :: IO ()
testContactShortLinkInvalidOwners = do
  -- encrypt
  g <- C.newRandom
  (pk, lnk) <- encryptLink g
  -- encrypt updated user data
  (ownerPK, owner) <- authNewOwner g pk
  let mkCtData owners = UserContactData {direct = True, owners, relays = [], userData = UserLinkData "updated user data"}
  -- decryption fails: owner uses root key
  let ud = mkCtData [owner {ownerKey = C.publicKey pk}]
      err = A_LINK $ "owner key for ID " <> ownerIdStr owner <> " matches root key"
  testEncDecFail g pk lnk ud err
  testEncDecFail g ownerPK lnk ud err
  -- decryption fails: duplicate owner ID or key
  (ownerPK1, owner1) <- authNewOwner g pk
  let ud1 = mkCtData [owner, owner1 {ownerId = ownerId owner}]
      ud1' = mkCtData [owner, owner1 {ownerKey = ownerKey owner}]
      err1 o = A_LINK $ "duplicate owner key or ID " <> ownerIdStr o
  testEncDecFail g pk lnk ud1 $ err1 owner
  testEncDecFail g pk lnk ud1' $ err1 owner1
  -- decryption fails: wrong order
  (ownerPK2, owner2) <- authNewOwner g ownerPK
  let ud2 = mkCtData [owner, owner1, owner2]
      ud2' = mkCtData [owner, owner2, owner1]
  testEncDec g pk lnk ud2
  testEncDec g pk lnk ud2'
  testEncDec g ownerPK lnk ud2
  testEncDec g ownerPK1 lnk ud2
  testEncDec g ownerPK2 lnk ud2
  let ud2'' = mkCtData [owner2, owner, owner1]
      err2 = A_LINK $ "invalid authorization of owner ID " <> ownerIdStr owner2
  testEncDecFail g pk lnk ud2'' err2
  -- decryption fails: authorized with wrong key
  (_, wrongKey) <- atomically $ C.generateKeyPair @'C.Ed25519 g
  (_, owner3) <- authNewOwner g wrongKey
  let ud3 = mkCtData [owner3]
      ud3' = mkCtData [owner, owner1, owner2, owner3]
      err3 = A_LINK $ "invalid authorization of owner ID " <> ownerIdStr owner3
  testEncDecFail g pk lnk ud3 err3
  testEncDecFail g pk lnk ud3' err3

testEncDecFail :: TVar ChaChaDRG -> C.PrivateKeyEd25519 -> (EncFixedDataBytes, LinkKey, C.SbKey) -> UserContactData -> SMPAgentError -> IO ()
testEncDecFail g pk (fd, linkKey, k) ctData err = do
  let signed = SL.encodeSignUserData SCMContact pk supportedSMPAgentVRange $ UserContactLinkData ctData
  Right ud <- runExceptT $ SL.encryptUserData g k signed
  SL.decryptLinkData @'CMContact linkKey k (fd, ud) `shouldBe` Left (AGENT err)

ownerIdStr :: OwnerAuth -> String
ownerIdStr OwnerAuth {ownerId} = B.unpack $ B64.encodeUnpadded ownerId
