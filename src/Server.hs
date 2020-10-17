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
  runReaderT smpServer env
  where
    smpServer :: (MonadUnliftIO m, MonadReader Env m) => m ()
    smpServer = do
      s <- asks server
      race_ (runTCPServer port runClient) (serverThread s)

    serverThread :: MonadUnliftIO m => Server -> m ()
    serverThread Server {subscribedQ, connections} = forever . atomically $ do
      (rId, clnt) <- readTBQueue subscribedQ
      cs <- readTVar connections
      case M.lookup rId cs of
        Just Client {rcvQ} -> writeTBQueue rcvQ (rId, Cmd SBroker END)
        Nothing -> return ()
      writeTVar connections $ M.insert rId clnt cs

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
        Cmd SBroker END -> unsubscribeConn connId >> return (connId, cmd)
        Cmd SBroker _ -> return (connId, cmd)
        Cmd SSender (SEND msgBody) -> sendMessage st connId msgBody
        Cmd SRecipient command -> case command of
          CONN rKey -> createConn st rKey
          SUB -> subscribeConn connId
          ACK -> deliverMessage tryDelPeekMsg connId -- TODO? sending ACK without message loses the message
          KEY sKey -> okResponse <$> secureConn st connId sKey
          OFF -> okResponse <$> suspendConn st connId
          DEL -> okResponse <$> deleteConn st connId
      where
        ok :: Signed
        ok = (connId, Cmd SBroker OK)

        okResponse :: Either ErrorType () -> Signed
        okResponse = mkSigned connId . either ERR (const OK)

        createConn :: MonadConnStore s m => s -> RecipientKey -> m Signed
        createConn st rKey = mkSigned "" <$> addSubscribe
          where
            addSubscribe =
              addConn st rKey >>= \case
                Right Connection {recipientId = rId, senderId = sId} -> do
                  void $ subscribeConn rId
                  return $ IDS rId sId
                Left e -> return $ ERR e

        subscribeConn :: RecipientId -> m Signed
        subscribeConn rId = do
          atomically $ do
            cs <- readTVar connections
            when (M.notMember rId cs) $ do
              writeTBQueue subscribedQ (rId, clnt)
              writeTVar connections $ M.insert rId (Left ()) cs
          deliverMessage tryPeekMsg rId

        unsubscribeConn :: RecipientId -> m ()
        unsubscribeConn rId = do
          cs <- readTVarIO connections
          atomically . writeTVar connections $ M.delete rId cs
          case M.lookup rId cs of
            Just (Right threadId) -> killThread threadId
            _ -> return ()

        sendMessage :: MonadConnStore s m => s -> SenderId -> MsgBody -> m Signed
        sendMessage st sId msgBody =
          getConn st SSender sId
            >>= fmap (mkSigned sId) . either (return . ERR) storeMessage
          where
            storeMessage :: Connection -> m (Command 'Broker)
            storeMessage c = case status c of
              ConnActive -> do
                ms <- asks msgStore
                q <- getMsgQueue ms (recipientId c)
                msg <- newMessage msgBody
                writeMsg q msg
                return OK
              ConnOff -> return $ ERR AUTH

        deliverMessage :: (MsgQueue -> m (Maybe Message)) -> RecipientId -> m Signed
        deliverMessage tryPeek rId = do
          ms <- asks msgStore
          q <- getMsgQueue ms rId
          tryPeek q >>= \case
            Just msg -> return $ msgResponse rId msg
            Nothing -> forkSubscriber q rId

        forkSubscriber :: MsgQueue -> RecipientId -> m Signed
        forkSubscriber q rId = do
          cs <- readTVarIO connections
          case M.lookup rId cs of
            Just (Left ()) -> do
              threadId <- forkIO subscriber
              trackSubscriber $ Right threadId
              return ok
            _ -> return ok
          where
            trackSubscriber sThrd = atomically . modifyTVar connections $ M.insert rId sThrd
            subscriber = do
              msg <- peekMsg q
              atomically . writeTBQueue sndQ $ msgResponse rId msg
              trackSubscriber $ Left ()

        mkSigned :: ConnId -> Command 'Broker -> Signed
        mkSigned cId command = (cId, Cmd SBroker command)

        msgResponse :: RecipientId -> Message -> Signed
        msgResponse rId Message {msgId, ts, msgBody} = mkSigned rId $ MSG msgId ts msgBody
