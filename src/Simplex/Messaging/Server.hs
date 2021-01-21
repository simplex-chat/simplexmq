{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}

-- TODO move randomBytes to another module
module Simplex.Messaging.Server (runSMPServer, randomBytes) where

import Control.Concurrent.STM (stateTVar)
import Control.Monad
import Control.Monad.IO.Unlift
import Control.Monad.Reader
import Crypto.Random
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.Functor (($>))
import qualified Data.Map.Strict as M
import Data.Time.Clock
import qualified Simplex.Messaging.Protocol as SMP
import Simplex.Messaging.Server.Env.STM
import Simplex.Messaging.Server.MsgStore
import Simplex.Messaging.Server.MsgStore.STM (MsgQueue)
import Simplex.Messaging.Server.QueueStore
import Simplex.Messaging.Server.QueueStore.STM (QueueStore)
import Simplex.Messaging.Transport
import Simplex.Messaging.Util
import UnliftIO.Async
import UnliftIO.Concurrent
import UnliftIO.Exception
import UnliftIO.IO
import UnliftIO.STM

runSMPServer :: (MonadRandom m, MonadUnliftIO m) => ServerConfig -> m ()
runSMPServer cfg@ServerConfig {tcpPort} = do
  env <- newEnv cfg
  runReaderT smpServer env
  where
    smpServer :: (MonadUnliftIO m, MonadReader Env m) => m ()
    smpServer = do
      s <- asks server
      race_ (runTCPServer tcpPort runClient) (serverThread s)

    serverThread :: MonadUnliftIO m => Server -> m ()
    serverThread Server {subscribedQ, subscribers} = forever . atomically $ do
      (rId, clnt) <- readTBQueue subscribedQ
      cs <- readTVar subscribers
      case M.lookup rId cs of
        Just Client {rcvQ} -> writeTBQueue rcvQ (SMP.CorrId B.empty, rId, SMP.Cmd SMP.SBroker SMP.END)
        Nothing -> return ()
      writeTVar subscribers $ M.insert rId clnt cs

runClient :: (MonadUnliftIO m, MonadReader Env m) => Handle -> m ()
runClient h = do
  liftIO $ putLn h "Welcome to SMP v0.2.0"
  q <- asks $ tbqSize . config
  c <- atomically $ newClient q
  s <- asks server
  raceAny_ [send h c, client c s, receive h c]
    `finally` cancelSubscribers c

cancelSubscribers :: MonadUnliftIO m => Client -> m ()
cancelSubscribers Client {subscriptions} =
  readTVarIO subscriptions >>= mapM_ cancelSub

cancelSub :: MonadUnliftIO m => Sub -> m ()
cancelSub = \case
  Sub {subThread = SubThread t} -> killThread t
  _ -> return ()

receive :: (MonadUnliftIO m, MonadReader Env m) => Handle -> Client -> m ()
receive h Client {rcvQ} = forever $ do
  (signature, (corrId, queueId, cmdOrError)) <- SMP.tGet SMP.fromClient h
  signed <- case cmdOrError of
    Left e -> return . mkResp corrId queueId $ SMP.ERR e
    Right cmd -> verifyTransmission (signature, (corrId, queueId, cmd))
  atomically $ writeTBQueue rcvQ signed

send :: MonadUnliftIO m => Handle -> Client -> m ()
send h Client {sndQ} = forever $ do
  signed <- atomically $ readTBQueue sndQ
  SMP.tPut h (B.empty, signed)

mkResp :: SMP.CorrId -> SMP.QueueId -> SMP.Command 'SMP.Broker -> SMP.Signed
mkResp corrId queueId command = (corrId, queueId, SMP.Cmd SMP.SBroker command)

