module Main where

import Network.Socket (ServiceName)
import Numeric.Natural
import Server (runSMPServer)

port :: ServiceName
port = "5223"

queuePerClient :: Natural
queuePerClient = 100

main :: IO ()
main = do
  putStrLn $ "Listening on port " ++ port
  runSMPServer port queuePerClient
