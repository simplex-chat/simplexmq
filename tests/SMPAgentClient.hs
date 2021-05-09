{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module SMPAgentClient where

import Control.Monad.IO.Unlift
import Crypto.Random
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
import Simplex.Messaging.Client (SMPClientConfig (..), smpDefaultConfig)
import Simplex.Messaging.Transport
import Test.Hspec
import UnliftIO.Concurrent
import UnliftIO.Directory
import UnliftIO.IO

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

smpAgentTest :: ARawTransmission -> IO ARawTransmission
smpAgentTest cmd = runSmpAgentTest $ \h -> tPutRaw h cmd >> tGetRaw h

runSmpAgentTest :: (MonadUnliftIO m, MonadRandom m) => (Handle -> m a) -> m a
runSmpAgentTest test = withSmpServer . withSmpAgent $ testSMPAgentClient test

runSmpAgentServerTest :: (MonadUnliftIO m, MonadRandom m) => ((ThreadId, ThreadId) -> Handle -> m a) -> m a
runSmpAgentServerTest test =
  withSmpServerThreadOn testPort $
    \server -> withSmpAgentThreadOn (agentTestPort, testPort, testDB) $
      \agent -> testSMPAgentClient $ test (server, agent)

smpAgentServerTest :: ((ThreadId, ThreadId) -> Handle -> IO ()) -> Expectation
smpAgentServerTest test' = runSmpAgentServerTest test' `shouldReturn` ()

runSmpAgentTestN :: forall m a. (MonadUnliftIO m, MonadRandom m) => [(ServiceName, ServiceName, String)] -> ([Handle] -> m a) -> m a
runSmpAgentTestN agents test = withSmpServer $ run agents []
  where
    run :: [(ServiceName, ServiceName, String)] -> [Handle] -> m a
    run [] hs = test hs
    run (a@(p, _, _) : as) hs = withSmpAgentOn a $ testSMPAgentClientOn p $ \h -> run as (h : hs)

runSmpAgentTestN_1 :: forall m a. (MonadUnliftIO m, MonadRandom m) => Int -> ([Handle] -> m a) -> m a
runSmpAgentTestN_1 nClients test = withSmpServer . withSmpAgent $ run nClients []
  where
    run :: Int -> [Handle] -> m a
    run 0 hs = test hs
    run n hs = testSMPAgentClient $ \h -> run (n - 1) (h : hs)

smpAgentTestN :: [(ServiceName, ServiceName, String)] -> ([Handle] -> IO ()) -> Expectation
smpAgentTestN agents test' = runSmpAgentTestN agents test' `shouldReturn` ()

smpAgentTestN_1 :: Int -> ([Handle] -> IO ()) -> Expectation
smpAgentTestN_1 n test' = runSmpAgentTestN_1 n test' `shouldReturn` ()

smpAgentTest2_2_2 :: (Handle -> Handle -> IO ()) -> Expectation
smpAgentTest2_2_2 test' =
  withSmpServerOn testPort2 $
    smpAgentTestN
      [ (agentTestPort, testPort, testDB),
        (agentTestPort2, testPort2, testDB2)
      ]
      _test
  where
    _test [h1, h2] = test' h1 h2
    _test _ = error "expected 2 handles"

smpAgentTest2_2_1 :: (Handle -> Handle -> IO ()) -> Expectation
smpAgentTest2_2_1 test' =
  smpAgentTestN
    [ (agentTestPort, testPort, testDB),
      (agentTestPort2, testPort, testDB2)
    ]
    _test
  where
    _test [h1, h2] = test' h1 h2
    _test _ = error "expected 2 handles"

smpAgentTest2_1_1 :: (Handle -> Handle -> IO ()) -> Expectation
smpAgentTest2_1_1 test' = smpAgentTestN_1 2 _test
  where
    _test [h1, h2] = test' h1 h2
    _test _ = error "expected 2 handles"

smpAgentTest3 :: (Handle -> Handle -> Handle -> IO ()) -> Expectation
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

smpAgentTest3_1_1 :: (Handle -> Handle -> Handle -> IO ()) -> Expectation
smpAgentTest3_1_1 test' = smpAgentTestN_1 3 _test
  where
    _test [h1, h2, h3] = test' h1 h2 h3
    _test _ = error "expected 3 handles"

cfg :: AgentConfig
cfg =
  AgentConfig
    { tcpPort = agentTestPort,
      smpServers = L.fromList ["localhost:5000#KXNE1m2E1m0lm92WGKet9CL6+lO742Vy5G6nsrkvgs8="],
      rsaKeySize = 2048 `div` 8,
      connIdBytes = 12,
      tbqSize = 1,
      dbFile = testDB,
      smpCfg =
        smpDefaultConfig
          { qSize = 1,
            defaultPort = testPort,
            tcpTimeout = 500_000
          }
    }

withSmpAgentThreadOn :: (MonadUnliftIO m, MonadRandom m) => (ServiceName, ServiceName, String) -> (ThreadId -> m a) -> m a
withSmpAgentThreadOn (port', smpPort', db') =
  let cfg' = cfg {tcpPort = port', dbFile = db', smpServers = L.fromList [SMPServer "localhost" (Just smpPort') testKeyHash]}
   in serverBracket
        (`runSMPAgentBlocking` cfg')
        (removeFile db')

withSmpAgentOn :: (MonadUnliftIO m, MonadRandom m) => (ServiceName, ServiceName, String) -> m a -> m a
withSmpAgentOn (port', smpPort', db') = withSmpAgentThreadOn (port', smpPort', db') . const

withSmpAgent :: (MonadUnliftIO m, MonadRandom m) => m a -> m a
withSmpAgent = withSmpAgentOn (agentTestPort, testPort, testDB)

testSMPAgentClientOn :: MonadUnliftIO m => ServiceName -> (Handle -> m a) -> m a
testSMPAgentClientOn port' client = do
  runTCPClient agentTestHost port' $ \h -> do
    line <- liftIO $ getLn h
    if line == "Welcome to SMP v0.3.0 agent"
      then client h
      else error "not connected"

testSMPAgentClient :: MonadUnliftIO m => (Handle -> m a) -> m a
testSMPAgentClient = testSMPAgentClientOn agentTestPort