verifyTransmission :: forall m. (MonadUnliftIO m, MonadReader Env m) => SMP.Transmission -> m SMP.Signed
verifyTransmission (signature, (corrId, queueId, cmd)) = do
  (corrId,queueId,) <$> case cmd of
    SMP.Cmd SMP.SBroker _ -> return $ smpErr SMP.INTERNAL -- it can only be client command, because `fromClient` was used
    SMP.Cmd SMP.SRecipient (SMP.NEW _) -> return cmd
    SMP.Cmd SMP.SRecipient _ -> withQueueRec SMP.SRecipient $ verifySignature . recipientKey
    SMP.Cmd SMP.SSender (SMP.SEND _) -> withQueueRec SMP.SSender $ verifySend . senderKey
  where
    withQueueRec :: SMP.SParty (p :: SMP.Party) -> (QueueRec -> m SMP.Cmd) -> m SMP.Cmd
    withQueueRec party f = do
      st <- asks queueStore
      qr <- atomically $ getQueue st party queueId
      either (return . smpErr) f qr
    verifySend :: Maybe SMP.PublicKey -> m SMP.Cmd
    verifySend
      | B.null signature = return . maybe cmd (const authErr)
      | otherwise = maybe (return authErr) verifySignature
    -- TODO stub
    verifySignature :: SMP.PublicKey -> m SMP.Cmd
    verifySignature key = return $ if signature == key then cmd else authErr

    smpErr e = SMP.Cmd SMP.SBroker $ SMP.ERR e
    authErr = smpErr SMP.AUTH

