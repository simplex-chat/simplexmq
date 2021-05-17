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

-- |
-- Module      : Simplex.Messaging.Server
-- Copyright   : (c) simplex.chat
-- License     : AGPL-3
--
-- Maintainer  : chat@simplex.chat
-- Stability   : experimental
-- Portability : non-portable
--
-- This module defines SMP protocol server with in-memory persistence
-- and optional append only log of SMP queue records.
--
-- See https://github.com/simplex-chat/simplexmq/blob/master/protocol/simplex-messaging.md
module Simplex.Messaging.Server (runSMPServer, runSMPServerBlocking) where

import Control.Concurrent.STM (stateTVar)
import Control.Monad
import Control.Monad.Except
import Control.Monad.IO.Unlift
import Control.Monad.Reader
import Crypto.Random
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.Functor (($>))
import qualified Data.Map.Strict as M
import Data.Time.Clock
import Network.Socket (ServiceName)
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Protocol
import Simplex.Messaging.Server.Env.STM
import Simplex.Messaging.Server.MsgStore
import Simplex.Messaging.Server.MsgStore.STM (MsgQueue)
import Simplex.Messaging.Server.QueueStore
import Simplex.Messaging.Server.QueueStore.STM (QueueStore)
import Simplex.Messaging.Server.StoreLog
import Simplex.Messaging.Transport
import Simplex.Messaging.Util
import UnliftIO.Concurrent
import UnliftIO.Exception
import UnliftIO.IO
import UnliftIO.STM

-- | Runs an SMP server using passed configuration.
--
-- See a full server here: https://github.com/simplex-chat/simplexmq/blob/master/apps/smp-server/Main.hs
runSMPServer :: (MonadRandom m, MonadUnliftIO m) => ServerConfig -> m ()
runSMPServer cfg = do
  started <- newEmptyTMVarIO
  runSMPServerBlocking started cfg

-- | Runs an SMP server using passed configuration with signalling.
--
-- This function uses passed TMVar to signal when the server is ready to accept TCP requests (True)
-- and when it is disconnected from the TCP socket once the server thread is killed (False).
runSMPServerBlocking :: (MonadRandom m, MonadUnliftIO m) => TMVar Bool -> ServerConfig -> m ()
runSMPServerBlocking started cfg@ServerConfig {transports} = do
  env <- newEnv cfg
  runReaderT smpServer env
  where
    smpServer :: (MonadUnliftIO m', MonadReader Env m') => m' ()
    smpServer = do
      s <- asks server
      raceAny_ (serverThread s : map runServer transports)
        `finally` withLog closeStoreLog

    runServer :: (MonadUnliftIO m', MonadReader Env m') => (ServiceName, ATransport) -> m' ()
    runServer (tcpPort, ATransport t) = runTransportServer started tcpPort (runClient t)

    serverThread :: MonadUnliftIO m' => Server -> m' ()
    serverThread Server {subscribedQ, subscribers} = forever . atomically $ do
      (rId, clnt) <- readTBQueue subscribedQ
      cs <- readTVar subscribers
      case M.lookup rId cs of
        Just Client {rcvQ} -> writeTBQueue rcvQ (CorrId B.empty, rId, Cmd SBroker END)
        Nothing -> return ()
      writeTVar subscribers $ M.insert rId clnt cs

runClient :: (Transport c, MonadUnliftIO m, MonadReader Env m) => TProxy c -> c -> m ()
runClient _ h = do
  keyPair <- asks serverKeyPair
  liftIO (runExceptT $ serverHandshake h keyPair) >>= \case
    Right th -> runClientTransport th
    Left _ -> pure ()

runClientTransport :: (Transport c, MonadUnliftIO m, MonadReader Env m) => THandle c -> m ()
runClientTransport th = do
  q <- asks $ tbqSize . config
  c <- atomically $ newClient q
  s <- asks server
  raceAny_ [send th c, client c s, receive th c]
    `finally` cancelSubscribers c

cancelSubscribers :: MonadUnliftIO m => Client -> m ()
cancelSubscribers Client {subscriptions} =
  readTVarIO subscriptions >>= mapM_ cancelSub

cancelSub :: MonadUnliftIO m => Sub -> m ()
cancelSub = \case
  Sub {subThread = SubThread t} -> killThread t
  _ -> return ()

receive :: (Transport c, MonadUnliftIO m, MonadReader Env m) => THandle c -> Client -> m ()
receive h Client {rcvQ} = forever $ do
  (signature, (corrId, queueId, cmdOrError)) <- tGet fromClient h
  t <- case cmdOrError of
    Left e -> return . mkResp corrId queueId $ ERR e
    Right cmd -> verifyTransmission (signature, (corrId, queueId, cmd))
  atomically $ writeTBQueue rcvQ t

