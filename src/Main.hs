{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Main where

-- import Polysemy
import ConnStore
import Control.Monad
import Control.Monad.IO.Unlift
import Control.Monad.Reader
import qualified Data.ByteString.Char8 as B
import EnvSTM
import Network.Socket
import Text.Read
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

receive :: MonadUnliftIO m => Client -> m ()
receive Client {handle, channel} = forever $ do
  signature <- getLn handle
  connId <- getLn handle
  command <- getLn handle
  cmdOrError <- parseReadVerifyTransmission handle signature connId command
  atomically $ writeTChan channel cmdOrError

parseReadVerifyTransmission :: MonadUnliftIO m => Handle -> String -> String -> String -> m SomeSigned
parseReadVerifyTransmission h signature connId command = do
  let cmd = parseCommand command
  cmd' <- case cmd of
    Cmd SBroker _ -> return cmd
    Cmd _ (CREATE _) ->
      return
        if signature == "" && connId == ""
          then cmd
          else smpError SYNTAX
    Cmd _ (SEND msgBody) ->
      if connId == ""
        then return $ smpError SYNTAX
        else case B.unpack msgBody of
          ':' : body -> return . smpSend $ B.pack body
          sizeStr -> case readMaybe sizeStr :: Maybe Int of
            Just size -> do
              body <- getBytes h size
              s <- getLn h
              return if s == "" then smpSend body else smpError SYNTAX
            Nothing -> return $ smpError SYNTAX
    Cmd _ _ ->
      return
        if signature == "" || connId == ""
          then smpError SYNTAX
          else cmd
  return (Just connId, cmd')

client :: MonadIO m => Client -> m ()
client Client {handle, channel} = loop
  where
    loop = forever $ do
      (_, cmdOrErr) <- atomically $ readTChan channel
      let response = case cmdOrErr of
            Cmd SRecipient _ -> "OK"
            Cmd SSender _ -> "OK"
            Cmd SBroker (ERROR t) -> "ERROR " ++ show t
            _ -> "ERROR INTERNAL"
      putLn handle response
      liftIO $ print cmdOrErr
