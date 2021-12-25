{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE OverloadedStrings #-}

module AgentTests.ConnectionRequestTests where

import qualified Crypto.PubKey.RSA as R
import Simplex.Messaging.Agent.Protocol
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Parsers (parseAll)
import Test.Hspec

uri :: String
uri = "smp.simplex.im"

srv :: SMPServer
srv =
  SMPServer
    { host = "smp.simplex.im",
      port = Just "5223",
      keyHash = Just (C.KeyHash "\215m\248\251")
    }

queue :: SMPQueueUri
queue =
  SMPQueueUri
    { smpServer = srv,
      senderId = "\223\142z\251",
      dhPublicKey = Nothing
    }

testDhKey :: C.APublicDhKey
testDhKey = C.APublicDhKey C.SX25519 "MCowBQYDK2VuAyEAjiswwI3O/NlS8Fk3HJUW870EY2bAwmttMBsvRB9eV3o="

appServer :: ConnReqScheme
appServer = CRSAppServer "simplex.chat" Nothing

connectionRequest :: AConnectionRequest
connectionRequest =
  ACR SCMInvitation . CRInvitation $
    ConnReqData
      { crScheme = appServer,
        crSmpQueues = [queue],
        crEncryptKey = C.APublicEncryptKey C.SRSA (C.PublicKeyRSA $ R.PublicKey 1 0 0)
      }

connectionRequestTests :: Spec
connectionRequestTests = do
  describe "connection request parsing / serializing" $ do
    it "should serialize SMP queue URIs" $ do
      serializeSMPQueueUri queue {smpServer = srv {port = Nothing}}
        `shouldBe` "smp://1234-w==@smp.simplex.im/3456-w==#"
      serializeSMPQueueUri queue
        `shouldBe` "smp://1234-w==@smp.simplex.im:5223/3456-w==#"
      serializeSMPQueueUri queue {dhPublicKey = Just testDhKey}
        `shouldBe` "smp://1234-w==@smp.simplex.im:5223/3456-w==#x25519:MCowBQYDK2VuAyEAjiswwI3O_NlS8Fk3HJUW870EY2bAwmttMBsvRB9eV3o="
    it "should parse SMP queue URIs" $ do
      parseAll smpQueueUriP "smp://1234-w==@smp.simplex.im/3456-w==#"
        `shouldBe` Right queue {smpServer = srv {port = Nothing}}
      parseAll smpQueueUriP "smp://1234-w==@smp.simplex.im:5223/3456-w==#"
        `shouldBe` Right queue
      parseAll smpQueueUriP "smp://1234-w==@smp.simplex.im:5223/3456-w=="
        `shouldBe` Right queue
      parseAll smpQueueUriP ("smp://1234-w==@smp.simplex.im:5223/3456-w==#" <> C.serializeKeyUri testDhKey)
        `shouldBe` Right queue {dhPublicKey = Just testDhKey}
    it "should serialize connection requests" $ do
      serializeConnReq connectionRequest
        `shouldBe` "https://simplex.chat/invitation#/?smp=smp%3A%2F%2F1234-w%3D%3D%40smp.simplex.im%3A5223%2F3456-w%3D%3D%23&e2e=rsa%3AMBowDQYJKoZIhvcNAQEBBQADCQAwBgIBAAIBAA%3D%3D"
    it "should parse connection requests" $ do
      parseAll connReqP "https://simplex.chat/invitation#/?smp=smp%3A%2F%2F1234-w%3D%3D%40smp.simplex.im%3A5223%2F3456-w%3D%3D%23&e2e=rsa%3AMBowDQYJKoZIhvcNAQEBBQADCQAwBgIBAAIBAA%3D%3D"
        `shouldBe` Right connectionRequest
