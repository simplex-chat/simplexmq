{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE OverloadedStrings #-}

module AgentTests.ConnectionRequestTests where

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
      senderId = "\215m\248\251",
      serverVerifyKey = reservedServerKey
    }

appServer :: ConnReqScheme
appServer = CRSAppServer "simplex.chat" Nothing

connectionRequest :: AConnectionRequest
connectionRequest =
  ACR SCMInvitation . CRInvitation $
    ConnReqData
      { crScheme = appServer,
        crSmpQueues = [queue],
        crEncryptKey = reservedServerKey
      }

connectionRequestTests :: Spec
connectionRequestTests = do
  describe "connection request parsing / serializing" $ do
    it "should serialize SMP queue URIs" $ do
      serializeSMPQueueUri queue {smpServer = srv {port = Nothing, keyHash = Nothing}}
        `shouldBe` "smp://smp.simplex.im/1234-w==#"
      serializeSMPQueueUri queue {smpServer = srv {keyHash = Nothing}}
        `shouldBe` "smp://smp.simplex.im:5223/1234-w==#"
      serializeSMPQueueUri queue {smpServer = srv {port = Nothing}}
        `shouldBe` "smp://1234-w==@smp.simplex.im/1234-w==#"
      serializeSMPQueueUri queue
        `shouldBe` "smp://1234-w==@smp.simplex.im:5223/1234-w==#"
    it "should parse SMP queue URIs" $ do
      parseAll smpQueueUriP "smp://smp.simplex.im/1234-w==#"
        `shouldBe` Right queue {smpServer = srv {port = Nothing, keyHash = Nothing}}
      parseAll smpQueueUriP "smp://smp.simplex.im:5223/1234-w==#"
        `shouldBe` Right queue {smpServer = srv {keyHash = Nothing}}
      parseAll smpQueueUriP "smp://1234-w==@smp.simplex.im/1234-w==#"
        `shouldBe` Right queue {smpServer = srv {port = Nothing}}
      parseAll smpQueueUriP "smp://1234-w==@smp.simplex.im:5223/1234-w==#"
        `shouldBe` Right queue
    it "should serialize connection requests" $ do
      serializeConnReq connectionRequest
        `shouldBe` "https://simplex.chat/invitation#/?smp=smp%3A%2F%2F1234-w%3D%3D%40smp.simplex.im%3A5223%2F1234-w%3D%3D%23&e2e=rsa%3AMBowDQYJKoZIhvcNAQEBBQADCQAwBgIBAAIBAA%3D%3D"
    it "should parse connection requests" $ do
      parseAll connReqP "https://simplex.chat/invitation#/?smp=smp%3A%2F%2F1234-w%3D%3D%40smp.simplex.im%3A5223%2F1234-w%3D%3D%23&e2e=rsa%3AMBowDQYJKoZIhvcNAQEBBQADCQAwBgIBAAIBAA%3D%3D"
        `shouldBe` Right connectionRequest
