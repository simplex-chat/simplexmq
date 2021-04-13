module Main where

import Control.Concurrent.STM (newEmptyTMVarIO)
import Simplex.Messaging.Server (runSMPServer)
import Simplex.Messaging.Server.Env.STM

cfg :: ServerConfig
cfg =
  ServerConfig
    { tcpPort = "5223",
      tbqSize = 16,
      queueIdBytes = 12,
      msgIdBytes = 6
    }

main :: IO ()
main = do
  putStrLn $ "Listening on port " ++ tcpPort cfg
  started <- newEmptyTMVarIO
  runSMPServer started cfg
