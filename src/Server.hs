{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}

module Server (runSMPServer) where

import ConnStore
import Control.Monad
import Control.Monad.IO.Unlift
import Control.Monad.Reader
import Env.STM
import Network.Socket
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
  (signature, (connId, cmdOrError)) <- tGet fromClient handle
  -- TODO maybe send Either to queue?
  cmd <- either (return . (connId,) . Cmd SBroker . ERROR) (verifyTransmission handle signature connId) cmdOrError
  atomically $ writeTChan channel cmd

verifyTransmission :: forall m. (MonadUnliftIO m, MonadReader Env m) => Handle -> Signature -> ConnId -> Cmd -> m SomeSigned
verifyTransmission _h signature connId cmd = do
  cmd' <- case cmd of
    Cmd SBroker _ -> return . Cmd SBroker $ ERROR INTERNAL
    Cmd SRecipient (CREATE _) -> return cmd
    Cmd SSender (SEND _) -> return cmd -- TODO verify sender's signature for secured connections
    Cmd _ _ -> verifyConnSignature cmd
  return (connId, cmd')
  where
    verifyConnSignature :: Cmd -> m Cmd
    verifyConnSignature c@(Cmd party _) = do
      store <- asks connStore
      getConn store party connId >>= \case
        Right Connection {recipientKey, senderKey} -> do
          res <- case party of
            SRecipient -> verifySignature recipientKey
            SSender -> case senderKey of
              Just key -> verifySignature key
              Nothing -> return False
            SBroker -> return False
          if res then return c else return $ smpError AUTH
        Left err -> return $ smpError err
    verifySignature :: Encoded -> m Bool
    verifySignature key = return $ signature == key

client :: (MonadUnliftIO m, MonadReader Env m) => Client -> m ()
client Client {handle, channel} = loop
  where
    loop = forever $ do
      (connId, cmdOrErr) <- atomically $ readTChan channel
      response <- case cmdOrErr of
        Cmd SRecipient (CREATE recipientKey) -> do
          store <- asks connStore
          conn <- createConn store recipientKey
          return . Cmd SBroker $ case conn of
            Right Connection {recipientId, senderId} -> CONN recipientId senderId
            Left e -> ERROR e
        Cmd SBroker _ -> return cmdOrErr
        Cmd _ _ -> return $ Cmd SBroker OK
      putLn handle "" -- singnature
      putLn handle connId
      putLn handle $ serializeCommand response
