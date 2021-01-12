{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedStrings #-}

module SMPAgentClient where

import Control.Monad
import Control.Monad.IO.Unlift
import Crypto.Random
import Network.Socket
import SMPClient (testPort, withSmpServer)
import Simplex.Messaging.Agent
import Simplex.Messaging.Agent.Env.SQLite
import Simplex.Messaging.Agent.Transmission
import Simplex.Messaging.Transport
import UnliftIO.Concurrent
import UnliftIO.Directory
import qualified UnliftIO.Exception as E
import UnliftIO.IO

agentTestHost :: HostName
agentTestHost = "localhost"

agentTestPort :: ServiceName
agentTestPort = "5001"

testDB :: String
testDB = "smp-agent.test.protocol.db"

smpAgentTest :: ARawTransmission -> IO ARawTransmission
smpAgentTest cmd = runSmpAgentTest $ \h -> tPutRaw h cmd >> tGetRaw h

runSmpAgentTest :: (MonadUnliftIO m, MonadRandom m) => (Handle -> m a) -> m a
runSmpAgentTest test = withSmpServer . withSmpAgent $ testSMPAgentClient test

cfg :: AgentConfig
cfg =
  AgentConfig
    { tcpPort = agentTestPort,
      tbqSize = 1,
      connIdBytes = 12,
      dbFile = testDB,
      smpTcpPort = testPort
    }

withSmpAgent :: (MonadUnliftIO m, MonadRandom m) => m a -> m a
withSmpAgent =
  E.bracket
    (forkIO $ runSMPAgent cfg)
    (liftIO . killThread >=> const (removeFile testDB))
    . const

testSMPAgentClient :: MonadUnliftIO m => (Handle -> m a) -> m a
testSMPAgentClient client = do
  threadDelay 25000 -- TODO hack: thread delay for SMP agent to start
  runTCPClient agentTestHost agentTestPort $ \h -> do
    line <- getLn h
    if line == "Welcome to SMP v0.2.0 agent"
      then client h
      else error "not connected"
