{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE RankNTypes #-}
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
import Numeric.Natural
import Transmission
import Transport
import UnliftIO.Async
import UnliftIO.IO
import UnliftIO.STM

runSMPServer :: MonadUnliftIO m => ServiceName -> Natural -> m ()
runSMPServer port queueSize = do
  env <- atomically $ newEnv port queueSize
  runReaderT (runTCPServer port runClient) env

runClient :: (MonadUnliftIO m, MonadReader Env m) => Handle -> m ()
runClient h = do
  putLn h "Welcome to SMP"
  q <- asks queueSize
  c <- atomically $ newClient q
  void $ race3_ (send h c) (client c) (receive h c)

race3_ :: MonadUnliftIO m => m a -> m a -> m a -> m ()
race3_ m1 m2 m3 = void $
  withAsync m1 $ \a1 ->
    withAsync m2 $ \a2 ->
      withAsync m3 $ \a3 ->
        waitAnyCancel [a1, a2, a3]

receive :: (MonadUnliftIO m, MonadReader Env m) => Handle -> Client -> m ()
receive h Client {rcvQ} = forever $ do
  (signature, (connId, cmdOrError)) <- tGet fromClient h
  -- TODO maybe send Either to queue?
  signed <- case cmdOrError of
    Left e -> return . (connId,) . Cmd SBroker $ ERR e
    Right cmd -> verifyTransmission signature connId cmd
  atomically $ writeTBQueue rcvQ signed

send :: MonadUnliftIO m => Handle -> Client -> m ()
send h Client {sndQ} = forever $ do
  signed <- atomically $ readTBQueue sndQ
  tPut h ("", signed)

verifyTransmission :: forall m. (MonadUnliftIO m, MonadReader Env m) => Signature -> ConnId -> Cmd -> m Signed
verifyTransmission signature connId cmd = do
  (connId,) <$> case cmd of
    Cmd SBroker _ -> return $ smpErr INTERNAL -- it can only be client command, because `fromClient` was used
    Cmd SRecipient (CONN _) -> return cmd
    Cmd SRecipient _ -> withConnection SRecipient $ verifySignature . recipientKey
    Cmd SSender (SEND _) -> withConnection SSender $ verifySend . senderKey
  where
    withConnection :: Sing (p :: Party) -> (Connection -> m Cmd) -> m Cmd
    withConnection party f = do
      store <- asks connStore
      conn <- getConn store party connId
      either (return . smpErr) f conn
    verifySend :: Maybe PublicKey -> m Cmd
    verifySend
      | null signature = return . maybe cmd (const authErr)
      | otherwise = maybe (return authErr) verifySignature
    -- TODO stub
    verifySignature :: PublicKey -> m Cmd
    verifySignature key = return $ if signature == key then cmd else authErr

    smpErr e = Cmd SBroker $ ERR e
    authErr = smpErr AUTH

client :: forall m. (MonadUnliftIO m, MonadReader Env m) => Client -> m ()
client Client {rcvQ, sndQ} =
  forever $
    atomically (readTBQueue rcvQ)
      >>= processCommand
      >>= atomically . writeTBQueue sndQ
  where
    processCommand :: Signed -> m Signed
    processCommand (connId, cmd) = do
      st <- asks connStore
      case cmd of
        Cmd SRecipient (CONN rKey) ->
          either (mkSigned "" . ERR) idsResponce
            <$> createConn st rKey
        Cmd SRecipient SUB -> do
          -- TODO message subscription
          return ok
        Cmd SRecipient (KEY sKey) -> okResponse <$> secureConn st connId sKey
        Cmd SRecipient HOLD -> okResponse <$> suspendConn st connId
        Cmd SRecipient DEL -> okResponse <$> deleteConn st connId
        Cmd SSender (SEND msgBody) -> do
          -- TODO message delivery
          mkSigned connId . either ERR (deliverTo msgBody)
            <$> getConn st SSender connId
        Cmd SBroker _ -> return (connId, cmd)
        Cmd _ _ -> return ok
      where
        ok :: Signed
        ok = (connId, Cmd SBroker OK)

        mkSigned :: ConnId -> Command 'Broker -> Signed
        mkSigned cId command = (cId, Cmd SBroker command)

        idsResponce :: Connection -> Signed
        idsResponce Connection {recipientId, senderId} =
          mkSigned recipientId $ IDS recipientId senderId

        okResponse :: Either ErrorType () -> Signed
        okResponse = mkSigned connId . either ERR (const OK)

        -- TODO stub
        deliverTo :: MsgBody -> Connection -> Command 'Broker
        deliverTo _msgBody conn = case status conn of
          ConnActive -> OK
          ConnSuspended -> ERR AUTH