send :: (Transport c, MonadUnliftIO m) => THandle c -> Client -> m ()
send h Client {sndQ} = forever $ do
  t <- atomically $ readTBQueue sndQ
  liftIO $ tPut h ("", serializeTransmission t)

mkResp :: CorrId -> QueueId -> Command 'Broker -> Transmission
mkResp corrId queueId command = (corrId, queueId, Cmd SBroker command)

verifyTransmission :: forall m. (MonadUnliftIO m, MonadReader Env m) => SignedTransmission -> m Transmission
verifyTransmission (sig, t@(corrId, queueId, cmd)) = do
  (corrId,queueId,) <$> case cmd of
    Cmd SBroker _ -> return $ smpErr INTERNAL -- it can only be client command, because `fromClient` was used
    Cmd SRecipient (NEW k) -> pure $ verifySignature k
    Cmd SRecipient _ -> verifyCmd SRecipient $ verifySignature . recipientKey
    Cmd SSender (SEND _) -> verifyCmd SSender $ verifySend sig . senderKey
    Cmd SSender PING -> return cmd
  where
    verifyCmd :: SParty p -> (QueueRec -> Cmd) -> m Cmd
    verifyCmd party f = do
      st <- asks queueStore
      q <- atomically $ getQueue st party queueId
      pure $ either (const $ dummyVerify authErr) f q
    verifySend :: C.Signature -> Maybe SenderPublicKey -> Cmd
    verifySend "" = maybe cmd (const authErr)
    verifySend _ = maybe authErr verifySignature
    verifySignature :: C.PublicKey -> Cmd
    verifySignature key = if verify key then cmd else authErr
    verify key
      | C.publicKeySize key == sigLen = cryptoVerify key
      | otherwise = dummyVerify False
    cryptoVerify key = C.verify key sig (serializeTransmission t)
    smpErr = Cmd SBroker . ERR
    authErr = smpErr AUTH
    dummyVerify :: a -> a
    dummyVerify = seq $
      cryptoVerify $ case sigLen of
        128 -> dummyKey128
        256 -> dummyKey256
        512 -> dummyKey512
        _ -> dummyKey256
    sigLen = B.length $ C.unSignature sig

-- These dummy keys are used with `dummyVerify` function to mitigate timing attacks
-- by having the same time of the response whether a queue exists or nor, for all valid key/signature sizes
dummyKey128 :: C.PublicKey
dummyKey128 = "MIIBIDANBgkqhkiG9w0BAQEFAAOCAQ0AMIIBCAKBgQC2oeA7s4roXN5K2N6022I1/2CTeMKjWH0m00bSZWa4N8LDKeFcShh8YUxZea5giAveViTRNOOVLgcuXbKvR3u24szN04xP0+KnYUuUUIIoT3YSjX0IlomhDhhSyup4BmA0gAZ+D1OaIKZFX6J8yQ1Lr/JGLEfSRsBjw8l+4hs9OwKBgQDKA+YlZvGb3BcpDwKmatiCXN7ZRDWkjXbj8VAW5zV95tSRCCVN48hrFM1H4Ju2QMMUc6kPUVX+eW4ZjdCl5blIqIHMcTmsdcmsDDCg3PjUNrwc6bv/1TcirbAKcmnKt9iurIt6eerxSO7TZUXXMUVsi7eRwb/RUNhpCrpJ/hpIOw=="

dummyKey256 :: C.PublicKey
dummyKey256 = "MIIBoDANBgkqhkiG9w0BAQEFAAOCAY0AMIIBiAKCAQEAxwmTvaqmdTbkfUGNi8Yu0L/T4cxuOlQlx3zGZ9X9Qx0+oZjknWK+QHrdWTcpS+zH4Hi7fP6kanOQoQ90Hj6Ghl57VU1GEdUPywSw4i1/7t0Wv9uT9Q2ktHp2rqVo3xkC9IVIpL7EZAxdRviIN2OsOB3g4a/F1ZpjxcAaZeOMUugiAX1+GtkLuE0Xn4neYjCaOghLxQTdhybN70VtnkiQLx/X9NjkDIl/spYGm3tQFMyYKkP6IWoEpj0926hJ0fmlmhy8tAOhlZsb/baW5cgkEZ3E9jVVrySCgQzoLQgma610FIISRpRJbSyv26jU7MkMxiyuBiDaFOORkXFttoKbtQKBgEbDS9II2brsz+vfI7uP8atFcawkE52cx4M1UWQhqb1H3tBiRl+qO+dMq1pPQF2bW7dlZAWYzS4W/367bTAuALHBDGB8xi1P4Njhh9vaOgTvuqrHG9NJQ85BLy0qGw8rjIWSIXVmVpfrXFJ8po5l04UE258Ll2yocv3QRQmddQW9"

