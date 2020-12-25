module Main where

import Simplex.Messaging.Agent (runSMPAgent)
import Simplex.Messaging.Agent.Env

cfg :: AgentConfig
cfg =
  AgentConfig
    { tcpPort = "5224",
      tbqSize = 16,
      connIdBytes = 12
    }

main :: IO ()
main = do
  putStrLn $ "SMP agent listening on port " ++ tcpPort cfg
  runSMPAgent cfg
