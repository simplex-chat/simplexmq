{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

module Main where

import Control.Logger.Simple
import qualified Data.List.NonEmpty as L
import qualified Data.Map.Strict as M
import Simplex.Messaging.Agent.Env.SQLite
import Simplex.Messaging.Agent.Server (runSMPAgent)
import Simplex.Messaging.Client (defaultNetworkConfig)
import Simplex.Messaging.Transport (TLS, Transport (..))

cfg :: AgentConfig
cfg = defaultAgentConfig

servers :: InitialAgentServers
servers =
  InitialAgentServers
    { smp = M.fromList [(1, L.fromList ["smp://bU0K-bRg24xWW__lS0umO1Zdw_SXqpJNtm1_RrPLViE=@localhost:5223"])],
      ntf = [],
      xftp = M.fromList [],
      netCfg = defaultNetworkConfig
    }

logCfg :: LogConfig
logCfg = LogConfig {lc_file = Nothing, lc_stderr = True}

main :: IO ()
main = do
  putStrLn $ "SMP agent listening on port " ++ tcpPort (cfg :: AgentConfig)
  setLogLevel LogInfo -- LogError
  Right () <- withGlobalLogging logCfg $ runSMPAgent (transport @TLS) cfg servers
  pure ()
