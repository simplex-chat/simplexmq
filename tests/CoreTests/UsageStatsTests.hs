{-# LANGUAGE CPP #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module CoreTests.UsageStatsTests where

import Control.Monad (forM_, (<=<))
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.IORef (readIORef)
import qualified Data.IntMap.Strict as IM
import Data.List.NonEmpty (NonEmpty (..))
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Encoding (decodeLatin1)
import Network.Socket (SockAddr (..), tupleToHostAddress, tupleToHostAddress6)
import qualified Simplex.FileTransfer.Protocol as XFTP
import Simplex.FileTransfer.Server.Env (XFTPUsageCounter (..), xftpCmdCounter)
import Simplex.FileTransfer.Transport (supportedFileServerVRange)
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Protocol
import Simplex.Messaging.Server.Env.STM (SMPUsageCounter (..), smpCmdCounter)
import Simplex.Messaging.Server.UsageStats
import Simplex.Messaging.SimplexName (SimplexDomain (..), SimplexTLD (..))
import qualified Simplex.Messaging.TMap as TM
import Simplex.Messaging.Transport (supportedClientSMPRelayVRange, supportedServerSMPRelayVRange)
import Simplex.Messaging.Version (VersionRange (..))
import System.Timeout (timeout)
import Test.Hspec hiding (fit, it)
import UnliftIO.STM
import Util
#if defined(dbServerPostgres)
import qualified Simplex.Messaging.Notifications.Protocol as NTF
import Simplex.Messaging.Notifications.Server.Env (NtfUsageCounter (..), ntfCmdCounter)
import Simplex.Messaging.Notifications.Transport (supportedServerNTFVRange)
#endif

data TestCounter = TCConnections | TCSend | TCGet
  deriving (Eq, Ord, Enum, Bounded, Show)

instance UsageCounter TestCounter where
  counterName = \case
    TCConnections -> "connections"
    TCSend -> "SEND"
    TCGet -> "GET"
  counterBounds _ = [1, 2, 5, 10]
  connectionsCounter = TCConnections

addr1, addr2, addr3, addr4 :: ClientAddr
addr1 = ClientIPv4 $ read "10.0.0.1"
addr2 = ClientIPv4 $ read "10.0.0.2"
addr3 = ClientIPv4 $ read "10.0.0.3"
addr4 = ClientIPv4 $ read "10.0.0.4"

usageStatsTests :: Spec
usageStatsTests = do
  describe "clientAddr" clientAddrTests
  describe "bounds" boundsTests
  describe "counterByName" counterByNameTests
  describe "addUsage" addUsageTests
  describe "closeUsagePeriod" closeUsagePeriodTests
  describe "topClients" topClientsTests
  describe "usageMetrics" metricsTests
  describe "command counters" commandCounterTests

clientAddrTests :: Spec
clientAddrTests = do
  it "should use IPv4 address" $
    clientAddrText <$> clientAddr (ipv4 (192, 168, 1, 2)) `shouldBe` Just "192.168.1.2"
  it "should use IPv4 address of IPv4-mapped IPv6 address" $
    clientAddr (ipv6 (0, 0, 0, 0, 0, 0xffff, 0xc0a8, 0x0102)) `shouldBe` clientAddr (ipv4 (192, 168, 1, 2))
  it "should use one address for IPv6 addresses in one /64" $ do
    clientAddr (ipv6 (0x2001, 0xdb8, 1, 2, 3, 4, 5, 6)) `shouldBe` clientAddr (ipv6 (0x2001, 0xdb8, 1, 2, 7, 8, 9, 10))
    clientAddrText <$> clientAddr (ipv6 (0x2001, 0xdb8, 1, 2, 3, 4, 5, 6)) `shouldBe` Just "2001:db8:1:2::/64"
  it "should use different addresses for IPv6 addresses in different /64" $
    clientAddr (ipv6 (0x2001, 0xdb8, 1, 2, 3, 4, 5, 6)) `shouldNotBe` clientAddr (ipv6 (0x2001, 0xdb8, 1, 3, 3, 4, 5, 6))
  it "should not use other address types" $
    clientAddr (SockAddrUnix "tests/tmp/socket") `shouldBe` Nothing
  where
    ipv4 a = SockAddrInet 443 $ tupleToHostAddress a
    ipv6 a = SockAddrInet6 443 0 (tupleToHostAddress6 a) 0

boundsTests :: Spec
boundsTests = do
  it "should use R10 values up to 1000000 for counts" $
    countBounds
      `shouldBe` [ 1, 2, 3, 4, 5, 6, 7, 8, 9,
                   10, 13, 16, 20, 25, 32, 40, 50, 63, 80,
                   100, 125, 160, 200, 250, 315, 400, 500, 630, 800,
                   1000, 1250, 1600, 2000, 2500, 3150, 4000, 5000, 6300, 8000,
                   10000, 12500, 16000, 20000, 25000, 31500, 40000, 50000, 63000, 80000,
                   100000, 125000, 160000, 200000, 250000, 315000, 400000, 500000, 630000, 800000,
                   1000000
                 ]
  it "should use R10 values up to 100000000 for kilobytes" $ do
    take 60 kilobyteBounds `shouldBe` countBounds
    drop 59 kilobyteBounds
      `shouldBe` [ 1000000, 1250000, 1600000, 2000000, 2500000, 3150000, 4000000, 5000000, 6300000, 8000000,
                   10000000, 12500000, 16000000, 20000000, 25000000, 31500000, 40000000, 50000000, 63000000, 80000000,
                   100000000
                 ]

counterByNameTests :: Spec
counterByNameTests = do
  it "should find SMP counters" $ testCounterNames [minBound .. maxBound :: SMPUsageCounter]
  it "should find XFTP counters" $ testCounterNames [minBound .. maxBound :: XFTPUsageCounter]
#if defined(dbServerPostgres)
  it "should find NTF counters" $ testCounterNames [minBound .. maxBound :: NtfUsageCounter]
#endif
  it "should not find unknown counter" $
    counterByName "unknown" `shouldBe` (Nothing :: Maybe SMPUsageCounter)
  where
    testCounterNames :: (UsageCounter c, Show c) => [c] -> Expectation
    testCounterNames cs = map (counterByName . counterName) cs `shouldBe` map Just cs

addUsageTests :: Spec
addUsageTests = do
  it "should count usage of one address in one entry" $ do
    stats@UsageStats {clientCounts} <- newUsageStats
    incUsage (ClientUsage stats addr1) TCSend
    incUsage (ClientUsage stats addr1) TCSend
    incUsage (ClientUsage stats addr2) TCGet
    M.keys <$> readTVarIO clientCounts `shouldReturn` [addr1, addr2]
    counts stats addr1 TCSend `shouldReturn` Just (0, 2)
    counts stats addr2 TCGet `shouldReturn` Just (0, 1)
  it "should evaluate the amount when a counter is created" $ do
    stats <- newUsageStats
    addUsage (ClientUsage stats addr1) TCSend undefined `shouldThrow` anyErrorCall

closeUsagePeriodTests :: Spec
closeUsagePeriodTests = do
  it "should add closed counts to histograms" $ do
    stats@UsageStats {histograms} <- newUsageStats
    let usage = ClientUsage stats
    incUsage (usage addr1) TCConnections
    incUsage (usage addr2) TCConnections
    addUsage (usage addr1) TCSend 3
    addUsage (usage addr2) TCSend 7
    closeUsagePeriod stats
    readIORef histograms
      `shouldReturn` M.fromList
        [ (TCConnections, UsageHistogram (IM.fromList [(0, 2)]) 2 1),
          (TCSend, UsageHistogram (IM.fromList [(2, 1), (3, 1)]) 10 7),
          (TCGet, UsageHistogram IM.empty 0 0)
        ]
    addUsage (usage addr1) TCSend 20
    closeUsagePeriod stats
    readIORef histograms
      `shouldReturn` M.fromList
        [ (TCConnections, UsageHistogram (IM.fromList [(0, 2)]) 2 0),
          (TCSend, UsageHistogram (IM.fromList [(2, 1), (3, 1), (4, 1)]) 30 20),
          (TCGet, UsageHistogram IM.empty 0 0)
        ]
  it "should set previous counts to closed counts" $ do
    stats <- newUsageStats
    let usage = ClientUsage stats addr1
    addUsage usage TCSend 3
    incUsage usage TCGet
    counts stats addr1 TCSend `shouldReturn` Just (0, 3)
    closeUsagePeriod stats
    counts stats addr1 TCSend `shouldReturn` Just (3, 0)
    counts stats addr1 TCGet `shouldReturn` Just (1, 0)
    addUsage usage TCSend 5
    closeUsagePeriod stats
    counts stats addr1 TCSend `shouldReturn` Just (5, 0)
    counts stats addr1 TCGet `shouldReturn` Just (0, 0)
  it "should delete clients without counts in the closed period" $ do
    stats@UsageStats {clientCounts} <- newUsageStats
    let usage = ClientUsage stats
    incUsage (usage addr1) TCSend
    incUsage (usage addr2) TCGet
    closeUsagePeriod stats
    M.keys <$> readTVarIO clientCounts `shouldReturn` [addr1, addr2]
    incUsage (usage addr1) TCSend
    closeUsagePeriod stats
    M.keys <$> readTVarIO clientCounts `shouldReturn` [addr1]
    closeUsagePeriod stats
    M.keys <$> readTVarIO clientCounts `shouldReturn` []
  it "should close a period with counts of 40000 clients within 5 seconds" $ do
    stats@UsageStats {histograms} <- newUsageStats
    forM_ [1 .. 40000] $ \a -> incUsage (ClientUsage stats $ ClientIPv4 $ toEnum a) TCSend
    timeout 5000000 (closeUsagePeriod stats) `shouldReturn` Just ()
    M.lookup TCSend <$> readIORef histograms `shouldReturn` Just (UsageHistogram (IM.fromList [(0, 40000)]) 40000 1)

topClientsTests :: Spec
topClientsTests =
  it "should return clients with non-zero counts, sorted by the sum of previous and current counts" $ do
    stats <- newUsageStats
    let usage = ClientUsage stats
    addUsage (usage addr1) TCSend 3
    addUsage (usage addr2) TCSend 7
    incUsage (usage addr4) TCGet
    closeUsagePeriod stats
    addUsage (usage addr1) TCSend 5
    addUsage (usage addr3) TCSend 10
    topClients stats TCSend 10 `shouldReturn` [(addr3, 0, 10), (addr1, 3, 5), (addr2, 7, 0)]
    topClients stats TCSend 2 `shouldReturn` [(addr3, 0, 10), (addr1, 3, 5)]

metricsTests :: Spec
metricsTests =
  it "should encode histograms and maximums as Prometheus metrics" $
    usageMetrics "simplex_test" "1767225600000" usageHistograms
      `shouldBe` T.unlines
        [ "# Client usage",
          "# ------------",
          "",
          "# HELP simplex_test_client_usage Clients by usage in a period",
          "# TYPE simplex_test_client_usage histogram",
          "simplex_test_client_usage_bucket{counter=\"SEND\",le=\"1\"} 0 1767225600000",
          "simplex_test_client_usage_bucket{counter=\"SEND\",le=\"2\"} 0 1767225600000",
          "simplex_test_client_usage_bucket{counter=\"SEND\",le=\"5\"} 1 1767225600000",
          "simplex_test_client_usage_bucket{counter=\"SEND\",le=\"10\"} 2 1767225600000",
          "simplex_test_client_usage_bucket{counter=\"SEND\",le=\"+Inf\"} 2 1767225600000",
          "simplex_test_client_usage_sum{counter=\"SEND\"} 10 1767225600000",
          "simplex_test_client_usage_count{counter=\"SEND\"} 2 1767225600000",
          "simplex_test_client_usage_bucket{counter=\"GET\",le=\"1\"} 0 1767225600000",
          "simplex_test_client_usage_bucket{counter=\"GET\",le=\"2\"} 0 1767225600000",
          "simplex_test_client_usage_bucket{counter=\"GET\",le=\"5\"} 0 1767225600000",
          "simplex_test_client_usage_bucket{counter=\"GET\",le=\"10\"} 0 1767225600000",
          "simplex_test_client_usage_bucket{counter=\"GET\",le=\"+Inf\"} 1 1767225600000",
          "simplex_test_client_usage_sum{counter=\"GET\"} 12 1767225600000",
          "simplex_test_client_usage_count{counter=\"GET\"} 1 1767225600000",
          "",
          "# HELP simplex_test_client_usage_max Largest usage of one client in the last period",
          "# TYPE simplex_test_client_usage_max gauge",
          "simplex_test_client_usage_max{counter=\"SEND\"} 7 1767225600000",
          "simplex_test_client_usage_max{counter=\"GET\"} 12 1767225600000",
          ""
        ]
  where
    usageHistograms =
      M.fromList
        [ (TCSend, UsageHistogram (IM.fromList [(2, 1), (3, 1)]) 10 7),
          (TCGet, UsageHistogram (IM.fromList [(4, 1)]) 12 12)
        ]

commandCounterTests :: Spec
commandCounterTests = do
  it "should count each SMP command in the counter named by its tag or in other" $ do
    cmds <- smpCommands
    map (counterName . smpCmdCounter) cmds `shouldBe` map (commandCounter ["NEW", "SUB", "SEND", "PFWD", "RFWD", "RSLV"] . encodeProtocol (maxVersion supportedServerSMPRelayVRange)) cmds
    S.fromList (map smpCmdCounter cmds) `shouldBe` S.fromList [SUCNew .. SUCOther]
  it "should count each XFTP command in the counter named by its tag or in other" $ do
    cmds <- xftpCommands
    map (counterName . xftpCmdCounter) cmds `shouldBe` map (commandCounter ["FNEW"] . encodeProtocol (maxVersion supportedFileServerVRange)) cmds
    S.fromList (map xftpCmdCounter cmds) `shouldBe` S.fromList [XUCFNew .. XUCOther]
#if defined(dbServerPostgres)
  it "should count each NTF command in the counter named by its tag or in other" $ do
    cmds <- ntfCommands
    map (counterName . ntfCmdCounter) cmds `shouldBe` map (commandCounter ["TNEW", "TRPL", "SNEW"] . encodeProtocol (maxVersion supportedServerNTFVRange)) cmds
    S.fromList (map ntfCmdCounter cmds) `shouldBe` S.fromList [NUCTNew .. NUCOther]
#endif
  where
    commandCounter :: [Text] -> ByteString -> Text
    commandCounter tags s
      | tag `elem` tags = tag
      | otherwise = "other"
      where
        tag = decodeLatin1 $ B.takeWhile (/= ' ') s

counts :: UsageStats TestCounter -> ClientAddr -> TestCounter -> IO (Maybe (Int, Int))
counts UsageStats {clientCounts} addr c =
  readTVarIO clientCounts >>= mapM (\ClientCounts {previous, current} -> (,) <$> previousCount previous <*> currentCount current) . M.lookup addr
  where
    previousCount = fmap (M.findWithDefault 0 c) . readTVarIO
    currentCount = maybe (pure 0) readTVarIO <=< TM.lookupIO c

testKeys :: IO (C.APublicAuthKey, C.APrivateAuthKey, C.PublicKeyX25519)
testKeys = do
  g <- C.newRandom
  (authKey, authPrivKey) <- atomically $ C.generateAuthKeyPair C.SEd25519 g
  (dhKey, _ :: C.PrivateKeyX25519) <- atomically $ C.generateKeyPair g
  pure (authKey, authPrivKey, dhKey)

testSMPServer :: SMPServer
testSMPServer = SMPServer "localhost" "5001" (C.KeyHash "hash")

smpCommands :: IO [Cmd]
smpCommands = do
  (authKey, _, dhKey) <- testKeys
  let newQueue = NewQueueReq {rcvAuthKey = authKey, rcvDhKey = dhKey, auth_ = Nothing, subMode = SMSubscribe, queueReqData = Nothing, ntfCreds = Nothing}
      linkData = (EncDataBytes "fixed", EncDataBytes "user")
      name = NQDomain SimplexDomain {nameTLD = TLDSimplex, domain = "alice", subDomain = []}
  pure
    [ Cmd SCreator $ NEW newQueue,
      Cmd SRecipient SUB,
      Cmd SRecipientService $ SUBS 1 mempty,
      Cmd SRecipient $ KEY authKey,
      Cmd SRecipient $ RKEY (authKey :| []),
      Cmd SRecipient $ LSET (EntityId "link") linkData,
      Cmd SRecipient LDEL,
      Cmd SRecipient $ NKEY authKey dhKey,
      Cmd SRecipient NDEL,
      Cmd SRecipient GET,
      Cmd SRecipient $ ACK "message",
      Cmd SRecipient OFF,
      Cmd SRecipient DEL,
      Cmd SRecipient QUE,
      Cmd SSender $ SKEY authKey,
      Cmd SSender $ SEND noMsgFlags "hello",
      Cmd SIdleClient PING,
      Cmd SSenderLink $ LKEY authKey,
      Cmd SSenderLink LGET,
      Cmd SNotifier NSUB,
      Cmd SNotifierService $ NSUBS 1 mempty,
      Cmd SProxiedClient $ PRXY testSMPServer Nothing,
      Cmd SProxiedClient $ PFWD (maxVersion supportedClientSMPRelayVRange) dhKey (EncTransmission "transmission"),
      Cmd SProxyService $ RFWD (EncFwdTransmission "transmission"),
      Cmd SResolver $ RSLV name
    ]

xftpCommands :: IO [XFTP.FileCmd]
xftpCommands = do
  (authKey, _, dhKey) <- testKeys
  pure
    [ XFTP.FileCmd XFTP.SFSender $ XFTP.FNEW (XFTP.FileInfo authKey 65536 "digest") (authKey :| []) Nothing Nothing,
      XFTP.FileCmd XFTP.SFSender $ XFTP.FADD (authKey :| []),
      XFTP.FileCmd XFTP.SFSender XFTP.FPUT,
      XFTP.FileCmd XFTP.SFSender XFTP.FDEL,
      XFTP.FileCmd XFTP.SFRecipient $ XFTP.FGET dhKey,
      XFTP.FileCmd XFTP.SFRecipient XFTP.FACK,
      XFTP.FileCmd XFTP.SFRecipient XFTP.PING
    ]

#if defined(dbServerPostgres)
ntfCommands :: IO [NTF.NtfCmd]
ntfCommands = do
  (authKey, authPrivKey, dhKey) <- testKeys
  let token = NTF.DeviceToken NTF.PPApnsTest "token"
      queue = NTF.SMPQueueNtf testSMPServer (EntityId "notifier")
  pure
    [ NTF.NtfCmd NTF.SToken $ NTF.TNEW $ NTF.NewNtfTkn token authKey dhKey,
      NTF.NtfCmd NTF.SToken $ NTF.TVFY $ NTF.NtfRegCode "code",
      NTF.NtfCmd NTF.SToken NTF.TCHK,
      NTF.NtfCmd NTF.SToken $ NTF.TRPL token,
      NTF.NtfCmd NTF.SToken NTF.TDEL,
      NTF.NtfCmd NTF.SToken $ NTF.TCRN 20,
      NTF.NtfCmd NTF.SSubscription $ NTF.SNEW $ NTF.NewNtfSub (EntityId "token") queue authPrivKey,
      NTF.NtfCmd NTF.SSubscription NTF.SCHK,
      NTF.NtfCmd NTF.SSubscription NTF.SDEL,
      NTF.NtfCmd NTF.SSubscription NTF.PING
    ]
#endif
