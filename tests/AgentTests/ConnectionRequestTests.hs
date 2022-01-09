{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE OverloadedStrings #-}

module AgentTests.ConnectionRequestTests where

import Data.ByteString (ByteString)
import Network.HTTP.Types (urlEncode)
import Simplex.Messaging.Agent.Protocol
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Crypto.Ratchet
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Protocol (smpClientVersion)
import Simplex.Messaging.Version
import Test.Hspec

uri :: String
uri = "smp.simplex.im"

srv :: SMPServer
srv =
  SMPServer
    { host = "smp.simplex.im",
      port = Just "5223",
      keyHash = C.KeyHash "\215m\248\251"
    }

queue :: SMPQueueUri
queue =
  SMPQueueUri
    { smpServer = srv,
      senderId = "\223\142z\251",
      clientVersionRange = smpClientVersion,
      dhPublicKey = testDhKey
    }

testDhKey :: C.PublicKeyX25519
testDhKey = "MCowBQYDK2VuAyEAjiswwI3O/NlS8Fk3HJUW870EY2bAwmttMBsvRB9eV3o="

testDhKeyStr :: ByteString
testDhKeyStr = strEncode testDhKey

testDhKeyStrUri :: ByteString
testDhKeyStrUri = urlEncode True testDhKeyStr

connReqData :: ConnReqUriData
connReqData =
  ConnReqUriData
    { crScheme = simplexChat,
      crAgentVRange = smpAgentVRange,
      crSmpQueues = [queue]
    }

testDhPubKey :: C.PublicKeyX448
testDhPubKey = "MEIwBQYDK2VvAzkAmKuSYeQ/m0SixPDS8Wq8VBaTS1cW+Lp0n0h4Diu+kUpR+qXx4SDJ32YGEFoGFGSbGPry5Ychr6U="

testE2ERatchetParams :: E2ERatchetParamsUri 'C.X448
testE2ERatchetParams = E2ERatchetParamsUri e2eEncryptVRange testDhPubKey testDhPubKey

testE2ERatchetParams13 :: E2ERatchetParamsUri 'C.X448
testE2ERatchetParams13 = E2ERatchetParamsUri (mkVersionRange 1 3) testDhPubKey testDhPubKey

connectionRequest :: AConnectionRequestUri
connectionRequest =
  ACRU SCMInvitation $
    CRInvitationUri connReqData testE2ERatchetParams

connectionRequest12 :: AConnectionRequestUri
connectionRequest12 =
  ACRU SCMInvitation $
    CRInvitationUri
      connReqData {crAgentVRange = mkVersionRange 1 2, crSmpQueues = [queue, queue]}
      testE2ERatchetParams13

connectionRequestTests :: Spec
connectionRequestTests =
  describe "connection request parsing / serializing" $ do
    it "should serialize SMP queue URIs" $ do
      strEncode (queue :: SMPQueueUri) {smpServer = srv {port = Nothing}}
        `shouldBe` "smp://1234-w==@smp.simplex.im/3456-w==#" <> testDhKeyStr
      strEncode queue {clientVersionRange = mkVersionRange 1 2}
        `shouldBe` "smp://1234-w==@smp.simplex.im:5223/3456-w==#" <> testDhKeyStr
    it "should parse SMP queue URIs" $ do
      strDecode ("smp://1234-w==@smp.simplex.im/3456-w==#/?v=1&dh=" <> testDhKeyStr)
        `shouldBe` Right (queue :: SMPQueueUri) {smpServer = srv {port = Nothing}}
      strDecode ("smp://1234-w==@smp.simplex.im/3456-w==#" <> testDhKeyStr)
        `shouldBe` Right (queue :: SMPQueueUri) {smpServer = srv {port = Nothing}}
      strDecode ("smp://1234-w==@smp.simplex.im:5223/3456-w==#" <> testDhKeyStr)
        `shouldBe` Right queue
      strDecode ("smp://1234-w==@smp.simplex.im:5223/3456-w==#" <> testDhKeyStr <> "/?v=1&extra_param=abc")
        `shouldBe` Right queue
      strDecode ("smp://1234-w==@smp.simplex.im:5223/3456-w==#/?extra_param=abc&v=1-2&dh=" <> testDhKeyStr)
        `shouldBe` Right queue {clientVersionRange = mkVersionRange 1 2}
      strDecode ("smp://1234-w==@smp.simplex.im:5223/3456-w==#" <> testDhKeyStr <> "/?v=1-2&extra_param=abc")
        `shouldBe` Right queue {clientVersionRange = mkVersionRange 1 2}
    it "should serialize connection requests" $ do
      strEncode connectionRequest
        `shouldBe` "https://simplex.chat/invitation#/?v=1&smp=smp%3A%2F%2F1234-w%3D%3D%40smp.simplex.im%3A5223%2F3456-w%3D%3D%23"
        <> testDhKeyStrUri
        <> "&e2e=v%3D1%26x3dh%3DMEIwBQYDK2VvAzkAmKuSYeQ_m0SixPDS8Wq8VBaTS1cW-Lp0n0h4Diu-kUpR-qXx4SDJ32YGEFoGFGSbGPry5Ychr6U%3D%2CMEIwBQYDK2VvAzkAmKuSYeQ_m0SixPDS8Wq8VBaTS1cW-Lp0n0h4Diu-kUpR-qXx4SDJ32YGEFoGFGSbGPry5Ychr6U%3D"
      strEncode connectionRequest12
        `shouldBe` "https://simplex.chat/invitation#/?v=1-2&smp=smp%3A%2F%2F1234-w%3D%3D%40smp.simplex.im%3A5223%2F3456-w%3D%3D%23"
        <> testDhKeyStrUri
        <> "%2Csmp%3A%2F%2F1234-w%3D%3D%40smp.simplex.im%3A5223%2F3456-w%3D%3D%23"
        <> testDhKeyStrUri
        <> "&e2e=v%3D1-3%26x3dh%3DMEIwBQYDK2VvAzkAmKuSYeQ_m0SixPDS8Wq8VBaTS1cW-Lp0n0h4Diu-kUpR-qXx4SDJ32YGEFoGFGSbGPry5Ychr6U%3D%2CMEIwBQYDK2VvAzkAmKuSYeQ_m0SixPDS8Wq8VBaTS1cW-Lp0n0h4Diu-kUpR-qXx4SDJ32YGEFoGFGSbGPry5Ychr6U%3D"
    it "should parse connection requests" $ do
      strDecode
        ( "https://simplex.chat/invitation#/?smp=smp%3A%2F%2F1234-w%3D%3D%40smp.simplex.im%3A5223%2F3456-w%3D%3D%23"
            <> testDhKeyStrUri
            <> "&e2e=v%3D1%26x3dh%3DMEIwBQYDK2VvAzkAmKuSYeQ_m0SixPDS8Wq8VBaTS1cW-Lp0n0h4Diu-kUpR-qXx4SDJ32YGEFoGFGSbGPry5Ychr6U%3D%2CMEIwBQYDK2VvAzkAmKuSYeQ_m0SixPDS8Wq8VBaTS1cW-Lp0n0h4Diu-kUpR-qXx4SDJ32YGEFoGFGSbGPry5Ychr6U%3D"
            <> "&v=1"
        )
        `shouldBe` Right connectionRequest
      strDecode
        ( "https://simplex.chat/invitation#/?smp=smp%3A%2F%2F1234-w%3D%3D%40smp.simplex.im%3A5223%2F3456-w%3D%3D%23%2F%3Fv%3D1%26dh%3D"
            <> testDhKeyStrUri
            <> "&e2e=v%3D1%26x3dh%3DMEIwBQYDK2VvAzkAmKuSYeQ_m0SixPDS8Wq8VBaTS1cW-Lp0n0h4Diu-kUpR-qXx4SDJ32YGEFoGFGSbGPry5Ychr6U%3D%2CMEIwBQYDK2VvAzkAmKuSYeQ_m0SixPDS8Wq8VBaTS1cW-Lp0n0h4Diu-kUpR-qXx4SDJ32YGEFoGFGSbGPry5Ychr6U%3D"
            <> "&v=1"
        )
        `shouldBe` Right connectionRequest
      strDecode
        ( "https://simplex.chat/invitation#/?smp=smp%3A%2F%2F1234-w%3D%3D%40smp.simplex.im%3A5223%2F3456-w%3D%3D%23%2F%3Fv%3D1%26dh%3D"
            <> testDhKeyStrUri
            <> "&e2e=v%3D1-1%26x3dh%3DMEIwBQYDK2VvAzkAmKuSYeQ_m0SixPDS8Wq8VBaTS1cW-Lp0n0h4Diu-kUpR-qXx4SDJ32YGEFoGFGSbGPry5Ychr6U%3D%2CMEIwBQYDK2VvAzkAmKuSYeQ_m0SixPDS8Wq8VBaTS1cW-Lp0n0h4Diu-kUpR-qXx4SDJ32YGEFoGFGSbGPry5Ychr6U%3D"
            <> "&v=1-1"
        )
        `shouldBe` Right connectionRequest
      strDecode
        ( "https://simplex.chat/invitation#/?smp=smp%3A%2F%2F1234-w%3D%3D%40smp.simplex.im%3A5223%2F3456-w%3D%3D%23%2F%3Fv%3D1%26extra_param%3Dabc%26dh%3D"
            <> testDhKeyStrUri
            <> "%2Csmp%3A%2F%2F1234-w%3D%3D%40smp.simplex.im%3A5223%2F3456-w%3D%3D%23%2F%3Fv%3D1%26dh%3D"
            <> testDhKeyStrUri
            <> "&e2e=extra_key%3Dnew%26v%3D1-3%26x3dh%3DMEIwBQYDK2VvAzkAmKuSYeQ_m0SixPDS8Wq8VBaTS1cW-Lp0n0h4Diu-kUpR-qXx4SDJ32YGEFoGFGSbGPry5Ychr6U%3D%2CMEIwBQYDK2VvAzkAmKuSYeQ_m0SixPDS8Wq8VBaTS1cW-Lp0n0h4Diu-kUpR-qXx4SDJ32YGEFoGFGSbGPry5Ychr6U%3D"
            <> "&some_new_param=abc"
            <> "&v=1-2"
        )
        `shouldBe` Right connectionRequest12
