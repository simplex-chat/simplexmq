{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

module Main where

import Control.Logger.Simple
import qualified Data.List.NonEmpty as L
import Simplex.Messaging.Agent.Env.SQLite
import Simplex.Messaging.Agent.Server (runSMPAgent)
import Simplex.Messaging.Transport (TLS, Transport (..))

cfg :: AgentConfig
cfg = defaultAgentConfig

servers :: InitialAgentServers
servers =
  InitialAgentServers
    { smp = L.fromList ["smp://bU0K-bRg24xWW__lS0umO1Zdw_SXqpJNtm1_RrPLViE=@localhost:5223"],
      ntf = []
    }

logCfg :: LogConfig
logCfg = LogConfig {lc_file = Nothing, lc_stderr = True}

main :: IO ()
main = do
  putStrLn $ "SMP agent listening on port " ++ tcpPort (cfg :: AgentConfig)
  setLogLevel LogInfo -- LogError
  withGlobalLogging logCfg $ runSMPAgent (transport @TLS) cfg servers
