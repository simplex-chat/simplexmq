module Main where

import Network.Socket (ServiceName)
import Server (runSMPServer)

port :: ServiceName
port = "5223"

main :: IO ()
main = do
  putStrLn $ "Listening on port " ++ port
  runSMPServer port
