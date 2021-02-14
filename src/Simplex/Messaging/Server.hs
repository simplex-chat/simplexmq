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
import Simplex.Messaging.Agent.Transmission (VerificationKey)
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Protocol
import Simplex.Messaging.Server.Env.STM
import Simplex.Messaging.Server.MsgStore
import Simplex.Messaging.Server.MsgStore.STM (MsgQueue)
import Simplex.Messaging.Server.QueueStore
import Simplex.Messaging.Server.QueueStore.STM (QueueStore)
import Simplex.Messaging.Transport
import Simplex.Messaging.Types
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
        Just Client {rcvQ} -> writeTBQueue rcvQ (CorrId B.empty, rId, Cmd SBroker END)
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
  (signature, (corrId, queueId, cmdOrError)) <- tGet fromClient h
  t <- case cmdOrError of
    Left e -> return . mkResp corrId queueId $ ERR e
    Right cmd -> verifyTransmission (signature, (corrId, queueId, cmd))
  atomically $ writeTBQueue rcvQ t

send :: MonadUnliftIO m => Handle -> Client -> m ()
send h Client {sndQ} = forever $ do
  t <- atomically $ readTBQueue sndQ
  liftIO $ tPut h ("", serializeTransmission t)

mkResp :: CorrId -> QueueId -> Command 'Broker -> Transmission
mkResp corrId queueId command = (corrId, queueId, Cmd SBroker command)

verifyTransmission :: forall m. (MonadUnliftIO m, MonadReader Env m) => SignedTransmission -> m Transmission
verifyTransmission (sig, t@(corrId, queueId, cmd)) = do
  (corrId,queueId,) <$> case cmd of
    Cmd SBroker _ -> return $ smpErr INTERNAL -- it can only be client command, because `fromClient` was used
    Cmd SRecipient (NEW k) -> return $ verifySignature k
    Cmd SRecipient _ -> withQueueRec SRecipient $ verifySignature . recipientKey
    Cmd SSender (SEND _) -> withQueueRec SSender $ verifySend sig . senderKey
  where
    withQueueRec :: SParty (p :: Party) -> (QueueRec -> Cmd) -> m Cmd
    withQueueRec party f = do
      st <- asks queueStore
      qr <- atomically $ getQueue st party queueId
      return $ either smpErr f qr
    verifySend :: C.Signature -> Maybe VerificationKey -> Cmd
    verifySend "" = maybe cmd (const authErr)
    verifySend _ = maybe authErr verifySignature
    verifySignature :: VerificationKey -> Cmd
    verifySignature key =
      if C.verify key sig (serializeTransmission t)
        then cmd
        else authErr

    smpErr e = Cmd SBroker $ ERR e
    authErr = smpErr AUTH

