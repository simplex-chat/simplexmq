{-# LANGUAGE CPP #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module CoreTests.AddressStatsTests where

import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.IORef (readIORef)
import Data.List.NonEmpty (NonEmpty (..))
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Encoding (decodeLatin1)
import Network.Socket (SockAddr (..), tupleToHostAddress, tupleToHostAddress6)
import qualified Simplex.FileTransfer.Protocol as XFTP
import Simplex.FileTransfer.Server.Env (XFTPAddrCounter (..), xftpCmdCounter)
import Simplex.FileTransfer.Transport (supportedFileServerVRange)
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Protocol
import Simplex.Messaging.Server.AddressStats
import Simplex.Messaging.Server.Env.STM (SMPAddrCounter (..), smpCmdCounter)
import Simplex.Messaging.SimplexName (SimplexDomain (..), SimplexTLD (..))
import Simplex.Messaging.Transport (supportedClientSMPRelayVRange, supportedServerSMPRelayVRange)
import Simplex.Messaging.Version (VersionRange (..))
import Test.Hspec hiding (fit, it)
import UnliftIO.STM
import Util
#if defined(dbServerPostgres)
import qualified Simplex.Messaging.Notifications.Protocol as NTF
import Simplex.Messaging.Notifications.Server.Env (NtfAddrCounter (..), ntfCmdCounter)
import Simplex.Messaging.Notifications.Transport (supportedServerNTFVRange)
#endif

data TestCounter = TCConnections | TCSend | TCGet
  deriving (Eq, Ord, Enum, Bounded, Show)

instance AddrCounter TestCounter where
  counterName = \case
    TCConnections -> "connections"
    TCSend -> "SEND"
    TCGet -> "GET"
  counterBounds _ = [1, 2, 5, 10]
  connectionsCounter = TCConnections

addr1, addr2, addr3, addr4 :: AddrKey
addr1 = AKIPv4 1
addr2 = AKIPv4 2
addr3 = AKIPv4 3
addr4 = AKIPv4 4

addressStatsTests :: Spec
addressStatsTests = do
  describe "addrKey" addrKeyTests
  describe "bounds" boundsTests
  describe "counterByName" counterByNameTests
  describe "openAddrStats" openAddrStatsTests
  describe "rolloverAddrStats" rolloverTests
  describe "topAddresses" topAddressesTests
  describe "addrHistogramMetrics" metricsTests
  describe "command counters" commandCounterTests

addrKeyTests :: Spec
addrKeyTests = do
  it "should use IPv4 address" $
    addrKeyText <$> addrKey (ipv4 (192, 168, 1, 2)) `shouldBe` Just "192.168.1.2"
  it "should use IPv4 address of IPv4-mapped IPv6 address" $
    addrKey (ipv6 (0, 0, 0, 0, 0, 0xffff, 0xc0a8, 0x0102)) `shouldBe` addrKey (ipv4 (192, 168, 1, 2))
  it "should use one key for IPv6 addresses in one /64" $ do
    addrKey (ipv6 (0x2001, 0xdb8, 1, 2, 3, 4, 5, 6)) `shouldBe` addrKey (ipv6 (0x2001, 0xdb8, 1, 2, 7, 8, 9, 10))
    addrKeyText <$> addrKey (ipv6 (0x2001, 0xdb8, 1, 2, 3, 4, 5, 6)) `shouldBe` Just "2001:db8:1:2::/64"
  it "should use different keys for IPv6 addresses in different /64" $
    addrKey (ipv6 (0x2001, 0xdb8, 1, 2, 3, 4, 5, 6)) `shouldNotBe` addrKey (ipv6 (0x2001, 0xdb8, 1, 3, 3, 4, 5, 6))
  it "should not use other address types" $
    addrKey (SockAddrUnix "tests/tmp/socket") `shouldBe` Nothing
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
  it "should find SMP counters" $ testCounterNames [minBound .. maxBound :: SMPAddrCounter]
  it "should find XFTP counters" $ testCounterNames [minBound .. maxBound :: XFTPAddrCounter]
#if defined(dbServerPostgres)
  it "should find NTF counters" $ testCounterNames [minBound .. maxBound :: NtfAddrCounter]
#endif
  it "should not find unknown counter" $
    counterByName "unknown" `shouldBe` (Nothing :: Maybe SMPAddrCounter)
  where
    testCounterNames :: (AddrCounter c, Show c) => [c] -> Expectation
    testCounterNames cs = map (counterByName . counterName) cs `shouldBe` map Just cs

openAddrStatsTests :: Spec
openAddrStatsTests =
  it "should count connections of one address in one entry" $ do
    ServerAddrStats {addrStatsMap = m} <- newServerAddrStats
    s <- openAddrStats m addr1
    s' <- openAddrStats m addr1
    readTVarIO (connectionsCount s) `shouldReturn` 2
    counts s TCConnections `shouldReturn` (0, 2)
    closeAddrStats s'
    readTVarIO (connectionsCount s) `shouldReturn` 1

rolloverTests :: Spec
rolloverTests = do
  it "should add non-zero closing counts to histograms" $ do
    stats@ServerAddrStats {addrStatsMap = m, addrHistograms} <- newServerAddrStats
    s1 <- openAddrStats m addr1
    s2 <- openAddrStats m addr2
    addAddrCounter s1 TCSend 3
    addAddrCounter s2 TCSend 7
    rolloverAddrStats stats
    readIORef addrHistograms
      `shouldReturn` M.fromList
        [ (TCConnections, AddrHistogram [2, 2, 2, 2] 2 2 1),
          (TCSend, AddrHistogram [0, 0, 1, 2] 10 2 7),
          (TCGet, AddrHistogram [0, 0, 0, 0] 0 0 0)
        ]
    addAddrCounter s1 TCSend 20
    rolloverAddrStats stats
    readIORef addrHistograms
      `shouldReturn` M.fromList
        [ (TCConnections, AddrHistogram [2, 2, 2, 2] 2 2 0),
          (TCSend, AddrHistogram [0, 0, 1, 2] 30 3 20),
          (TCGet, AddrHistogram [0, 0, 0, 0] 0 0 0)
        ]
  it "should set previous counts to closing counts" $ do
    stats@ServerAddrStats {addrStatsMap = m} <- newServerAddrStats
    s <- openAddrStats m addr1
    addAddrCounter s TCSend 3
    counts s TCSend `shouldReturn` (0, 3)
    rolloverAddrStats stats
    counts s TCSend `shouldReturn` (3, 0)
    addAddrCounter s TCSend 5
    rolloverAddrStats stats
    counts s TCSend `shouldReturn` (5, 0)
    rolloverAddrStats stats
    counts s TCSend `shouldReturn` (0, 0)
  it "should keep entries with open connections or closing counts, and delete other entries" $ do
    stats@ServerAddrStats {addrStatsMap = m} <- newServerAddrStats
    _ <- openAddrStats m addr1
    s2 <- openAddrStats m addr2
    s3 <- openAddrStats m addr3
    closeAddrStats s3
    rolloverAddrStats stats
    M.keys <$> readTVarIO m `shouldReturn` [addr1, addr2, addr3]
    addAddrCounter s2 TCSend 1
    closeAddrStats s2
    rolloverAddrStats stats
    M.keys <$> readTVarIO m `shouldReturn` [addr1, addr2]
    rolloverAddrStats stats
    M.keys <$> readTVarIO m `shouldReturn` [addr1]

topAddressesTests :: Spec
topAddressesTests =
  it "should return addresses with non-zero counts, sorted by the sum of previous and current counts" $ do
    stats@ServerAddrStats {addrStatsMap = m} <- newServerAddrStats
    [s1, s2, s3, _] <- mapM (openAddrStats m) [addr1, addr2, addr3, addr4]
    addAddrCounter s1 TCSend 3
    addAddrCounter s2 TCSend 7
    rolloverAddrStats stats
    addAddrCounter s1 TCSend 5
    addAddrCounter s3 TCSend 10
    topAddresses m TCSend 10 `shouldReturn` [(addr3, 0, 10), (addr1, 3, 5), (addr2, 7, 0)]
    topAddresses m TCSend 2 `shouldReturn` [(addr3, 0, 10), (addr1, 3, 5)]

metricsTests :: Spec
metricsTests =
  it "should encode histograms and maximums as Prometheus metrics" $
    addrHistogramMetrics "simplex_test" "1767225600000" histograms
      `shouldBe` T.unlines
        [ "# Client addresses",
          "# ----------------",
          "",
          "# HELP simplex_test_client_address_period_count Counts of client addresses per period",
          "# TYPE simplex_test_client_address_period_count histogram",
          "simplex_test_client_address_period_count_bucket{counter=\"SEND\",le=\"1\"} 0 1767225600000",
          "simplex_test_client_address_period_count_bucket{counter=\"SEND\",le=\"2\"} 0 1767225600000",
          "simplex_test_client_address_period_count_bucket{counter=\"SEND\",le=\"5\"} 1 1767225600000",
          "simplex_test_client_address_period_count_bucket{counter=\"SEND\",le=\"10\"} 2 1767225600000",
          "simplex_test_client_address_period_count_bucket{counter=\"SEND\",le=\"+Inf\"} 2 1767225600000",
          "simplex_test_client_address_period_count_sum{counter=\"SEND\"} 10 1767225600000",
          "simplex_test_client_address_period_count_count{counter=\"SEND\"} 2 1767225600000",
          "simplex_test_client_address_period_count_bucket{counter=\"GET\",le=\"1\"} 0 1767225600000",
          "simplex_test_client_address_period_count_bucket{counter=\"GET\",le=\"2\"} 0 1767225600000",
          "simplex_test_client_address_period_count_bucket{counter=\"GET\",le=\"5\"} 0 1767225600000",
          "simplex_test_client_address_period_count_bucket{counter=\"GET\",le=\"10\"} 0 1767225600000",
          "simplex_test_client_address_period_count_bucket{counter=\"GET\",le=\"+Inf\"} 1 1767225600000",
          "simplex_test_client_address_period_count_sum{counter=\"GET\"} 12 1767225600000",
          "simplex_test_client_address_period_count_count{counter=\"GET\"} 1 1767225600000",
          "",
          "# HELP simplex_test_client_address_period_max Maximum count of a client address in the last period",
          "# TYPE simplex_test_client_address_period_max gauge",
          "simplex_test_client_address_period_max{counter=\"SEND\"} 7 1767225600000",
          "simplex_test_client_address_period_max{counter=\"GET\"} 12 1767225600000",
          ""
        ]
  where
    histograms =
      M.fromList
        [ (TCSend, AddrHistogram [0, 0, 1, 2] 10 2 7),
          (TCGet, AddrHistogram [0, 0, 0, 0] 12 1 12)
        ]

commandCounterTests :: Spec
commandCounterTests = do
  it "should count each SMP command in the counter named by its tag" $ do
    cmds <- smpCommands
    map (counterName . smpCmdCounter) cmds `shouldBe` map (commandTag . encodeProtocol (maxVersion supportedServerSMPRelayVRange)) cmds
    S.fromList (map smpCmdCounter cmds) `shouldBe` S.fromList [SACNew .. SACRslv]
  it "should count each XFTP command in the counter named by its tag" $ do
    cmds <- xftpCommands
    map (counterName . xftpCmdCounter) cmds `shouldBe` map (commandTag . encodeProtocol (maxVersion supportedFileServerVRange)) cmds
    S.fromList (map xftpCmdCounter cmds) `shouldBe` S.fromList [XACFNew .. XACPing]
#if defined(dbServerPostgres)
  it "should count each NTF command in the counter named by its tag" $ do
    cmds <- ntfCommands
    map (counterName . ntfCmdCounter) cmds `shouldBe` map (commandTag . encodeProtocol (maxVersion supportedServerNTFVRange)) cmds
    S.fromList (map ntfCmdCounter cmds) `shouldBe` S.fromList [NACTNew .. NACPing]
#endif
  where
    commandTag :: ByteString -> Text
    commandTag = decodeLatin1 . B.takeWhile (/= ' ')

counts :: AddrStats TestCounter -> TestCounter -> IO (Int, Int)
counts AddrStats {previous, current} c = (,) <$> readIORef (previous M.! c) <*> readIORef (current M.! c)

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
