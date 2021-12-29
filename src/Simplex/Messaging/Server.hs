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
import Data.Maybe (isNothing)
import Data.Time.Clock
import Data.Type.Equality
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
      raceAny_
        ( serverThread s subscribedQ subscribers subscriptions cancelSub :
          serverThread s ntfSubscribedQ notifiers ntfSubscriptions (\_ -> pure ()) :
          map runServer transports
        )
        `finally` withLog closeStoreLog

    runServer :: (MonadUnliftIO m', MonadReader Env m') => (ServiceName, ATransport) -> m' ()
    runServer (tcpPort, ATransport t) = do
      serverParams <- asks tlsServerParams
      runTransportServer started tcpPort serverParams (runClient t)

    serverThread ::
      forall m' s.
      MonadUnliftIO m' =>
      Server ->
      (Server -> TBQueue (QueueId, Client)) ->
      (Server -> TVar (M.Map QueueId Client)) ->
      (Client -> TVar (M.Map QueueId s)) ->
      (s -> m' ()) ->
      m' ()
    serverThread s subQ subs clientSubs unsub = forever $ do
      atomically updateSubscribers
        >>= fmap join . mapM endPreviousSubscriptions
        >>= mapM_ unsub
      where
        updateSubscribers :: STM (Maybe (QueueId, Client))
        updateSubscribers = do
          (qId, clnt) <- readTBQueue $ subQ s
          let clientToBeNotified = \c' ->
                if sameClientSession clnt c'
                  then pure Nothing
                  else do
                    yes <- readTVar $ connected c'
                    pure $ if yes then Just (qId, c') else Nothing
          stateTVar (subs s) (\cs -> (M.lookup qId cs, M.insert qId clnt cs))
            >>= fmap join . mapM clientToBeNotified
        endPreviousSubscriptions :: (QueueId, Client) -> m' (Maybe s)
        endPreviousSubscriptions (qId, c) = do
          void . forkIO . atomically $
            writeTBQueue (sndQ c) (CorrId "", qId, END)
          atomically . stateTVar (clientSubs c) $ \ss -> (M.lookup qId ss, M.delete qId ss)

runClient :: (Transport c, MonadUnliftIO m, MonadReader Env m) => TProxy c -> c -> m ()
runClient _ h =
  liftIO (runExceptT $ serverHandshake h) >>= \case
    Right th -> runClientTransport th
    Left _ -> pure ()

runClientTransport :: (Transport c, MonadUnliftIO m, MonadReader Env m) => THandle c -> m ()
runClientTransport th@THandle {sessionId} = do
  q <- asks $ tbqSize . config
  c <- atomically $ newClient q sessionId
  s <- asks server
  raceAny_ [send th c, client c s, receive th c]
    `finally` clientDisconnected c

clientDisconnected :: (MonadUnliftIO m, MonadReader Env m) => Client -> m ()
clientDisconnected c@Client {subscriptions, connected} = do
  atomically $ writeTVar connected False
  subs <- readTVarIO subscriptions
  mapM_ cancelSub subs
  cs <- asks $ subscribers . server
  atomically . mapM_ (modifyTVar cs . M.update deleteCurrentClient) $ M.keys subs
  where
    deleteCurrentClient :: Client -> Maybe Client
    deleteCurrentClient c'
      | sameClientSession c c' = Nothing
      | otherwise = Just c'

sameClientSession :: Client -> Client -> Bool
sameClientSession Client {sessionId} Client {sessionId = s'} = sessionId == s'

cancelSub :: MonadUnliftIO m => Sub -> m ()
cancelSub = \case
  Sub {subThread = SubThread t} -> killThread t
  _ -> return ()

receive :: (Transport c, MonadUnliftIO m, MonadReader Env m) => THandle c -> Client -> m ()
receive th Client {rcvQ, sndQ} = forever $ do
  (sig, signed, (corrId, queueId, cmdOrError)) <- tGet th
  case cmdOrError of
    Left e -> write sndQ (corrId, queueId, ERR e)
    Right cmd -> do
      verified <- verifyTransmission sig signed queueId cmd
      if verified
        then write rcvQ (corrId, queueId, cmd)
        else write sndQ (corrId, queueId, ERR AUTH)
  where
    write q t = atomically $ writeTBQueue q t

send :: (Transport c, MonadUnliftIO m) => THandle c -> Client -> m ()
send h Client {sndQ, sessionId} = forever $ do
  t <- atomically $ readTBQueue sndQ
  liftIO $ tPut h (Nothing, encodeTransmission sessionId t)

verifyTransmission ::
  forall m. (MonadUnliftIO m, MonadReader Env m) => Maybe C.ASignature -> ByteString -> QueueId -> ClientCmd -> m Bool
verifyTransmission sig_ signed queueId cmd = do
  case cmd of
    ClientCmd SRecipient (NEW k _) -> pure $ verifySignature k
    ClientCmd SRecipient _ -> verifyCmd (CP SRecipient) $ verifySignature . recipientKey
    ClientCmd SSender (SEND _) -> verifyCmd (CP SSender) $ verifyMaybe . senderKey
    ClientCmd SSender PING -> pure True
    ClientCmd SNotifier NSUB -> verifyCmd (CP SNotifier) $ verifyMaybe . fmap snd . notifier
  where
    verifyCmd :: ClientParty -> (QueueRec -> Bool) -> m Bool
    verifyCmd party f = do
      st <- asks queueStore
      q <- atomically $ getQueue st party queueId
      pure $ either (const $ maybe False dummyVerify sig_ `seq` False) f q
    verifyMaybe :: Maybe C.APublicVerifyKey -> Bool
    verifyMaybe = maybe (isNothing sig_) verifySignature
    verifySignature :: C.APublicVerifyKey -> Bool
    verifySignature key = maybe False (verify key) sig_
    verify :: C.APublicVerifyKey -> C.ASignature -> Bool
    verify (C.APublicVerifyKey a k) sig@(C.ASignature a' s) =
      case (testEquality a a', C.signatureSize k == C.signatureSize s) of
        (Just Refl, True) -> C.verify' k s signed
        _ -> dummyVerify sig `seq` False
    dummyVerify :: C.ASignature -> Bool
    dummyVerify (C.ASignature _ s) = C.verify' (dummyPublicKey s) s signed

-- These dummy keys are used with `dummyVerify` function to mitigate timing attacks
-- by having the same time of the response whether a queue exists or nor, for all valid key/signature sizes
dummyPublicKey :: C.Signature a -> C.PublicKey a
dummyPublicKey = \case
  C.SignatureEd25519 _ -> dummyKeyEd25519
  C.SignatureEd448 _ -> dummyKeyEd448

dummyKeyEd25519 :: C.PublicKey 'C.Ed25519
dummyKeyEd25519 = "MCowBQYDK2VwAyEA139Oqs4QgpqbAmB0o7rZf6T19ryl7E65k4AYe0kE3Qs="

dummyKeyEd448 :: C.PublicKey 'C.Ed448
dummyKeyEd448 = "MEMwBQYDK2VxAzoA6ibQc9XpkSLtwrf7PLvp81qW/etiumckVFImCMRdftcG/XopbOSaq9qyLhrgJWKOLyNrQPNVvpMA"

client :: forall m. (MonadUnliftIO m, MonadReader Env m) => Client -> Server -> m ()
client clnt@Client {subscriptions, ntfSubscriptions, rcvQ, sndQ} Server {subscribedQ, ntfSubscribedQ, notifiers} =
  forever $
    atomically (readTBQueue rcvQ)
      >>= processCommand
      >>= atomically . writeTBQueue sndQ
  where
    processCommand :: Transmission ClientCmd -> m BrokerTransmission
    processCommand (corrId, queueId, cmd) = do
      st <- asks queueStore
      case cmd of
        ClientCmd SSender command ->
          case command of
            SEND msgBody -> sendMessage st msgBody
            PING -> pure (corrId, "", PONG)
        ClientCmd SNotifier NSUB -> subscribeNotifications
        ClientCmd SRecipient command ->
          case command of
            NEW rKey dhKey -> createQueue st rKey dhKey
            SUB -> subscribeQueue queueId
            ACK -> acknowledgeMsg
            KEY sKey -> secureQueue_ st sKey
            NKEY nKey -> addQueueNotifier_ st nKey
            OFF -> suspendQueue_ st
            DEL -> delQueueAndMsgs st
      where
        createQueue :: QueueStore -> RcvPublicVerifyKey -> RcvPublicDhKey -> m BrokerTransmission
        createQueue st recipientKey dhKey = do
          (rcvPublicDhKey, privDhKey) <- liftIO C.generateKeyPair'
          let rcvDhSecret = C.dh' dhKey privDhKey
              qik (rcvId, sndId) = QIK {rcvId, sndId, rcvPublicDhKey}
              qRec (recipientId, senderId) =
                QueueRec
                  { recipientId,
                    senderId,
                    recipientKey,
                    rcvDhSecret,
                    senderKey = Nothing,
                    notifier = Nothing,
                    status = QueueActive
                  }
          (corrId,queueId,) <$> addQueueRetry 3 qik qRec
          where
            addQueueRetry ::
              Int -> ((RecipientId, SenderId) -> QueueIdsKeys) -> ((RecipientId, SenderId) -> QueueRec) -> m (Command 'Broker)
            addQueueRetry 0 _ _ = pure $ ERR INTERNAL
            addQueueRetry n qik qRec = do
              ids@(rId, _) <- getIds
              -- create QueueRec record with these ids and keys
              atomically (addQueue st $ qRec ids) >>= \case
                Left DUPLICATE_ -> addQueueRetry (n - 1) qik qRec
                Left e -> pure $ ERR e
                Right _ -> do
                  withLog (`logCreateById` rId)
                  subscribeQueue rId $> IDS (qik ids)

            logCreateById :: StoreLog 'WriteMode -> RecipientId -> IO ()
            logCreateById s rId =
              atomically (getQueue st (CP SRecipient) rId) >>= \case
                Right q -> logCreateQueue s q
                _ -> pure ()

            getIds :: m (RecipientId, SenderId)
            getIds = do
              n <- asks $ queueIdBytes . config
              liftM2 (,) (randomId n) (randomId n)

        secureQueue_ :: QueueStore -> SndPublicVerifyKey -> m BrokerTransmission
        secureQueue_ st sKey = do
          withLog $ \s -> logSecureQueue s queueId sKey
          atomically $ (corrId,queueId,) . either ERR (const OK) <$> secureQueue st queueId sKey

        addQueueNotifier_ :: QueueStore -> NtfPublicVerifyKey -> m BrokerTransmission
        addQueueNotifier_ st nKey = (corrId,queueId,) <$> addNotifierRetry 3
          where
            addNotifierRetry :: Int -> m (Command 'Broker)
            addNotifierRetry 0 = pure $ ERR INTERNAL
            addNotifierRetry n = do
              nId <- randomId =<< asks (queueIdBytes . config)
              atomically (addQueueNotifier st queueId nId nKey) >>= \case
                Left DUPLICATE_ -> addNotifierRetry $ n - 1
                Left e -> pure $ ERR e
                Right _ -> do
                  withLog $ \s -> logAddNotifier s queueId nId nKey
                  pure $ NID nId

        suspendQueue_ :: QueueStore -> m BrokerTransmission
        suspendQueue_ st = do
          withLog (`logDeleteQueue` queueId)
          okResp <$> atomically (suspendQueue st queueId)

        subscribeQueue :: RecipientId -> m BrokerTransmission
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

        subscribeNotifications :: m BrokerTransmission
        subscribeNotifications = atomically $ do
          subs <- readTVar ntfSubscriptions
          when (isNothing $ M.lookup queueId subs) $ do
            writeTBQueue ntfSubscribedQ (queueId, clnt)
            writeTVar ntfSubscriptions $ M.insert queueId () subs
          pure ok

        acknowledgeMsg :: m BrokerTransmission
        acknowledgeMsg =
          atomically (withSub queueId $ \s -> const s <$$> tryTakeTMVar (delivered s))
            >>= \case
              Just (Just s) -> deliverMessage tryDelPeekMsg queueId s
              _ -> return $ err NO_MSG

        withSub :: RecipientId -> (Sub -> STM a) -> STM (Maybe a)
        withSub rId f = readTVar subscriptions >>= mapM f . M.lookup rId

        sendMessage :: QueueStore -> MsgBody -> m BrokerTransmission
        sendMessage st msgBody
          | B.length msgBody > maxMessageLength = pure $ err LARGE_MSG
          | otherwise = do
            qr <- atomically $ getQueue st (CP SSender) queueId
            either (return . err) storeMessage qr
          where
            storeMessage :: QueueRec -> m BrokerTransmission
            storeMessage qr = case status qr of
              QueueOff -> return $ err AUTH
              QueueActive ->
                mkMessage >>= \case
                  Left _ -> pure $ err LARGE_MSG
                  Right msg -> do
                    ms <- asks msgStore
                    quota <- asks $ msgQueueQuota . config
                    atomically $ do
                      q <- getMsgQueue ms (recipientId qr) quota
                      ifM (isFull q) (pure $ err QUOTA) $ do
                        trySendNotification
                        writeMsg q msg
                        pure ok
              where
                mkMessage :: m (Either C.CryptoError Message)
                mkMessage = do
                  msgId <- randomId =<< asks (msgIdBytes . config)
                  ts <- liftIO getCurrentTime
                  let c = C.cbEncrypt (rcvDhSecret qr) (C.cbNonce msgId) msgBody (maxMessageLength + 2)
                  pure $ Message msgId ts <$> c

                trySendNotification :: STM ()
                trySendNotification =
                  forM_ (notifier qr) $ \(nId, _) ->
                    mapM_ (writeNtf nId) . M.lookup nId =<< readTVar notifiers

                writeNtf :: NotifierId -> Client -> STM ()
                writeNtf nId Client {sndQ = q} =
                  unlessM (isFullTBQueue sndQ) $
                    writeTBQueue q (CorrId "", nId, NMSG)

        deliverMessage :: (MsgQueue -> STM (Maybe Message)) -> RecipientId -> Sub -> m BrokerTransmission
        deliverMessage tryPeek rId = \case
          Sub {subThread = NoSub} -> do
            ms <- asks msgStore
            quota <- asks $ msgQueueQuota . config
            q <- atomically $ getMsgQueue ms rId quota
            atomically (tryPeek q) >>= \case
              Nothing -> forkSub q $> ok
              Just msg -> atomically setDelivered $> (corrId, rId, msgCmd msg)
          _ -> pure ok
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
              writeTBQueue sndQ (CorrId "", rId, msgCmd msg)
              setSub (\s -> s {subThread = NoSub})
              void setDelivered

            setSub :: (Sub -> Sub) -> STM ()
            setSub f = modifyTVar subscriptions $ M.adjust f rId

            setDelivered :: STM (Maybe Bool)
            setDelivered = withSub rId $ \s -> tryPutTMVar (delivered s) ()

            msgCmd :: Message -> Command 'Broker
            msgCmd Message {msgId, ts, msgBody} = MSG msgId ts msgBody

        delQueueAndMsgs :: QueueStore -> m BrokerTransmission
        delQueueAndMsgs st = do
          withLog (`logDeleteQueue` queueId)
          ms <- asks msgStore
          atomically $
            deleteQueue st queueId >>= \case
              Left e -> pure $ err e
              Right _ -> delMsgQueue ms queueId $> ok

        ok :: BrokerTransmission
        ok = (corrId, queueId, OK)

        err :: ErrorType -> BrokerTransmission
        err e = (corrId, queueId, ERR e)

        okResp :: Either ErrorType () -> BrokerTransmission
        okResp = either err $ const ok

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
