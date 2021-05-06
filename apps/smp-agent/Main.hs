{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedStrings #-}

module Main where

import Control.Logger.Simple
import qualified Data.List.NonEmpty as L
import Simplex.Messaging.Agent (runSMPAgent)
import Simplex.Messaging.Agent.Env.SQLite
import Simplex.Messaging.Client (smpDefaultConfig)

cfg :: AgentConfig
cfg =
  AgentConfig
    { tcpPort = "5224",
      smpServers = L.fromList ["localhost:5223#KXNE1m2E1m0lm92WGKet9CL6+lO742Vy5G6nsrkvgs8="],
      rsaKeySize = 2048 `div` 8,
      connIdBytes = 12,
      tbqSize = 16,
      dbFile = "smp-agent.db",
      smpCfg = smpDefaultConfig
    }

logCfg :: LogConfig
logCfg = LogConfig {lc_file = Nothing, lc_stderr = True}

main :: IO ()
main = do
  putStrLn $ "SMP agent listening on port " ++ tcpPort (cfg :: AgentConfig)
  setLogLevel LogInfo -- LogError
  withGlobalLogging logCfg $ runSMPAgent cfg
