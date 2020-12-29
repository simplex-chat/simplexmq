{-# LANGUAGE DuplicateRecordFields #-}

module Main where

import Simplex.Messaging.Agent (runSMPAgent)
import Simplex.Messaging.Agent.Env.SQLite
import Simplex.Messaging.Agent.ServerClient

cfg :: AgentConfig
cfg =
  AgentConfig
    { tcpPort = "5224",
      tbqSize = 16,
      connIdBytes = 12,
      dbFile = "smp-agent.db",
      smpConfig =
        ServerClientConfig
          { tcpPort = "5223",
            tbqSize = 16,
            corrIdBytes = 4
          }
    }

main :: IO ()
main = do
  putStrLn $ "SMP agent listening on port " ++ tcpPort (cfg :: AgentConfig)
  runSMPAgent cfg