client :: forall m. (MonadUnliftIO m, MonadReader Env m) => Client -> Server -> m ()
client clnt@Client {subscriptions, rcvQ, sndQ} Server {subscribedQ} =
  forever $
    atomically (readTBQueue rcvQ)
      >>= processCommand
      >>= atomically . writeTBQueue sndQ
  where
    processCommand :: Transmission -> m Transmission
    processCommand (corrId, queueId, cmd) = do
      st <- asks queueStore
      case cmd of
        Cmd SBroker END -> unsubscribeQueue $> (corrId, queueId, cmd)
        Cmd SBroker _ -> return (corrId, queueId, cmd)
        Cmd SSender (SEND msgBody) -> sendMessage st msgBody
        Cmd SRecipient command -> case command of
          NEW rKey -> createQueue st rKey
          SUB -> subscribeQueue queueId
          ACK -> acknowledgeMsg
          KEY sKey -> okResp <$> atomically (secureQueue st queueId sKey)
          OFF -> okResp <$> atomically (suspendQueue st queueId)
          DEL -> delQueueAndMsgs st
      where
        createQueue :: QueueStore -> RecipientPublicKey -> m Transmission
        createQueue st rKey =
          mkResp corrId B.empty <$> addSubscribe
          where
            addSubscribe =
              addQueueRetry 3 >>= \case
                Left e -> return $ ERR e
                Right (rId, sId) -> subscribeQueue rId $> IDS rId sId

            addQueueRetry :: Int -> m (Either ErrorType (RecipientId, SenderId))
            addQueueRetry 0 = return $ Left INTERNAL
            addQueueRetry n = do
              ids <- getIds
              atomically (addQueue st rKey ids) >>= \case
                Left DUPLICATE -> addQueueRetry $ n - 1
                Left e -> return $ Left e
                Right _ -> return $ Right ids

            getIds :: m (RecipientId, SenderId)
            getIds = do
              n <- asks $ queueIdBytes . config
              liftM2 (,) (randomId n) (randomId n)

        subscribeQueue :: RecipientId -> m Transmission
        subscribeQueue rId =
          atomically (getSubscription rId) >>= deliverMessage tryPeekMsg rId

        getSubscription :: RecipientId -> STM Sub
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

        acknowledgeMsg :: m Transmission
        acknowledgeMsg =
          atomically (withSub queueId $ \s -> const s <$$> tryTakeTMVar (delivered s))
            >>= \case
              Just (Just s) -> deliverMessage tryDelPeekMsg queueId s
              _ -> return $ err PROHIBITED

        withSub :: RecipientId -> (Sub -> STM a) -> STM (Maybe a)
        withSub rId f = readTVar subscriptions >>= mapM f . M.lookup rId

        sendMessage :: QueueStore -> MsgBody -> m Transmission
        sendMessage st msgBody = do
          qr <- atomically $ getQueue st SSender queueId
          either (return . err) storeMessage qr
          where
            mkMessage :: m Message
            mkMessage = do
              msgId <- asks (msgIdBytes . config) >>= randomId
              ts <- liftIO getCurrentTime
              return $ Message {msgId, ts, msgBody}

            storeMessage :: QueueRec -> m Transmission
            storeMessage qr = case status qr of
              QueueOff -> return $ err AUTH
              QueueActive -> do
                ms <- asks msgStore
                msg <- mkMessage
                atomically $ do
                  q <- getMsgQueue ms (recipientId qr)
                  writeMsg q msg
                  return ok

        deliverMessage :: (MsgQueue -> STM (Maybe Message)) -> RecipientId -> Sub -> m Transmission
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
              writeTBQueue sndQ $ mkResp (CorrId B.empty) rId (msgCmd msg)
              setSub (\s -> s {subThread = NoSub})
              void setDelivered

            setSub :: (Sub -> Sub) -> STM ()
            setSub f = modifyTVar subscriptions $ M.adjust f rId

            setDelivered :: STM (Maybe Bool)
            setDelivered = withSub rId $ \s -> tryPutTMVar (delivered s) ()

        delQueueAndMsgs :: QueueStore -> m Transmission
        delQueueAndMsgs st = do
          ms <- asks msgStore
          atomically $
            deleteQueue st queueId >>= \case
              Left e -> return $ err e
              Right _ -> delMsgQueue ms queueId $> ok

        ok :: Transmission
        ok = mkResp corrId queueId OK

        err :: ErrorType -> Transmission
        err = mkResp corrId queueId . ERR

        okResp :: Either ErrorType () -> Transmission
        okResp = either err $ const ok

        msgCmd :: Message -> Command 'Broker
        msgCmd Message {msgId, ts, msgBody} = MSG msgId ts msgBody

randomId :: (MonadUnliftIO m, MonadReader Env m) => Int -> m Encoded
randomId n = do
  gVar <- asks idsDrg
  atomically (randomBytes n gVar)

randomBytes :: Int -> TVar ChaChaDRG -> STM ByteString
randomBytes n gVar = do
  g <- readTVar gVar
  let (bytes, g') = randomBytesGenerate n g
  writeTVar gVar g'
  return bytes
