{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

module SMPAgentClient where

import Control.Monad.IO.Unlift
import Crypto.Random
import qualified Data.ByteString.Char8 as B
import qualified Data.List.NonEmpty as L
import Network.Socket (HostName, ServiceName)
import SMPClient
  ( serverBracket,
    testKeyHash,
    testPort,
    testPort2,
    withSmpServer,
    withSmpServerOn,
    withSmpServerThreadOn,
  )
import Simplex.Messaging.Agent (runSMPAgentBlocking)
import Simplex.Messaging.Agent.Env.SQLite
import Simplex.Messaging.Agent.Protocol
import Simplex.Messaging.Agent.RetryInterval
import Simplex.Messaging.Client (SMPClientConfig (..), smpDefaultConfig)
import Simplex.Messaging.Transport
import Test.Hspec
import UnliftIO.Concurrent
import UnliftIO.Directory

agentTestHost :: HostName
agentTestHost = "localhost"

agentTestPort :: ServiceName
agentTestPort = "5010"

agentTestPort2 :: ServiceName
agentTestPort2 = "5011"

agentTestPort3 :: ServiceName
agentTestPort3 = "5012"

testDB :: String
testDB = "tests/tmp/smp-agent.test.protocol.db"

testDB2 :: String
testDB2 = "tests/tmp/smp-agent2.test.protocol.db"

testDB3 :: String
testDB3 = "tests/tmp/smp-agent3.test.protocol.db"

smpAgentTest :: forall c. Transport c => TProxy c -> ARawTransmission -> IO ARawTransmission
smpAgentTest _ cmd = runSmpAgentTest $ \(h :: c) -> tPutRaw h cmd >> tGetRaw h

runSmpAgentTest :: forall c m a. (Transport c, MonadUnliftIO m, MonadRandom m) => (c -> m a) -> m a
runSmpAgentTest test = withSmpServer t . withSmpAgent t $ testSMPAgentClient test
  where
    t = transport @c

runSmpAgentServerTest :: forall c m a. (Transport c, MonadUnliftIO m, MonadRandom m) => ((ThreadId, ThreadId) -> c -> m a) -> m a
runSmpAgentServerTest test =
  withSmpServerThreadOn t testPort $
    \server -> withSmpAgentThreadOn t (agentTestPort, testPort, testDB) $
      \agent -> testSMPAgentClient $ test (server, agent)
  where
    t = transport @c

smpAgentServerTest :: Transport c => ((ThreadId, ThreadId) -> c -> IO ()) -> Expectation
smpAgentServerTest test' = runSmpAgentServerTest test' `shouldReturn` ()

runSmpAgentTestN :: forall c m a. (Transport c, MonadUnliftIO m, MonadRandom m) => [(ServiceName, ServiceName, String)] -> ([c] -> m a) -> m a
runSmpAgentTestN agents test = withSmpServer t $ run agents []
  where
    run :: [(ServiceName, ServiceName, String)] -> [c] -> m a
    run [] hs = test hs
    run (a@(p, _, _) : as) hs = withSmpAgentOn t a $ testSMPAgentClientOn p $ \h -> run as (h : hs)
    t = transport @c

runSmpAgentTestN_1 :: forall c m a. (Transport c, MonadUnliftIO m, MonadRandom m) => Int -> ([c] -> m a) -> m a
runSmpAgentTestN_1 nClients test = withSmpServer t . withSmpAgent t $ run nClients []
  where
    run :: Int -> [c] -> m a
    run 0 hs = test hs
    run n hs = testSMPAgentClient $ \h -> run (n - 1) (h : hs)
    t = transport @c

smpAgentTestN :: Transport c => [(ServiceName, ServiceName, String)] -> ([c] -> IO ()) -> Expectation
smpAgentTestN agents test' = runSmpAgentTestN agents test' `shouldReturn` ()

smpAgentTestN_1 :: Transport c => Int -> ([c] -> IO ()) -> Expectation
smpAgentTestN_1 n test' = runSmpAgentTestN_1 n test' `shouldReturn` ()

smpAgentTest2_2_2 :: forall c. Transport c => (c -> c -> IO ()) -> Expectation
smpAgentTest2_2_2 test' =
  withSmpServerOn (transport @c) testPort2 $
    smpAgentTest2_2_2_needs_server test'

smpAgentTest2_2_2_needs_server :: forall c. Transport c => (c -> c -> IO ()) -> Expectation
smpAgentTest2_2_2_needs_server test' =
  smpAgentTestN
    [ (agentTestPort, testPort, testDB),
      (agentTestPort2, testPort2, testDB2)
    ]
    _test
  where
    _test [h1, h2] = test' h1 h2
    _test _ = error "expected 2 handles"

smpAgentTest2_2_1 :: Transport c => (c -> c -> IO ()) -> Expectation
smpAgentTest2_2_1 test' =
  smpAgentTestN
    [ (agentTestPort, testPort, testDB),
      (agentTestPort2, testPort, testDB2)
    ]
    _test
  where
    _test [h1, h2] = test' h1 h2
    _test _ = error "expected 2 handles"

smpAgentTest2_1_1 :: Transport c => (c -> c -> IO ()) -> Expectation
smpAgentTest2_1_1 test' = smpAgentTestN_1 2 _test
  where
    _test [h1, h2] = test' h1 h2
    _test _ = error "expected 2 handles"

smpAgentTest3 :: Transport c => (c -> c -> c -> IO ()) -> Expectation
smpAgentTest3 test' =
  smpAgentTestN
    [ (agentTestPort, testPort, testDB),
      (agentTestPort2, testPort, testDB2),
      (agentTestPort3, testPort, testDB3)
    ]
    _test
  where
    _test [h1, h2, h3] = test' h1 h2 h3
    _test _ = error "expected 3 handles"

smpAgentTest3_1_1 :: Transport c => (c -> c -> c -> IO ()) -> Expectation
smpAgentTest3_1_1 test' = smpAgentTestN_1 3 _test
  where
    _test [h1, h2, h3] = test' h1 h2 h3
    _test _ = error "expected 3 handles"

smpAgentTest1_1_1 :: forall c. Transport c => (c -> IO ()) -> Expectation
smpAgentTest1_1_1 test' =
  smpAgentTestN
    [(agentTestPort2, testPort2, testDB2)]
    _test
  where
    _test [h] = test' h
    _test _ = error "expected 1 handle"

cfg :: AgentConfig
cfg =
  defaultAgentConfig
    { tcpPort = agentTestPort,
      smpServers = L.fromList ["smp://9VjLsOY5ZvB4hoglNdBzJFAUi_vP4GkZnJFahQOXV20=@localhost:5001"],
      tbqSize = 1,
      dbFile = testDB,
      smpCfg =
        smpDefaultConfig
          { qSize = 1,
            defaultTransport = (testPort, transport @TLS),
            tcpTimeout = 500_000
          },
      reconnectInterval = (reconnectInterval defaultAgentConfig) {initialInterval = 50_000},
      caCertificateFile = "tests/fixtures/ca.crt",
      privateKeyFile = "tests/fixtures/server.key",
      certificateFile = "tests/fixtures/server.crt"
    }

withSmpAgentThreadOn_ :: (MonadUnliftIO m, MonadRandom m) => ATransport -> (ServiceName, ServiceName, String) -> m () -> (ThreadId -> m a) -> m a
withSmpAgentThreadOn_ t (port', smpPort', db') afterProcess =
  let cfg' = cfg {tcpPort = port', dbFile = db', smpServers = L.fromList [SMPServer "localhost" smpPort' testKeyHash]}
   in serverBracket
        (\started -> runSMPAgentBlocking t started cfg')
        afterProcess

withSmpAgentThreadOn :: (MonadUnliftIO m, MonadRandom m) => ATransport -> (ServiceName, ServiceName, String) -> (ThreadId -> m a) -> m a
withSmpAgentThreadOn t a@(_, _, db') = withSmpAgentThreadOn_ t a $ removeFile db'

withSmpAgentOn :: (MonadUnliftIO m, MonadRandom m) => ATransport -> (ServiceName, ServiceName, String) -> m a -> m a
withSmpAgentOn t (port', smpPort', db') = withSmpAgentThreadOn t (port', smpPort', db') . const

withSmpAgent :: (MonadUnliftIO m, MonadRandom m) => ATransport -> m a -> m a
withSmpAgent t = withSmpAgentOn t (agentTestPort, testPort, testDB)

testSMPAgentClientOn :: (Transport c, MonadUnliftIO m) => ServiceName -> (c -> m a) -> m a
testSMPAgentClientOn port' client = do
  runTransportClient agentTestHost port' testKeyHash $ \h -> do
    line <- liftIO $ getLn h
    if line == "Welcome to SMP agent v" <> B.pack simplexMQVersion
      then client h
      else do
        error $ "wrong welcome message: " <> B.unpack line

testSMPAgentClient :: (Transport c, MonadUnliftIO m) => (c -> m a) -> m a
testSMPAgentClient = testSMPAgentClientOn agentTestPort
