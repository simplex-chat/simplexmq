{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

module Main where

import Control.Logger.Simple
import qualified Data.List.NonEmpty as L
import qualified Data.Map.Strict as M
import Simplex.Messaging.Agent.Env.SQLite
import Simplex.Messaging.Agent.Server (runSMPAgent)
import Simplex.Messaging.Agent.Store.SQLite (MigrationConfirmation (..))
import Simplex.Messaging.Client (defaultNetworkConfig)
import Simplex.Messaging.Crypto.Memory (LockedBytes)
import Simplex.Messaging.Transport (TLS, Transport (..))

cfg :: AgentConfig
cfg = defaultAgentConfig

agentDbFile :: String
agentDbFile = "smp-agent.db"

agentDbKey :: LockedBytes
agentDbKey = ""

servers :: InitialAgentServers
servers =
  InitialAgentServers
    { smp = M.fromList [(1, L.fromList ["smp://bU0K-bRg24xWW__lS0umO1Zdw_SXqpJNtm1_RrPLViE=@localhost:5223"])],
      ntf = [],
      xftp = M.empty,
      netCfg = defaultNetworkConfig
    }

logCfg :: LogConfig
logCfg = LogConfig {lc_file = Nothing, lc_stderr = True}

-- Warning: this SMP agent server is experimental - it does not work correctly with multiple connected TCP clients in some cases.
main :: IO ()
main = do
  putStrLn $ "SMP agent listening on port " ++ tcpPort (cfg :: AgentConfig)
  setLogLevel LogInfo -- LogError
  Right st <- createAgentStore agentDbFile agentDbKey False MCConsole
  withGlobalLogging logCfg $ runSMPAgent (transport @TLS) cfg servers st
