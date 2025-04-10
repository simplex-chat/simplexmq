{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE TypeApplications #-}
{-# OPTIONS_GHC -Wno-orphans #-}
{-# OPTIONS_GHC -fno-warn-ambiguous-fields #-}

module AgentTests.ConnectionRequestTests
  ( connectionRequestTests,
    connReqData,
    queueAddr,
    testE2ERatchetParams12,
    contactConnRequest,
    invConnRequest,
  ) where

import Data.ByteString (ByteString)
import Network.HTTP.Types (urlEncode)
import Simplex.Messaging.Agent.Protocol
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Crypto.Ratchet
import Simplex.Messaging.Encoding
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Protocol (EntityId (..), ProtocolServer (..), QueueMode (..), currentSMPClientVersion, supportedSMPClientVRange, pattern VersionSMPC)
import Simplex.Messaging.ServiceScheme (ServiceScheme (..))
import Simplex.Messaging.Version
import Test.Hspec

srv :: SMPServer
srv = SMPServer "smp.simplex.im,jjbyvoemxysm7qxap7m5d5m35jzv5qq6gnlv7s4rsn7tdwwmuqciwpid.onion" "5223" (C.KeyHash "\215m\248\251")

srv1 :: SMPServer
srv1 = SMPServer "smp.simplex.im" "5223" (C.KeyHash "\215m\248\251")

queueAddr :: SMPQueueAddress
queueAddr =
  SMPQueueAddress
    { smpServer = srv,
      senderId = EntityId "\223\142z\251",
      dhPublicKey = testDhKey,
      queueMode = Just QMMessaging
    }

queueAddrNoQM :: SMPQueueAddress
queueAddrNoQM = queueAddr {queueMode = Nothing}

queueAddrContact :: SMPQueueAddress
queueAddrContact = queueAddr {queueMode = Just QMContact}

queueAddr1 :: SMPQueueAddress
queueAddr1 = queueAddr {smpServer = srv1}

queueAddrNoPort :: SMPQueueAddress
queueAddrNoPort = queueAddr {smpServer = srv {port = ""}}

queueAddrNoPortNoQM :: SMPQueueAddress
queueAddrNoPortNoQM = queueAddrNoQM {smpServer = srv {port = ""}}

queueAddrNoPort1 :: SMPQueueAddress
queueAddrNoPort1 = queueAddr {smpServer = srv1 {port = ""}}

-- current version range includes version 1 and it uses legacy encoding
queue :: SMPQueueUri
queue = SMPQueueUri supportedSMPClientVRange queueAddr

queueNoQM :: SMPQueueUri
queueNoQM = SMPQueueUri supportedSMPClientVRange queueAddrNoQM

queueContact :: SMPQueueUri
queueContact = SMPQueueUri supportedSMPClientVRange queueAddrContact

queueStr :: ByteString
queueStr = "smp://1234-w==@smp.simplex.im:5223/3456-w==#/?v=1-4&dh=" <> url testDhKeyStr <> "&q=m&k=s" <> "&srv=jjbyvoemxysm7qxap7m5d5m35jzv5qq6gnlv7s4rsn7tdwwmuqciwpid.onion"

queueStrNoQM :: ByteString
queueStrNoQM = "smp://1234-w==@smp.simplex.im:5223/3456-w==#/?v=1-4&dh=" <> url testDhKeyStr <> "&srv=jjbyvoemxysm7qxap7m5d5m35jzv5qq6gnlv7s4rsn7tdwwmuqciwpid.onion"

queueStrContact :: ByteString
queueStrContact = "smp://1234-w==@smp.simplex.im:5223/3456-w==#/?v=1-4&dh=" <> url testDhKeyStr <> "&q=c" <> "&srv=jjbyvoemxysm7qxap7m5d5m35jzv5qq6gnlv7s4rsn7tdwwmuqciwpid.onion"

queue1 :: SMPQueueUri
queue1 = SMPQueueUri supportedSMPClientVRange queueAddr1

queue1Str :: ByteString
queue1Str = "smp://1234-w==@smp.simplex.im:5223/3456-w==#/?v=1-4&dh=" <> url testDhKeyStr <> "&q=m&k=s"

queueV1 :: SMPQueueUri
queueV1 = SMPQueueUri (mkVersionRange (VersionSMPC 1) (VersionSMPC 1)) queueAddrNoQM

queueV1NoPort :: SMPQueueUri
queueV1NoPort = (queueV1 :: SMPQueueUri) {queueAddress = queueAddrNoPortNoQM}

-- version range 2-3 uses new encoding
-- it is fixed/changed in v5.8.2.
queueNew :: SMPQueueUri
queueNew = SMPQueueUri (mkVersionRange (VersionSMPC 2) currentSMPClientVersion) queueAddr

queueNewStr :: ByteString
queueNewStr = "smp://1234-w==@smp.simplex.im,jjbyvoemxysm7qxap7m5d5m35jzv5qq6gnlv7s4rsn7tdwwmuqciwpid.onion:5223/3456-w==#/?v=2-4&dh=" <> url testDhKeyStr <> "&q=m&k=s"

queueNewStr' :: ByteString
queueNewStr' = "smp://1234-w==@smp.simplex.im,jjbyvoemxysm7qxap7m5d5m35jzv5qq6gnlv7s4rsn7tdwwmuqciwpid.onion:5223/3456-w==#/?v=2-4&dh=" <> testDhKeyStr <> "&q=m&k=s"

queueNewNoPort :: SMPQueueUri
queueNewNoPort = (queueNew :: SMPQueueUri) {queueAddress = queueAddrNoPort}

queueNew1 :: SMPQueueUri
queueNew1 = SMPQueueUri (mkVersionRange (VersionSMPC 2) currentSMPClientVersion) queueAddr1

queueNew1Str :: ByteString
queueNew1Str = "smp://1234-w==@smp.simplex.im:5223/3456-w==#/?v=2-4&dh=" <> url testDhKeyStr <> "&q=m&k=s"

queueNew1NoPort :: SMPQueueUri
queueNew1NoPort = (queueNew1 :: SMPQueueUri) {queueAddress = queueAddrNoPort1}

testDhKey :: C.PublicKeyX25519
testDhKey = "MCowBQYDK2VuAyEAjiswwI3O/NlS8Fk3HJUW870EY2bAwmttMBsvRB9eV3o="

testDhKeyStr :: ByteString
testDhKeyStr = strEncode testDhKey

connReqData :: ConnReqUriData
connReqData =
  ConnReqUriData
    { crScheme = SSSimplex,
      crAgentVRange = supportedSMPAgentVRange,
      crSmpQueues = [queue],
      crClientData = Nothing
    }

connReqDataNoQM :: ConnReqUriData
connReqDataNoQM = connReqData {crSmpQueues = [queueNoQM]}

connReqDataContact :: ConnReqUriData
connReqDataContact = connReqData {crSmpQueues = [queueContact]}

connReqData1 :: ConnReqUriData
connReqData1 = connReqData {crSmpQueues = [queue1]}

connReqDataV1 :: ConnReqUriData
connReqDataV1 = connReqData {crAgentVRange = mkVersionRange (VersionSMPA 1) (VersionSMPA 1)}

connReqDataV2 :: ConnReqUriData
connReqDataV2 = connReqData {crAgentVRange = mkVersionRange (VersionSMPA 2) (VersionSMPA 2)}

connReqDataNew :: ConnReqUriData
connReqDataNew = connReqData {crSmpQueues = [queueNew]}

connReqDataNew1 :: ConnReqUriData
connReqDataNew1 = connReqData {crSmpQueues = [queueNew1]}

testDhPubKey :: C.PublicKeyX448
testDhPubKey = "MEIwBQYDK2VvAzkAmKuSYeQ/m0SixPDS8Wq8VBaTS1cW+Lp0n0h4Diu+kUpR+qXx4SDJ32YGEFoGFGSbGPry5Ychr6U="

testE2ERatchetParams :: RcvE2ERatchetParamsUri 'C.X448
testE2ERatchetParams = E2ERatchetParamsUri (mkVersionRange (VersionE2E 1) (VersionE2E 1)) testDhPubKey testDhPubKey Nothing

testE2ERatchetParamsStrUri :: ByteString
testE2ERatchetParamsStrUri = "v%3D1%26x3dh%3DMEIwBQYDK2VvAzkAmKuSYeQ_m0SixPDS8Wq8VBaTS1cW-Lp0n0h4Diu-kUpR-qXx4SDJ32YGEFoGFGSbGPry5Ychr6U%3D%2CMEIwBQYDK2VvAzkAmKuSYeQ_m0SixPDS8Wq8VBaTS1cW-Lp0n0h4Diu-kUpR-qXx4SDJ32YGEFoGFGSbGPry5Ychr6U%3D"

testE2ERatchetParams12 :: RcvE2ERatchetParamsUri 'C.X448
testE2ERatchetParams12 = E2ERatchetParamsUri supportedE2EEncryptVRange testDhPubKey testDhPubKey Nothing

connectionRequest :: AConnectionRequestUri
connectionRequest = ACR SCMInvitation invConnRequest

invConnRequest :: ConnectionRequestUri 'CMInvitation
invConnRequest = CRInvitationUri connReqData testE2ERatchetParams

connectionRequestNoQM :: AConnectionRequestUri
connectionRequestNoQM = ACR SCMInvitation $ CRInvitationUri connReqDataNoQM testE2ERatchetParams

connectionRequestContact :: AConnectionRequestUri
connectionRequestContact = ACR SCMContact $ CRContactUri connReqDataContact

connectionRequestV1 :: AConnectionRequestUri
connectionRequestV1 = ACR SCMInvitation $ CRInvitationUri connReqDataV1 testE2ERatchetParams

connectionRequest1 :: AConnectionRequestUri
connectionRequest1 = ACR SCMInvitation $ CRInvitationUri connReqData1 testE2ERatchetParams

connectionRequestNew :: AConnectionRequestUri
connectionRequestNew = ACR SCMInvitation $ CRInvitationUri connReqDataNew testE2ERatchetParams

connectionRequestNew1 :: AConnectionRequestUri
connectionRequestNew1 = ACR SCMInvitation $ CRInvitationUri connReqDataNew1 testE2ERatchetParams

contactAddress :: AConnectionRequestUri
contactAddress = ACR SCMContact $ contactConnRequest

contactConnRequest :: ConnectionRequestUri 'CMContact
contactConnRequest = CRContactUri connReqData

contactAddressV2 :: AConnectionRequestUri
contactAddressV2 = ACR SCMContact $ CRContactUri connReqDataV2

contactAddressNew :: AConnectionRequestUri
contactAddressNew = ACR SCMContact $ CRContactUri connReqDataNew

connectionRequest2queues :: AConnectionRequestUri
connectionRequest2queues = ACR SCMInvitation $ CRInvitationUri connReqData {crSmpQueues = [queue, queue]} testE2ERatchetParams

connectionRequest2queuesNew :: AConnectionRequestUri
connectionRequest2queuesNew = ACR SCMInvitation $ CRInvitationUri connReqDataNew {crSmpQueues = [queueNew, queueNew]} testE2ERatchetParams

contactAddress2queues :: AConnectionRequestUri
contactAddress2queues = ACR SCMContact $ CRContactUri connReqData {crSmpQueues = [queue, queue]}

contactAddress2queuesNew :: AConnectionRequestUri
contactAddress2queuesNew = ACR SCMContact $ CRContactUri connReqDataNew {crSmpQueues = [queueNew, queueNew]}

connectionRequestClientDataEmpty :: AConnectionRequestUri
connectionRequestClientDataEmpty = ACR SCMInvitation $ CRInvitationUri connReqData {crClientData = Just "{}"} testE2ERatchetParams

contactAddressClientData :: AConnectionRequestUri
contactAddressClientData = ACR SCMContact $ CRContactUri connReqData {crClientData = Just "{\"type\":\"group_link\", \"group_link_id\":\"abc\"}"}

url :: ByteString -> ByteString
url = urlEncode True

(==#) :: (StrEncoding a, HasCallStack) => a -> ByteString -> Expectation
a ==# s = strEncode a `shouldBe` s

(#==) :: (StrEncoding a, Eq a, Show a, HasCallStack) => a -> ByteString -> Expectation
a #== s = strDecode s `shouldBe` Right a

(#==#) :: (StrEncoding a, Eq a, Show a, HasCallStack) => a -> ByteString -> Expectation
a #==# s = do
  a ==# s
  a #== s

connectionRequestTests :: Spec
connectionRequestTests =
  describe "connection request parsing / serializing" $ do
    it "should serialize and parse SMP queue URIs" $ do
      queue #==# queueStr
      queue #== ("smp://1234-w==@smp.simplex.im:5223/3456-w==#" <> testDhKeyStr <> "/?v=1-4&extra_param=abc&srv=jjbyvoemxysm7qxap7m5d5m35jzv5qq6gnlv7s4rsn7tdwwmuqciwpid.onion&q=m&k=s")
      queueNoQM #==# queueStrNoQM
      queueContact #==# queueStrContact
      queue1 #==# queue1Str
      queueNew #==# queueNewStr
      queueNew #== queueNewStr'
      queueNew1 #==# queueNew1Str
      queueNewNoPort #==# ("smp://1234-w==@smp.simplex.im,jjbyvoemxysm7qxap7m5d5m35jzv5qq6gnlv7s4rsn7tdwwmuqciwpid.onion/3456-w==#/?v=2-4&dh=" <> url testDhKeyStr <> "&q=m&k=s")
      queueNew1NoPort #==# ("smp://1234-w==@smp.simplex.im/3456-w==#/?v=2-4&dh=" <> url testDhKeyStr <> "&q=m&k=s")
      queueV1 #==# ("smp://1234-w==@smp.simplex.im:5223/3456-w==#/?v=1&dh=" <> url testDhKeyStr <> "&srv=jjbyvoemxysm7qxap7m5d5m35jzv5qq6gnlv7s4rsn7tdwwmuqciwpid.onion")
      queueV1 #== ("smp://1234-w==@smp.simplex.im,jjbyvoemxysm7qxap7m5d5m35jzv5qq6gnlv7s4rsn7tdwwmuqciwpid.onion:5223/3456-w==#" <> testDhKeyStr)
      queueV1 #== ("smp://1234-w==@smp.simplex.im:5223/3456-w==#/?extra_param=abc&v=1&dh=" <> testDhKeyStr <> "&srv=jjbyvoemxysm7qxap7m5d5m35jzv5qq6gnlv7s4rsn7tdwwmuqciwpid.onion")
      queueV1 #== ("smp://1234-w==@smp.simplex.im:5223/3456-w==#" <> testDhKeyStr <> "/?v=1&extra_param=abc&srv=jjbyvoemxysm7qxap7m5d5m35jzv5qq6gnlv7s4rsn7tdwwmuqciwpid.onion")
      queueV1NoPort #==# ("smp://1234-w==@smp.simplex.im/3456-w==#/?v=1&dh=" <> url testDhKeyStr <> "&srv=jjbyvoemxysm7qxap7m5d5m35jzv5qq6gnlv7s4rsn7tdwwmuqciwpid.onion")
      queueV1NoPort #== ("smp://1234-w==@smp.simplex.im/3456-w==#/?v=1-1&dh=" <> url testDhKeyStr <> "&srv=jjbyvoemxysm7qxap7m5d5m35jzv5qq6gnlv7s4rsn7tdwwmuqciwpid.onion")
      queueV1NoPort #== ("smp://1234-w==@smp.simplex.im,jjbyvoemxysm7qxap7m5d5m35jzv5qq6gnlv7s4rsn7tdwwmuqciwpid.onion/3456-w==#" <> testDhKeyStr)
    it "should serialize and parse connection invitations and contact addresses" $ do
      connectionRequest #==# ("simplex:/invitation#/?v=2-7&smp=" <> url queueStr <> "&e2e=" <> testE2ERatchetParamsStrUri)
      connectionRequest #== ("https://simplex.chat/invitation#/?v=2-7&smp=" <> url queueStr <> "&e2e=" <> testE2ERatchetParamsStrUri)
      connectionRequestNoQM #==# ("simplex:/invitation#/?v=2-7&smp=" <> url queueStrNoQM <> "&e2e=" <> testE2ERatchetParamsStrUri)
      connectionRequest1 #==# ("simplex:/invitation#/?v=2-7&smp=" <> url queue1Str <> "&e2e=" <> testE2ERatchetParamsStrUri)
      connectionRequest2queues #==# ("simplex:/invitation#/?v=2-7&smp=" <> url (queueStr <> ";" <> queueStr) <> "&e2e=" <> testE2ERatchetParamsStrUri)
      connectionRequestNew #==# ("simplex:/invitation#/?v=2-7&smp=" <> url queueNewStr <> "&e2e=" <> testE2ERatchetParamsStrUri)
      connectionRequestNew1 #==# ("simplex:/invitation#/?v=2-7&smp=" <> url queueNew1Str <> "&e2e=" <> testE2ERatchetParamsStrUri)
      connectionRequest2queuesNew #==# ("simplex:/invitation#/?v=2-7&smp=" <> url (queueNewStr <> ";" <> queueNewStr) <> "&e2e=" <> testE2ERatchetParamsStrUri)
      connectionRequestV1 #== ("https://simplex.chat/invitation#/?v=1&smp=" <> url queueStr <> "&e2e=" <> testE2ERatchetParamsStrUri)
      connectionRequestClientDataEmpty #==# ("simplex:/invitation#/?v=2-7&smp=" <> url queueStr <> "&e2e=" <> testE2ERatchetParamsStrUri <> "&data=" <> url "{}")
      contactAddress #==# ("simplex:/contact#/?v=2-7&smp=" <> url queueStr)
      contactAddress #== ("https://simplex.chat/contact#/?v=2-7&smp=" <> url queueStr)
      contactAddress2queues #==# ("simplex:/contact#/?v=2-7&smp=" <> url (queueStr <> ";" <> queueStr))
      contactAddressNew #==# ("simplex:/contact#/?v=2-7&smp=" <> url queueNewStr)
      contactAddress2queuesNew #==# ("simplex:/contact#/?v=2-7&smp=" <> url (queueNewStr <> ";" <> queueNewStr))
      contactAddressV2 #==# ("simplex:/contact#/?v=2&smp=" <> url queueStr)
      contactAddressV2 #== ("https://simplex.chat/contact#/?v=1&smp=" <> url queueStr) -- adjusted to v2
      contactAddressV2 #== ("https://simplex.chat/contact#/?v=1-2&smp=" <> url queueStr) -- adjusted to v2
      contactAddressV2 #== ("https://simplex.chat/contact#/?v=2-2&smp=" <> url queueStr)
      contactAddressClientData #==# ("simplex:/contact#/?v=2-7&smp=" <> url queueStr <> "&data=" <> url "{\"type\":\"group_link\", \"group_link_id\":\"abc\"}")
    it "should serialize / parse queue address, connection invitations and contact addresses as binary" $ do
      smpEncodingTest queue
      smpEncodingTest queueNoQM -- this passes, no queue mode patch in SMPQueueUri encoding
      -- smpEncodingTest queueContact -- this fails until SMP client min version is >= sndAuthKeySMPClientVersion
      smpEncodingTest queue1
      smpEncodingTest queueNew
      smpEncodingTest queueNew1
      smpEncodingTest queueNewNoPort
      smpEncodingTest queueNew1NoPort
      smpEncodingTest queueV1
      smpEncodingTest queueV1NoPort
      smpEncodingTest connectionRequest
      -- smpEncodingTest connectionRequestNoQM -- this fails, because of queue mode patch
      smpEncodingTest connectionRequestContact  -- this passes because of queue mode patch in ConnReqUriData encoding
      smpEncodingTest connectionRequest1
      smpEncodingTest connectionRequest2queues
      smpEncodingTest connectionRequestNew
      smpEncodingTest connectionRequestNew1
      smpEncodingTest connectionRequest2queuesNew
      smpEncodingTest connectionRequestClientDataEmpty
      smpEncodingTest contactAddress
      smpEncodingTest contactAddress2queues
      smpEncodingTest contactAddressNew
      smpEncodingTest contactAddress2queuesNew
      smpEncodingTest contactAddressV2
      smpEncodingTest contactAddressClientData
    it "should serialize / parse short links" $ do
      CSLContact SLSServer CCTContact srv (LinkKey "0123456789abcdef0123456789abcdef") #==# "https://smp.simplex.im/a#MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY?h=jjbyvoemxysm7qxap7m5d5m35jzv5qq6gnlv7s4rsn7tdwwmuqciwpid.onion&p=5223&c=1234-w"
      CSLContact SLSServer CCTGroup srv (LinkKey "0123456789abcdef0123456789abcdef") #==# "https://smp.simplex.im/g#MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY?h=jjbyvoemxysm7qxap7m5d5m35jzv5qq6gnlv7s4rsn7tdwwmuqciwpid.onion&p=5223&c=1234-w"
      CSLContact SLSServer CCTContact shortSrv (LinkKey "0123456789abcdef0123456789abcdef") #==# "https://smp.simplex.im/a#MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY"
      CSLInvitation SLSServer srv (EntityId "0123456789abcdef01234567") (LinkKey "0123456789abcdef0123456789abcdef") #==# "https://smp.simplex.im/i#MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3/MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY?h=jjbyvoemxysm7qxap7m5d5m35jzv5qq6gnlv7s4rsn7tdwwmuqciwpid.onion&p=5223&c=1234-w"
      CSLInvitation SLSServer shortSrv (EntityId "0123456789abcdef01234567") (LinkKey "0123456789abcdef0123456789abcdef") #==# "https://smp.simplex.im/i#MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3/MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY"
      CSLContact SLSSimplex CCTContact srv (LinkKey "0123456789abcdef0123456789abcdef") #==# "simplex:/a#MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY?h=smp.simplex.im%2Cjjbyvoemxysm7qxap7m5d5m35jzv5qq6gnlv7s4rsn7tdwwmuqciwpid.onion&p=5223&c=1234-w"
      CSLContact SLSSimplex CCTGroup srv (LinkKey "0123456789abcdef0123456789abcdef") #==# "simplex:/g#MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY?h=smp.simplex.im%2Cjjbyvoemxysm7qxap7m5d5m35jzv5qq6gnlv7s4rsn7tdwwmuqciwpid.onion&p=5223&c=1234-w"
      CSLContact SLSSimplex CCTContact shortSrv (LinkKey "0123456789abcdef0123456789abcdef") #==# "simplex:/a#MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY?h=smp.simplex.im"
      CSLInvitation SLSSimplex srv (EntityId "0123456789abcdef01234567") (LinkKey "0123456789abcdef0123456789abcdef") #==# "simplex:/i#MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3/MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY?h=smp.simplex.im%2Cjjbyvoemxysm7qxap7m5d5m35jzv5qq6gnlv7s4rsn7tdwwmuqciwpid.onion&p=5223&c=1234-w"
      CSLInvitation SLSSimplex shortSrv (EntityId "0123456789abcdef01234567") (LinkKey "0123456789abcdef0123456789abcdef") #==# "simplex:/i#MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3/MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY?h=smp.simplex.im"
    it "should shorten / restore short links" $ do
      let contact = CSLContact SLSServer CCTContact
      shortenShortLink [srv] (contact srv (LinkKey "0123456789abcdef0123456789abcdef"))
        `shouldBe` contact shortSrv (LinkKey "0123456789abcdef0123456789abcdef")
      -- won't shorten link that uses only onion host from preset server
      shortenShortLink [srv] (contact srvOnion (LinkKey "0123456789abcdef0123456789abcdef"))
        `shouldBe` contact srvOnion (LinkKey "0123456789abcdef0123456789abcdef")
      -- will shorten link that uses only public host from preset server
      shortenShortLink [srv] (contact srv1 (LinkKey "0123456789abcdef0123456789abcdef"))
        `shouldBe` contact shortSrv (LinkKey "0123456789abcdef0123456789abcdef")
      shortenShortLink [srv] (contact srv2 (LinkKey "0123456789abcdef0123456789abcdef"))
        `shouldBe` contact srv2 (LinkKey "0123456789abcdef0123456789abcdef")
      restoreShortLink [srv] (contact shortSrv (LinkKey "0123456789abcdef0123456789abcdef"))
        `shouldBe` contact srv (LinkKey "0123456789abcdef0123456789abcdef")
      -- won't change link that has only public host of preset server with keyhash
      restoreShortLink [srv] (contact srv1 (LinkKey "0123456789abcdef0123456789abcdef"))
        `shouldBe` contact srv1 (LinkKey "0123456789abcdef0123456789abcdef")
      restoreShortLink [srv2] (contact shortSrv (LinkKey "0123456789abcdef0123456789abcdef"))
        `shouldBe` contact shortSrv (LinkKey "0123456789abcdef0123456789abcdef")
      restoreShortLink [srv] (contact srv2 (LinkKey "0123456789abcdef0123456789abcdef"))
        `shouldBe` contact srv2 (LinkKey "0123456789abcdef0123456789abcdef")
  where
    smpEncodingTest :: (Encoding a, Eq a, Show a, HasCallStack) => a -> Expectation
    smpEncodingTest a = smpDecode (smpEncode a) `shouldBe` Right a

shortSrv :: SMPServer
shortSrv = SMPServer "smp.simplex.im" "" (C.KeyHash "")

srvOnion :: SMPServer
srvOnion = SMPServer "jjbyvoemxysm7qxap7m5d5m35jzv5qq6gnlv7s4rsn7tdwwmuqciwpid.onion" "" (C.KeyHash "\215m\248\251")

srv2 :: SMPServer
srv2 = SMPServer "smp2.simplex.im,jjbyvoemxysm7qxap7m5d5m35jzv5qq6gnlv7s4rsn7tdwwmuqciwpid.onion" "" (C.KeyHash "\215m\248\251")
