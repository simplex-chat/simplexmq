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

module Server (runSMPServer) where

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
import Env.STM
import MsgStore
import MsgStore.STM (MsgQueue)
import QueueStore
import QueueStore.STM (QueueStore)
import Transmission
import Transport
import UnliftIO.Async
import UnliftIO.Concurrent
import UnliftIO.Exception
import UnliftIO.IO
import UnliftIO.STM

runSMPServer :: (MonadRandom m, MonadUnliftIO m) => Config -> m ()
runSMPServer cfg@Config {tcpPort} = do
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
        Just Client {rcvQ} -> writeTBQueue rcvQ (rId, Cmd SBroker END)
        Nothing -> return ()
      writeTVar subscribers $ M.insert rId clnt cs

runClient :: (MonadUnliftIO m, MonadReader Env m) => Handle -> m ()
runClient h = do
  putLn h "Welcome to SMP"
  q <- asks $ tbqSize . config
  c <- atomically $ newClient q
  s <- asks server
  raceAny_ [send h c, client c s, receive h c]
    `finally` cancelSubscribers c

cancelSubscribers :: (MonadUnliftIO m) => Client -> m ()
cancelSubscribers Client {subscriptions} =
  readTVarIO subscriptions >>= mapM_ cancelSub

cancelSub :: (MonadUnliftIO m) => Sub -> m ()
cancelSub = \case
  Sub {subThread = SubThread t} -> killThread t
  _ -> return ()

raceAny_ :: MonadUnliftIO m => [m a] -> m ()
raceAny_ = r []
  where
    r as (m : ms) = withAsync m $ \a -> r (a : as) ms
    r as [] = void $ waitAnyCancel as

receive :: (MonadUnliftIO m, MonadReader Env m) => Handle -> Client -> m ()
receive h Client {rcvQ} = forever $ do
  (signature, (queueId, cmdOrError)) <- tGet fromClient h
  signed <- case cmdOrError of
    Left e -> return . mkResp queueId $ ERR e
    Right cmd -> verifyTransmission signature queueId cmd
  atomically $ writeTBQueue rcvQ signed

send :: MonadUnliftIO m => Handle -> Client -> m ()
send h Client {sndQ} = forever $ do
  signed <- atomically $ readTBQueue sndQ
  tPut h (B.empty, signed)

mkResp :: QueueId -> Command 'Broker -> Signed
mkResp queueId command = (queueId, Cmd SBroker command)

verifyTransmission :: forall m. (MonadUnliftIO m, MonadReader Env m) => Signature -> QueueId -> Cmd -> m Signed
verifyTransmission signature queueId cmd = do
  (queueId,) <$> case cmd of
    Cmd SBroker _ -> return $ smpErr INTERNAL -- it can only be client command, because `fromClient` was used
    Cmd SRecipient (NEW _) -> return cmd
    Cmd SRecipient _ -> withQueueRec SRecipient $ verifySignature . recipientKey
    Cmd SSender (SEND _) -> withQueueRec SSender $ verifySend . senderKey
  where
    withQueueRec :: SParty (p :: Party) -> (QueueRec -> m Cmd) -> m Cmd
    withQueueRec party f = do
      st <- asks queueStore
      qr <- atomically $ getQueue st party queueId
      either (return . smpErr) f qr
    verifySend :: Maybe PublicKey -> m Cmd
    verifySend
      | B.null signature = return . maybe cmd (const authErr)
      | otherwise = maybe (return authErr) verifySignature
    -- TODO stub
    verifySignature :: PublicKey -> m Cmd
    verifySignature key = return $ if signature == key then cmd else authErr

    smpErr e = Cmd SBroker $ ERR e
    authErr = smpErr AUTH

client :: forall m. (MonadUnliftIO m, MonadReader Env m) => Client -> Server -> m ()
client clnt@Client {subscriptions, rcvQ, sndQ} Server {subscribedQ} =
  forever $
    atomically (readTBQueue rcvQ)
      >>= processCommand
      >>= atomically . writeTBQueue sndQ
  where
    processCommand :: Signed -> m Signed
    processCommand (queueId, cmd) = do
      st <- asks queueStore
      case cmd of
        Cmd SBroker END -> unsubscribeQueue $> (queueId, cmd)
        Cmd SBroker _ -> return (queueId, cmd)
        Cmd SSender (SEND msgBody) -> sendMessage st msgBody
        Cmd SRecipient command -> case command of
          NEW rKey -> createQueue st rKey
          SUB -> subscribeQueue queueId
          ACK -> acknowledgeMsg
          KEY sKey -> okResp <$> atomically (secureQueue st queueId sKey)
          OFF -> okResp <$> atomically (suspendQueue st queueId)
          DEL -> delQueueAndMsgs st
      where
        createQueue :: QueueStore -> RecipientKey -> m Signed
        createQueue st rKey = mkResp B.empty <$> addSubscribe
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

        subscribeQueue :: RecipientId -> m Signed
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

        acknowledgeMsg :: m Signed
        acknowledgeMsg =
          atomically (withSub queueId $ \s -> const s <$$> tryTakeTMVar (delivered s))
            >>= \case
              Just (Just s) -> deliverMessage tryDelPeekMsg queueId s
              _ -> return $ err PROHIBITED

        withSub :: RecipientId -> (Sub -> STM a) -> STM (Maybe a)
        withSub rId f = readTVar subscriptions >>= mapM f . M.lookup rId

        sendMessage :: QueueStore -> MsgBody -> m Signed
        sendMessage st msgBody = do
          qr <- atomically $ getQueue st SSender queueId
          either (return . err) storeMessage qr
          where
            mkMessage :: m Message
            mkMessage = do
              msgId <- asks (msgIdBytes . config) >>= randomId
              ts <- liftIO getCurrentTime
              return $ Message {msgId, ts, msgBody}

            storeMessage :: QueueRec -> m Signed
            storeMessage qr = case status qr of
              QueueOff -> return $ err AUTH
              QueueActive -> do
                ms <- asks msgStore
                msg <- mkMessage
                atomically $ do
                  q <- getMsgQueue ms (recipientId qr)
                  writeMsg q msg
                  return ok

        deliverMessage :: (MsgQueue -> STM (Maybe Message)) -> RecipientId -> Sub -> m Signed
        deliverMessage tryPeek rId = \case
          Sub {subThread = NoSub} -> do
            ms <- asks msgStore
            q <- atomically $ getMsgQueue ms rId
            atomically (tryPeek q) >>= \case
              Nothing -> forkSub q $> ok
              Just msg -> atomically setDelivered $> msgResp rId msg
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
              writeTBQueue sndQ $ msgResp rId msg
              setSub (\s -> s {subThread = NoSub})
              void setDelivered

            setSub :: (Sub -> Sub) -> STM ()
            setSub f = modifyTVar subscriptions $ M.adjust f rId

            setDelivered :: STM (Maybe Bool)
            setDelivered = withSub rId $ \s -> tryPutTMVar (delivered s) ()

        delQueueAndMsgs :: QueueStore -> m Signed
        delQueueAndMsgs st = do
          ms <- asks msgStore
          atomically $
            deleteQueue st queueId >>= \case
              Left e -> return $ err e
              Right _ -> delMsgQueue ms queueId $> ok

        ok :: Signed
        ok = mkResp queueId OK

        err :: ErrorType -> Signed
        err = mkResp queueId . ERR

        okResp :: Either ErrorType () -> Signed
        okResp = either err $ const ok

        msgResp :: RecipientId -> Message -> Signed
        msgResp rId Message {msgId, ts, msgBody} = mkResp rId $ MSG msgId ts msgBody

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
