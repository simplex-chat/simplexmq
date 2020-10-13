{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Server (runSMPServer) where

import ConnStore
import Control.Monad
import Control.Monad.IO.Unlift
import Control.Monad.Reader
import qualified Data.ByteString.Char8 as B
import Env.STM
import Network.Socket
import Text.Read
import Transmission
import Transport
import UnliftIO.Async
import UnliftIO.Concurrent
import qualified UnliftIO.Exception as E
import UnliftIO.IO
import UnliftIO.STM

runSMPServer :: ServiceName -> IO ()
runSMPServer port = do
  env <- atomically $ newEnv port
  runReaderT (runTCPServer runClient) env

runTCPServer :: (MonadReader Env m, MonadUnliftIO m) => (Handle -> m ()) -> m ()
runTCPServer server =
  E.bracket startTCPServer (liftIO . close) $ \sock -> forever $ do
    h <- acceptTCPConn sock
    putLn h "Welcome to SMP"
    forkFinally (server h) (const $ hClose h)

runClient :: (MonadUnliftIO m, MonadReader Env m) => Handle -> m ()
runClient h = do
  c <- atomically $ newClient h
  void $ race (client c) (receive c)

receive :: (MonadUnliftIO m, MonadReader Env m) => Client -> m ()
receive Client {handle, channel} = forever $ do
  signature <- getLn handle
  connId <- getLn handle
  command <- getLn handle
  cmdOrError <- parseReadVerifyTransmission handle signature connId command
  atomically $ writeTChan channel cmdOrError

parseReadVerifyTransmission :: forall m. (MonadUnliftIO m, MonadReader Env m) => Handle -> String -> String -> String -> m SomeSigned
parseReadVerifyTransmission h signature connId command = do
  let cmd = parseCommand command
  cmd' <- case cmd of
    Cmd SBroker _ -> return cmd
    Cmd _ (CREATE _) -> signed False cmd errHasCredentials
    Cmd _ (SEND msgBody) -> getSendMsgBody msgBody
    Cmd _ _ -> verifyConnSignature cmd -- signed True cmd errNoCredentials
  return (connId, cmd')
  where
    signed :: Bool -> Cmd -> Int -> m Cmd
    signed isSigned cmd errCode =
      return
        if isSigned == (signature /= "") && isSigned == (connId /= "")
          then cmd
          else syntaxError errCode
    getSendMsgBody :: MsgBody -> m Cmd
    getSendMsgBody msgBody =
      if connId == ""
        then return $ syntaxError errNoConnectionId
        else case B.unpack msgBody of
          ':' : body -> return . smpSend $ B.pack body
          sizeStr -> case readMaybe sizeStr :: Maybe Int of
            Just size -> do
              body <- getBytes h size
              s <- getLn h
              return if s == "" then smpSend body else syntaxError errMessageBodySize
            Nothing -> return $ syntaxError errMessageBody
    verifyConnSignature :: Cmd -> m Cmd
    verifyConnSignature cmd@(Cmd party _) =
      if null signature || null connId
        then return $ syntaxError errNoCredentials
        else do
          store <- asks connStore
          getConn store party connId >>= \case
            Right Connection {recipientKey, senderKey} -> do
              res <- case party of
                SRecipient -> verifySignature recipientKey
                SSender -> case senderKey of
                  Just key -> verifySignature key
                  Nothing -> return False
                SBroker -> return False
              if res then return cmd else return $ smpError AUTH
            Left err -> return $ smpError err
    verifySignature :: Encoded -> m Bool
    verifySignature key = return $ signature == key

client :: (MonadUnliftIO m, MonadReader Env m) => Client -> m ()
client Client {handle, channel} = loop
  where
    loop = forever $ do
      (_, cmdOrErr) <- atomically $ readTChan channel
      response <- case cmdOrErr of
        Cmd SRecipient (CREATE recipientKey) -> do
          store <- asks connStore
          conn <- createConn store recipientKey
          case conn of
            Right Connection {recipientId, senderId} -> return $ "CONN " ++ recipientId ++ " " ++ senderId
            Left e -> return $ "ERROR " ++ show e
        Cmd SRecipient _ -> return "OK"
        Cmd SSender _ -> return "OK"
        Cmd SBroker (ERROR e) -> return $ "ERROR " ++ show e
        _ -> return "ERROR INTERNAL"
      putLn handle response
      liftIO $ print cmdOrErr
