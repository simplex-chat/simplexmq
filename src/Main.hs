{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Main where

import Control.Monad
import Control.Monad.IO.Unlift
import Control.Monad.Reader
import EnvSTM
import Network.Socket
-- import Polysemy
import Store
import Transmission
import Transport
import UnliftIO.Async
import UnliftIO.Concurrent
import qualified UnliftIO.Exception as E
import UnliftIO.IO
import UnliftIO.STM

port :: ServiceName
port = "5223"

main :: IO ()
main = do
  env <- atomically $ newEnv port
  putStrLn $ "Listening on port " ++ port
  runReaderT (runTCPServer runClient) env

runTCPServer :: (MonadReader Env m, MonadUnliftIO m) => (Handle -> m ()) -> m ()
runTCPServer server =
  E.bracket startTCPServer (liftIO . close) $ \sock -> forever $ do
    h <- acceptTCPConn sock
    putLn h "Welcome"
    forkFinally (server h) (const $ hClose h)

runClient :: MonadUnliftIO m => Handle -> m ()
runClient h = do
  c <- atomically $ newClient h
  void $ race (client c) (receive c)

receive :: MonadIO m => Client -> m ()
receive Client {handle, channel} = forever $ do
  signature <- getLn handle
  connId <- getLn handle
  command <- getLn handle
  cmdOrError <- parseVerifyTransmission signature connId command
  atomically $ writeTChan channel cmdOrError

parseVerifyTransmission :: Monad m => String -> String -> String -> m SomeSigned
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
  "CREATE" : _ -> err SYNTAX
  "SUB" : _ -> err SYNTAX
  "SECURE" : _ -> err SYNTAX
  "DELMSG" : _ -> err SYNTAX
  "SUSPEND" : _ -> err SYNTAX
  "DELETE" : _ -> err SYNTAX
  "SEND" : _ -> err SYNTAX
  _ -> err CMD
  where
    rCmd = SomeCom SRecipient
    err t = SomeCom SBroker $ ERROR t

client :: MonadIO m => Client -> m ()
client Client {handle, channel} = loop
  where
    loop = forever $ do
      (_, cmdOrErr) <- atomically $ readTChan channel
      let response = case cmdOrErr of
            SomeCom SRecipient _ -> "OK"
            SomeCom SSender _ -> "OK"
            SomeCom SBroker (ERROR t) -> "ERROR " ++ show t
            _ -> "ERROR INTERNAL"
      putLn handle response
