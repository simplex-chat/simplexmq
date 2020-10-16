{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}

module Server (runSMPServer) where

import ConnStore
import Control.Monad
import Control.Monad.IO.Unlift
import Control.Monad.Reader
import qualified Data.Map.Strict as M
import Data.Singletons
import Env.STM
import MsgStore
import MsgStore.STM (MsgQueue)
import Network.Socket
import Numeric.Natural
import Transmission
import Transport
import UnliftIO.Async
import UnliftIO.Concurrent
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
  s <- asks server
  raceAny_ [send h c, client c s, receive h c]

raceAny_ :: MonadUnliftIO m => [m a] -> m ()
raceAny_ = r []
  where
    r as (m : ms) = withAsync m $ \a -> r (a : as) ms
    r as [] = void $ waitAnyCancel as

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

client :: forall m. (MonadUnliftIO m, MonadReader Env m) => Client -> Server -> m ()
client clnt@Client {connections, rcvQ, sndQ} Server {subscribedQ} =
  forever $
    atomically (readTBQueue rcvQ)
      >>= processCommand
      >>= atomically . writeTBQueue sndQ
  where
    processCommand :: Signed -> m Signed
    processCommand (connId, cmd) = do
      st <- asks connStore
      case cmd of
        Cmd SBroker _ -> return (connId, cmd)
        Cmd SSender (SEND msgBody) -> do
          getConn st SSender connId
            >>= fmap (mkSigned connId) . either (return . ERR) (storeMessage msgBody)
        Cmd SRecipient command -> case command of
          CONN rKey -> idsResponce <$> createConn st rKey
          SUB -> subscribeConnection >> deliverMessage tryPeekMsg
          ACK -> deliverMessage tryDelPeekMsg
          KEY sKey -> okResponse <$> secureConn st connId sKey
          OFF -> okResponse <$> suspendConn st connId
          DEL -> okResponse <$> deleteConn st connId
      where
        ok :: Signed
        ok = (connId, Cmd SBroker OK)

        mkSigned :: ConnId -> Command 'Broker -> Signed
        mkSigned cId command = (cId, Cmd SBroker command)

        idsResponce :: Either ErrorType Connection -> Signed
        idsResponce = either (mkSigned "" . ERR) $
          \Connection {recipientId = rId, senderId = sId} ->
            mkSigned rId $ IDS rId sId

        okResponse :: Either ErrorType () -> Signed
        okResponse = mkSigned connId . either ERR (const OK)

        subscribeConnection :: m ()
        subscribeConnection = atomically $ do
          cs <- readTVar connections
          when (M.notMember connId cs) $ do
            writeTBQueue subscribedQ (connId, clnt)
            writeTVar connections $ M.insert connId (Left ()) cs

        storeMessage :: MsgBody -> Connection -> m (Command 'Broker)
        storeMessage msgBody c = case status c of
          ConnActive -> do
            ms <- asks msgStore
            q <- getMsgQueue ms (recipientId c)
            msg <- newMessage msgBody
            writeMsg q msg
            return OK
          ConnOff -> return $ ERR AUTH

        deliverMessage :: (MsgQueue -> m (Maybe Message)) -> m Signed
        deliverMessage tryPeek = do
          ms <- asks msgStore
          q <- getMsgQueue ms connId
          tryPeek q >>= \case
            Just Message {msgId, ts, msgBody} ->
              return . mkSigned connId $ MSG msgId ts msgBody
            Nothing -> do
              cs <- readTVarIO connections
              case M.lookup connId cs of
                Nothing -> return ok
                Just (Right _) -> return ok
                Just (Left ()) -> do
                  void . forkIO $ subscriber q
                  return ok

        subscriber :: MsgQueue -> m ()
        subscriber q = do
          Message {msgId, ts, msgBody} <- peekMsg q
          -- TODO refactor with deliver
          atomically $ writeTBQueue sndQ $ mkSigned connId $ MSG msgId ts msgBody
