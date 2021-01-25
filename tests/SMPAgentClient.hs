{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module SMPAgentClient where

import Control.Monad
import Control.Monad.IO.Unlift
import Crypto.Random
import Network.Socket
import SMPClient (testPort, withSmpServer, withSmpServerThreadOn)
import Simplex.Messaging.Agent
import Simplex.Messaging.Agent.Env.SQLite
import Simplex.Messaging.Agent.Transmission
import Simplex.Messaging.Client (SMPClientConfig (..))
import Simplex.Messaging.Transport
import Test.Hspec
import UnliftIO.Concurrent
import UnliftIO.Directory
import qualified UnliftIO.Exception as E
import UnliftIO.IO

agentTestHost :: HostName
agentTestHost = "localhost"

agentTestPort :: ServiceName
agentTestPort = "5001"

agentTestPort2 :: ServiceName
agentTestPort2 = "5011"

agentTestPort3 :: ServiceName
agentTestPort3 = "5021"

testDB :: String
testDB = "smp-agent.test.protocol.db"

testDB2 :: String
testDB2 = "smp-agent2.test.protocol.db"

testDB3 :: String
testDB3 = "smp-agent3.test.protocol.db"

smpAgentTest :: ARawTransmission -> IO ARawTransmission
smpAgentTest cmd = runSmpAgentTest $ \h -> tPutRaw h cmd >> tGetRaw h

runSmpAgentTest :: (MonadUnliftIO m, MonadRandom m) => (Handle -> m a) -> m a
runSmpAgentTest test = withSmpServer . withSmpAgent $ testSMPAgentClient test

runSmpAgentServerTest :: (MonadUnliftIO m, MonadRandom m) => ((ThreadId, ThreadId) -> Handle -> m a) -> m a
runSmpAgentServerTest test =
  withSmpServerThreadOn testPort $
    \server -> withSmpAgentThreadOn (agentTestPort, testDB) $
      \agent -> testSMPAgentClient $ test (server, agent)

smpAgentServerTest :: ((ThreadId, ThreadId) -> Handle -> IO ()) -> Expectation
smpAgentServerTest test' = runSmpAgentServerTest test' `shouldReturn` ()

runSmpAgentTestN :: forall m a. (MonadUnliftIO m, MonadRandom m) => [(ServiceName, String)] -> ([Handle] -> m a) -> m a
runSmpAgentTestN agents test = withSmpServer $ run agents []
  where
    run :: [(ServiceName, String)] -> [Handle] -> m a
    run [] hs = test hs
    run (a@(p, _) : as) hs = withSmpAgentOn a $ testSMPAgentClientOn p $ \h -> run as (h : hs)

runSmpAgentTestN_1 :: forall m a. (MonadUnliftIO m, MonadRandom m) => Int -> ([Handle] -> m a) -> m a
runSmpAgentTestN_1 nClients test = withSmpServer . withSmpAgent $ run nClients []
  where
    run :: Int -> [Handle] -> m a
    run 0 hs = test hs
    run n hs = testSMPAgentClient $ \h -> run (n - 1) (h : hs)

smpAgentTestN :: [(ServiceName, String)] -> ([Handle] -> IO ()) -> Expectation
smpAgentTestN agents test' = runSmpAgentTestN agents test' `shouldReturn` ()

smpAgentTestN_1 :: Int -> ([Handle] -> IO ()) -> Expectation
smpAgentTestN_1 n test' = runSmpAgentTestN_1 n test' `shouldReturn` ()

smpAgentTest2 :: (Handle -> Handle -> IO ()) -> Expectation
smpAgentTest2 test' =
  smpAgentTestN [(agentTestPort, testDB), (agentTestPort2, testDB2)] _test
  where
    _test [h1, h2] = test' h1 h2
    _test _ = error "expected 2 handles"

smpAgentTest2_1 :: (Handle -> Handle -> IO ()) -> Expectation
smpAgentTest2_1 test' = smpAgentTestN_1 2 _test
  where
    _test [h1, h2] = test' h1 h2
    _test _ = error "expected 2 handles"

smpAgentTest3 :: (Handle -> Handle -> Handle -> IO ()) -> Expectation
smpAgentTest3 test' =
  smpAgentTestN
    [(agentTestPort, testDB), (agentTestPort2, testDB2), (agentTestPort3, testDB3)]
    _test
  where
    _test [h1, h2, h3] = test' h1 h2 h3
    _test _ = error "expected 3 handles"

smpAgentTest3_1 :: (Handle -> Handle -> Handle -> IO ()) -> Expectation
smpAgentTest3_1 test' = smpAgentTestN_1 3 _test
  where
    _test [h1, h2, h3] = test' h1 h2 h3
    _test _ = error "expected 3 handles"

cfg :: AgentConfig
cfg =
  AgentConfig
    { tcpPort = agentTestPort,
      tbqSize = 1,
      connIdBytes = 12,
      dbFile = testDB,
      smpCfg =
        SMPClientConfig
          { qSize = 1,
            defaultPort = testPort,
            tcpTimeout = 500_000
          }
    }

withSmpAgentThreadOn :: (MonadUnliftIO m, MonadRandom m) => (ServiceName, String) -> (ThreadId -> m a) -> m a
withSmpAgentThreadOn (port', db') =
  E.bracket
    (forkIOWithUnmask ($ runSMPAgent cfg {tcpPort = port', dbFile = db'}))
    (liftIO . killThread >=> const (removeFile db'))

withSmpAgentOn :: (MonadUnliftIO m, MonadRandom m) => (ServiceName, String) -> m a -> m a
withSmpAgentOn (port', db') = withSmpAgentThreadOn (port', db') . const

withSmpAgent :: (MonadUnliftIO m, MonadRandom m) => m a -> m a
withSmpAgent = withSmpAgentOn (agentTestPort, testDB)

testSMPAgentClientOn :: MonadUnliftIO m => ServiceName -> (Handle -> m a) -> m a
testSMPAgentClientOn port' client = do
  threadDelay 100_000 -- TODO hack: thread delay for SMP agent to start
  runTCPClient agentTestHost port' $ \h -> do
    line <- liftIO $ getLn h
    if line == "Welcome to SMP v0.2.0 agent"
      then client h
      else error "not connected"

testSMPAgentClient :: MonadUnliftIO m => (Handle -> m a) -> m a
testSMPAgentClient = testSMPAgentClientOn agentTestPort
