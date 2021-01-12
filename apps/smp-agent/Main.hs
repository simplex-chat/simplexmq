{-# LANGUAGE DuplicateRecordFields #-}

module Main where

import Simplex.Messaging.Agent (runSMPAgent)
import Simplex.Messaging.Agent.Env.SQLite

cfg :: AgentConfig
cfg =
  AgentConfig
    { tcpPort = "5224",
      tbqSize = 16,
      connIdBytes = 12,
      dbFile = "smp-agent.db",
      smpTcpPort = "5223"
    }

main :: IO ()
main = do
  putStrLn $ "SMP agent listening on port " ++ tcpPort (cfg :: AgentConfig)
  runSMPAgent cfg
