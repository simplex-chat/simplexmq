{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}

module Server (runSMPServer) where

import ConnStore
import Control.Monad
import Control.Monad.IO.Unlift
import Control.Monad.Reader
import Data.Singletons
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
  cmd <-
    either
      (return . (connId,) . Cmd SBroker . ERROR)
      (verifyTransmission handle signature connId)
      cmdOrError
  atomically $ writeTChan channel cmd

verifyTransmission :: forall m. (MonadUnliftIO m, MonadReader Env m) => Handle -> Signature -> ConnId -> Cmd -> m Signed
verifyTransmission _h signature connId cmd = do
  (connId,) <$> case cmd of
    Cmd SBroker _ -> return $ smpErr INTERNAL
    Cmd SRecipient (CREATE _) -> return cmd
    Cmd SRecipient _ -> withConnection SRecipient $ verifySignature . recipientKey
    Cmd SSender (SEND _) -> withConnection SSender $ verifySend . senderKey
  where
    smpErr e = Cmd SBroker $ ERROR e
    authErr = smpErr AUTH
    withConnection :: Sing (p :: Party) -> (Connection -> m Cmd) -> m Cmd
    withConnection party f = do
      store <- asks connStore
      conn <- getConn store party connId
      either (return . smpErr) f conn
    verifySend :: Maybe PublicKey -> m Cmd
    verifySend =
      if null signature
        then return . maybe cmd (const authErr)
        else maybe (return authErr) verifySignature
    -- TODO stub
    verifySignature :: PublicKey -> m Cmd
    verifySignature key = return $ if signature == key then cmd else authErr

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