client :: forall m. (MonadUnliftIO m, MonadReader Env m) => Client -> Server -> m ()
client clnt@Client {subscriptions, rcvQ, sndQ} Server {subscribedQ} =
  forever $
    atomically (readTBQueue rcvQ)
      >>= processCommand
      >>= atomically . writeTBQueue sndQ
  where
    processCommand :: SMP.Signed -> m SMP.Signed
    processCommand (corrId, queueId, cmd) = do
      st <- asks queueStore
      case cmd of
        SMP.Cmd SMP.SBroker SMP.END -> unsubscribeQueue $> (corrId, queueId, cmd)
        SMP.Cmd SMP.SBroker _ -> return (corrId, queueId, cmd)
        SMP.Cmd SMP.SSender (SMP.SEND msgBody) -> sendMessage st msgBody
        SMP.Cmd SMP.SRecipient command -> case command of
          SMP.NEW rKey -> createQueue st rKey
          SMP.SUB -> subscribeQueue queueId
          SMP.ACK -> acknowledgeMsg
          SMP.KEY sKey -> okResp <$> atomically (secureQueue st queueId sKey)
          SMP.OFF -> okResp <$> atomically (suspendQueue st queueId)
          SMP.DEL -> delQueueAndMsgs st
      where
        createQueue :: QueueStore -> SMP.RecipientKey -> m SMP.Signed
        createQueue st rKey = mkResp corrId B.empty <$> addSubscribe
          where
            addSubscribe =
              addQueueRetry 3 >>= \case
                Left e -> return $ SMP.ERR e
                Right (rId, sId) -> subscribeQueue rId $> SMP.IDS rId sId

            addQueueRetry :: Int -> m (Either SMP.ErrorType (SMP.RecipientId, SMP.SenderId))
            addQueueRetry 0 = return $ Left SMP.INTERNAL
            addQueueRetry n = do
              ids <- getIds
              atomically (addQueue st rKey ids) >>= \case
                Left SMP.DUPLICATE -> addQueueRetry $ n - 1
                Left e -> return $ Left e
                Right _ -> return $ Right ids

            getIds :: m (SMP.RecipientId, SMP.SenderId)
            getIds = do
              n <- asks $ queueIdBytes . config
              liftM2 (,) (randomId n) (randomId n)

        subscribeQueue :: SMP.RecipientId -> m SMP.Signed
        subscribeQueue rId =
          atomically (getSubscription rId) >>= deliverMessage tryPeekMsg rId

        getSubscription :: SMP.RecipientId -> STM Sub
        getSubscription rId = do
          subs <- readTVar subscriptions
          case M.lookup rId subs of
            Just s -> tryTakeTMVar (delivered s) $> s
            Nothing -> do
              writeTBQueue subscribedQ (rId, clnt)
              s <- newSubscription
              writeTVar subscriptions $ M.insert rId s subs
              return s

        unsubscribeQueue :: m ()
        unsubscribeQueue = do
          sub <- atomically . stateTVar subscriptions $
            \cs -> (M.lookup queueId cs, M.delete queueId cs)
          mapM_ cancelSub sub

        acknowledgeMsg :: m SMP.Signed
        acknowledgeMsg =
          atomically (withSub queueId $ \s -> const s <$$> tryTakeTMVar (delivered s))
            >>= \case
              Just (Just s) -> deliverMessage tryDelPeekMsg queueId s
              _ -> return $ err SMP.PROHIBITED

        withSub :: SMP.RecipientId -> (Sub -> STM a) -> STM (Maybe a)
        withSub rId f = readTVar subscriptions >>= mapM f . M.lookup rId

        sendMessage :: QueueStore -> SMP.MsgBody -> m SMP.Signed
        sendMessage st msgBody = do
          qr <- atomically $ getQueue st SMP.SSender queueId
          either (return . err) storeMessage qr
          where
            mkMessage :: m Message
            mkMessage = do
              msgId <- asks (msgIdBytes . config) >>= randomId
              ts <- liftIO getCurrentTime
              return $ Message {msgId, ts, msgBody}

            storeMessage :: QueueRec -> m SMP.Signed
            storeMessage qr = case status qr of
              QueueOff -> return $ err SMP.AUTH
              QueueActive -> do
                ms <- asks msgStore
                msg <- mkMessage
                atomically $ do
                  q <- getMsgQueue ms (recipientId qr)
                  writeMsg q msg
                  return ok

        deliverMessage :: (MsgQueue -> STM (Maybe Message)) -> SMP.RecipientId -> Sub -> m SMP.Signed
        deliverMessage tryPeek rId = \case
          Sub {subThread = NoSub} -> do
            ms <- asks msgStore
            q <- atomically $ getMsgQueue ms rId
            atomically (tryPeek q) >>= \case
              Nothing -> forkSub q $> ok
              Just msg -> atomically setDelivered $> mkResp corrId rId (msgCmd msg)
          _ -> return ok
          where
            forkSub :: MsgQueue -> m ()
            forkSub q = do
              atomically . setSub $ \s -> s {subThread = SubPending}
              t <- forkIO $ subscriber q
              atomically . setSub $ \case
                s@Sub {subThread = SubPending} -> s {subThread = SubThread t}
                s -> s

            subscriber :: MsgQueue -> m ()
            subscriber q = atomically $ do
              msg <- peekMsg q
              writeTBQueue sndQ $ mkResp (SMP.CorrId B.empty) rId (msgCmd msg)
              setSub (\s -> s {subThread = NoSub})
              void setDelivered

            setSub :: (Sub -> Sub) -> STM ()
            setSub f = modifyTVar subscriptions $ M.adjust f rId

            setDelivered :: STM (Maybe Bool)
            setDelivered = withSub rId $ \s -> tryPutTMVar (delivered s) ()

        delQueueAndMsgs :: QueueStore -> m SMP.Signed
        delQueueAndMsgs st = do
          ms <- asks msgStore
          atomically $
            deleteQueue st queueId >>= \case
              Left e -> return $ err e
              Right _ -> delMsgQueue ms queueId $> ok

        ok :: SMP.Signed
        ok = mkResp corrId queueId SMP.OK

        err :: SMP.ErrorType -> SMP.Signed
        err = mkResp corrId queueId . SMP.ERR

        okResp :: Either SMP.ErrorType () -> SMP.Signed
        okResp = either err $ const ok

        msgCmd :: Message -> SMP.Command 'SMP.Broker
        msgCmd Message {msgId, ts, msgBody} = SMP.MSG msgId ts msgBody

randomId :: (MonadUnliftIO m, MonadReader Env m) => Int -> m SMP.Encoded
randomId n = do
  gVar <- asks idsDrg
  atomically (randomBytes n gVar)

randomBytes :: Int -> TVar ChaChaDRG -> STM ByteString
randomBytes n gVar = do
  g <- readTVar gVar
  let (bytes, g') = randomBytesGenerate n g
  writeTVar gVar g'
  return bytes
