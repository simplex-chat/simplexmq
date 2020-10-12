{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

module Main where

import Control.Concurrent
import Control.Concurrent.Async
import Control.Concurrent.STM
import qualified Control.Exception as E
import Control.Monad
import Data.Function ((&))
import Data.Map (Map)
import qualified Data.Map as M
import Data.Set (Set)
import qualified Data.Set as S
import EnvStm
import Network.Socket
import Polysemy
import Polysemy.Embed
import Polysemy.Resource
import Store
import System.IO
import Transmission
import Transport

newClient :: Handle -> IO Client
newClient h = do
  c <- newTChanIO @SomeSigned
  return Client {handle = h, connections = S.empty, channel = c}

main :: IO ()
main = do
  server <- atomically newServer
  putStrLn $ "Listening on port " ++ port'
  runTCPServer port' $ runClient server

port' :: String
port' = "5223"

runTCPServer :: ServiceName -> (Handle -> IO ()) -> IO ()
runTCPServer port server =
  E.bracket (startTCPServer port) close $ \sock -> forever $ do
    h <- acceptTCPConn sock
    hPutStrLn h "Welcome\r"
    forkFinally (server h) (const $ hClose h)

runClient :: TVar Server -> Handle -> IO ()
runClient server h = do
  c <- newClient h
  void $ race (client server c) (receive c)

receive :: Client -> IO ()
receive Client {handle, channel} = forever $ do
  signature <- hGetLine handle
  connId <- hGetLine handle
  command <- hGetLine handle
  cmdOrError <- parseVerifyTransmission signature connId command
  atomically $ writeTChan channel cmdOrError

parseVerifyTransmission :: String -> String -> String -> IO SomeSigned
parseVerifyTransmission _ connId command = do
  return (Just connId, parseCommand command)

parseCommand :: String -> SomeCom
parseCommand command = case words command of
  ["CREATE", recipientKey] -> rCmd $ CREATE recipientKey
  ["SUB"] -> rCmd SUB
  ["SECURE", senderKey] -> rCmd $ SECURE senderKey
  ["DELMSG", msgId] -> rCmd $ DELMSG msgId
  ["SUSPEND"] -> rCmd SUSPEND
  ["DELETE"] -> rCmd DELETE
  ["SEND", msgBody] -> SomeCom SSender $ SEND msgBody
  "CREATE" : _ -> error SYNTAX
  "SUB" : _ -> error SYNTAX
  "SECURE" : _ -> error SYNTAX
  "DELMSG" : _ -> error SYNTAX
  "SUSPEND" : _ -> error SYNTAX
  "DELETE" : _ -> error SYNTAX
  "SEND" : _ -> error SYNTAX
  _ -> error CMD
  where
    rCmd = SomeCom SRecipient
    error t = SomeCom SBroker $ ERROR t

client :: TVar Server -> Client -> IO ()
client server Client {handle, channel} = loop
  where
    loop = do
      (_, cmdOrErr) <- atomically $ readTChan channel
      let response = case cmdOrErr of
            SomeCom SRecipient _ -> "OK"
            SomeCom SSender _ -> "OK"
            SomeCom SBroker (ERROR t) -> "ERROR " ++ show t
            _ -> "ERROR INTERNAL"
      hPutStrLn handle response
      loop
