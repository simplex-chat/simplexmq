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
        `shouldBe` "https://simplex.chat/connect#/?smp=smp%3A%2F%2F1234-w%3D%3D%40smp.simplex.im%3A5223%2F1234-w%3D%3D%23&e2e=rsa%3AMBowDQYJKoZIhvcNAQEBBQADCQAwBgIBAAIBAA%3D%3D"
    it "should parse connection requests" $ do
      -- print $ parseSMPMessage "\n0 2021-11-29T19:23:27.005Z \nREPLY simplex:/connect#/?smp=smp%3A%2F%2FKXNE1m2E1m0lm92WGKet9CL6-lO742Vy5G6nsrkvgs8%3D%40localhost%3A5000%2FoWWCE_5ug0t05K6X%23&e2e=rsa%3AMIIBoDANBgkqhkiG9w0BAQEFAAOCAY0AMIIBiAKCAQEA3O4frbgUMRO%2B8FIX2%2ByqB%2F1B5pXmt%2F%2FY0dFd2HCVxL31TJHc90HJp92Qb7Ni%2B1dI2Ka1Hb1Fvup897mmEcFhZStG0OB6jffvPyxXCas8Tov3l757qCUZKqgTxSJkL7JvLkIN9jMs50islvrSHCAj8VReh5oR%2B8OFp8ITd5MuMHYuR1bt0XLl1TwSIyfRSQqtHlt%2FEBbEbWcgJMsDXMi3o983nezvF9En9F7OCnasdzKAsgcN2%2FdWp3CPeuMNe9epzrirxGfCKU%2FlVyZ77e7NZMkSmeOIDPGuE4Fk8bweAYArV%2FrECBJGBQkGx3YtEh0kIbCakQ1ZnKY%2F%2FMq0ZHGPhQKBgGRKfJ7xXftoLdVJ7EOW%2FR5Y%2Bj%2F%2Bb9yZMbTCdZfkuroV9FH8GF5tS3PWuSAOFu42h7TiqFjXlvM6aYp%2FBXxCosZjBlB6mWCLyuY48ZszhtCpLSlbR2x%2FpGMUEgyOsefeMusrHEqFJAI%2Fhh8LljBGL%2BV08qcGFxVTwCVePIjDOo1H\n"
      parseAll connReqP "https://simplex.chat/connect#/?smp=smp%3A%2F%2F1234-w%3D%3D%40smp.simplex.im%3A5223%2F1234-w%3D%3D%23&e2e=rsa%3AMBowDQYJKoZIhvcNAQEBBQADCQAwBgIBAAIBAA%3D%3D"
        `shouldBe` Right connectionRequest