dummyKey512 :: C.PublicKey
dummyKey512 = "MIICoDANBgkqhkiG9w0BAQEFAAOCAo0AMIICiAKCAgEArkCY9DuverJ4mmzDektv9aZMFyeRV46WZK9NsOBKEc+1ncqMs+LhLti9asKNgUBRbNzmbOe0NYYftrUpwnATaenggkTFxxbJ4JGJuGYbsEdFWkXSvrbWGtM8YUmn5RkAGme12xQ89bSM4VoJAGnrYPHwmcQd+KYCPZvTUsxaxgrJTX65ejHN9BsAn8XtGViOtHTDJO9yUMD2WrJvd7wnNa+0ugEteDLzMU++xS98VC+uA1vfauUqi3yXVchdfrLdVUuM+JE0gUEXCgzjuHkaoHiaGNiGhdPYoAJJdOKQOIHAKdk7Th6OPhirPhc9XYNB4O8JDthKhNtfokvFIFlC4QBRzJhpLIENaEBDt08WmgpOnecZB/CuxkqqOrNa8j5K5jNrtXAI67W46VEC2jeQy/gZwb64Zit2A4D00xXzGbQTPGj4ehcEMhLx5LSCygViEf0w0tN3c3TEyUcgPzvECd2ZVpQLr9Z4a07Ebr+YSuxcHhjg4Rg1VyJyOTTvaCBGm5X2B3+tI4NUttmikIHOYpBnsLmHY2BgfH2KcrIsDyAhInXmTFr/L2+erFarUnlfATd2L8Ti43TNHDedO6k6jI5Gyi62yPwjqPLEIIK8l+pIeNfHJ3pPmjhHBfzFcQLMMMXffHWNK8kWklrQXK+4j4HiPcTBvlO1FEtG9nEIZhUCgYA4a6WtI2k5YNli1C89GY5rGUY7RP71T6RWri/D3Lz9T7GvU+FemAyYmsvCQwqijUOur0uLvwSP8VdxpSUcrjJJSWur2hrPWzWlu0XbNaeizxpFeKbQP+zSrWJ1z8RwfAeUjShxt8q1TuqGqY10wQyp3nyiTGvS+KwZVj5h5qx8NQ=="

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
        Cmd SSender command -> case command of
          SEND msgBody -> sendMessage st msgBody
          PING -> return (corrId, queueId, Cmd SBroker PONG)
        Cmd SRecipient command -> case command of
          NEW rKey -> createQueue st rKey
          SUB -> subscribeQueue queueId
          ACK -> acknowledgeMsg
          KEY sKey -> secureQueue_ st sKey
          OFF -> suspendQueue_ st
          DEL -> delQueueAndMsgs st
      where
        createQueue :: QueueStore -> RecipientPublicKey -> m Transmission
        createQueue st rKey =
          checkKeySize rKey addSubscribe
          where
            addSubscribe =
              addQueueRetry 3 >>= \case
                Left e -> return $ ERR e
                Right (rId, sId) -> do
                  withLog (`logCreateById` rId)
                  subscribeQueue rId $> IDS rId sId

            addQueueRetry :: Int -> m (Either ErrorType (RecipientId, SenderId))
            addQueueRetry 0 = return $ Left INTERNAL
            addQueueRetry n = do
              ids <- getIds
              atomically (addQueue st rKey ids) >>= \case
                Left DUPLICATE_ -> addQueueRetry $ n - 1
                Left e -> return $ Left e
                Right _ -> return $ Right ids

            logCreateById :: StoreLog 'WriteMode -> RecipientId -> IO ()
            logCreateById s rId =
              atomically (getQueue st SRecipient rId) >>= \case
                Right q -> logCreateQueue s q
                _ -> pure ()

            getIds :: m (RecipientId, SenderId)
            getIds = do
              n <- asks $ queueIdBytes . config
              liftM2 (,) (randomId n) (randomId n)

        secureQueue_ :: QueueStore -> SenderPublicKey -> m Transmission
        secureQueue_ st sKey = do
          withLog $ \s -> logSecureQueue s queueId sKey
          atomically . checkKeySize sKey $ either ERR (const OK) <$> secureQueue st queueId sKey

        checkKeySize :: Monad m' => C.PublicKey -> m' (Command 'Broker) -> m' Transmission
        checkKeySize key action =
          mkResp corrId queueId
            <$> if C.validKeySize $ C.publicKeySize key
              then action
              else pure . ERR $ CMD KEY_SIZE

        suspendQueue_ :: QueueStore -> m Transmission
        suspendQueue_ st = do
          withLog (`logDeleteQueue` queueId)
          okResp <$> atomically (suspendQueue st queueId)

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
              _ -> return $ err NO_MSG

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
          withLog (`logDeleteQueue` queueId)
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

withLog :: (MonadUnliftIO m, MonadReader Env m) => (StoreLog 'WriteMode -> IO a) -> m ()
withLog action = do
  env <- ask
  liftIO . mapM_ action $ storeLog (env :: Env)

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
