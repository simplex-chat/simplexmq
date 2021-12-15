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
      credential <- asks serverCredential
      runTransportServer started tcpPort credential (runClient t)

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
      atomically updateSubscribers >>= mapM_ unsub
      where
        updateSubscribers :: STM (Maybe s)
        updateSubscribers = do
          (qId, clnt) <- readTBQueue $ subQ s
          serverSubs <- readTVar $ subs s
          writeTVar (subs s) $ M.insert qId clnt serverSubs
          join <$> mapM (endPreviousSubscriptions qId) (M.lookup qId serverSubs)
        endPreviousSubscriptions :: QueueId -> Client -> STM (Maybe s)
        endPreviousSubscriptions qId c = do
          writeTBQueue (sndQ c) (Just $ CP SRecipient, (CorrId "", qId, END))
          stateTVar (clientSubs c) $ \ss -> (M.lookup qId ss, M.delete qId ss)

runClient :: (Transport c, MonadUnliftIO m, MonadReader Env m) => TProxy c -> c -> m ()
runClient _ h = do
  keyPair <- asks serverKeyPair
  ServerConfig {blockSize} <- asks config
  liftIO (runExceptT $ serverHandshake h blockSize keyPair) >>= \case
    Right th -> runClientTransport th
    Left _ -> pure ()

runClientTransport :: (Transport c, MonadUnliftIO m, MonadReader Env m) => THandle c -> m ()
runClientTransport th@THandle {sndSessionId} = do
  q <- asks $ tbqSize . config
  c <- atomically $ newClient q sndSessionId
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
receive th Client {rcvQ, sndQ} = forever $ do
  (sig, signed, (corrId, queueId, cmdOrError)) <- tGet fromClient th
  case cmdOrError of
    Left e -> write sndQ (Nothing, (corrId, queueId, ERR e))
    Right cmd -> do
      verified <- verifyTransmission sig signed queueId cmd
      if verified
        then write rcvQ (corrId, queueId, cmd)
        else write sndQ (Nothing, (corrId, queueId, ERR AUTH))
  where
    write q t = atomically $ writeTBQueue q t

send :: (Transport c, MonadUnliftIO m, MonadReader Env m) => THandle c -> Client -> m ()
send h Client {sndQ, sndSessionId} = forever $ do
  atomically (readTBQueue sndQ)
    >>= signTransmission sndSessionId
    >>= liftIO . tPut h

signTransmission ::
  forall m. (MonadUnliftIO m, MonadReader Env m) => SessionId -> (Maybe ClientParty, BrokerTransmission) -> m SentRawTransmission
signTransmission sndSessionId (party_, t@(_, queueId, cmd)) =
  case party_ of
    Nothing -> unsigned
    Just (CP SNotifier) -> unsigned
    Just party ->
      case cmd of
        ERR QUOTA -> signed party
        ERR _ -> unsigned
        PONG -> unsigned
        _ -> signed party
  where
    s = serializeTransmission sndSessionId t
    unsigned = pure (Nothing, s)
    signed :: ClientParty -> m SentRawTransmission
    signed party = do
      st <- asks queueStore
      q <- atomically $ getQueue st party queueId
      pure (Nothing, s)

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
  C.SignatureRSA s' -> case B.length s' of
    128 -> dummyKey128
    256 -> dummyKey256
    384 -> dummyKey384
    512 -> dummyKey512
    _ -> dummyKey256
  C.SignatureEd25519 _ -> dummyKeyEd25519
  C.SignatureEd448 _ -> dummyKeyEd448

dummyKeyEd25519 :: C.PublicKey 'C.Ed25519
dummyKeyEd25519 = "MCowBQYDK2VwAyEA139Oqs4QgpqbAmB0o7rZf6T19ryl7E65k4AYe0kE3Qs="

dummyKeyEd448 :: C.PublicKey 'C.Ed448
dummyKeyEd448 = "MEMwBQYDK2VxAzoA6ibQc9XpkSLtwrf7PLvp81qW/etiumckVFImCMRdftcG/XopbOSaq9qyLhrgJWKOLyNrQPNVvpMA"

dummyKey128 :: C.PublicKey 'C.RSA
dummyKey128 = "MIIBIDANBgkqhkiG9w0BAQEFAAOCAQ0AMIIBCAKBgQC2oeA7s4roXN5K2N6022I1/2CTeMKjWH0m00bSZWa4N8LDKeFcShh8YUxZea5giAveViTRNOOVLgcuXbKvR3u24szN04xP0+KnYUuUUIIoT3YSjX0IlomhDhhSyup4BmA0gAZ+D1OaIKZFX6J8yQ1Lr/JGLEfSRsBjw8l+4hs9OwKBgQDKA+YlZvGb3BcpDwKmatiCXN7ZRDWkjXbj8VAW5zV95tSRCCVN48hrFM1H4Ju2QMMUc6kPUVX+eW4ZjdCl5blIqIHMcTmsdcmsDDCg3PjUNrwc6bv/1TcirbAKcmnKt9iurIt6eerxSO7TZUXXMUVsi7eRwb/RUNhpCrpJ/hpIOw=="

dummyKey256 :: C.PublicKey 'C.RSA
dummyKey256 = "MIIBoDANBgkqhkiG9w0BAQEFAAOCAY0AMIIBiAKCAQEAxwmTvaqmdTbkfUGNi8Yu0L/T4cxuOlQlx3zGZ9X9Qx0+oZjknWK+QHrdWTcpS+zH4Hi7fP6kanOQoQ90Hj6Ghl57VU1GEdUPywSw4i1/7t0Wv9uT9Q2ktHp2rqVo3xkC9IVIpL7EZAxdRviIN2OsOB3g4a/F1ZpjxcAaZeOMUugiAX1+GtkLuE0Xn4neYjCaOghLxQTdhybN70VtnkiQLx/X9NjkDIl/spYGm3tQFMyYKkP6IWoEpj0926hJ0fmlmhy8tAOhlZsb/baW5cgkEZ3E9jVVrySCgQzoLQgma610FIISRpRJbSyv26jU7MkMxiyuBiDaFOORkXFttoKbtQKBgEbDS9II2brsz+vfI7uP8atFcawkE52cx4M1UWQhqb1H3tBiRl+qO+dMq1pPQF2bW7dlZAWYzS4W/367bTAuALHBDGB8xi1P4Njhh9vaOgTvuqrHG9NJQ85BLy0qGw8rjIWSIXVmVpfrXFJ8po5l04UE258Ll2yocv3QRQmddQW9"

dummyKey384 :: C.PublicKey 'C.RSA
dummyKey384 = "MIICITANBgkqhkiG9w0BAQEFAAOCAg4AMIICCQKCAYEAthExp77lSFBMB0RedjgKIU+oNH5lMGdMqDCG0E5Ly7X49rFpfDMMN08GDIgvzg9kcwV3ScbPcjUE19wmAShX9f9k3w38KM3wmIBKSiuCREQl0V3xAYp1SYwiAkMNSSwxuIkDEeSOR56WdEcZvqbB4lY9MQlUv70KriPDxZaqKCTKslUezXHQuYPQX6eMnGFK7hxz5Kl5MajV52d+5iXsa8CA+m/e1KVnbelCO+xhN89xG8ALt0CJ9k5Wwo3myLgXi4dmNankCmg8jkh+7y2ywkzxMwH1JydDtV/FLzkbZsbPR2w93TNrTq1RJOuqMyh0VtdBSpxNW/Ft988TkkX2BAWzx82INw7W6/QbHGNtHNB995R4sgeYy8QbEpNGBhQnfQh7yRWygLTVXWKApQzzfCeIoDDWUS7dMv/zXoasAnpDBj+6UhHv3BHrps7kBvRyZQ2d/nUuAqiGd43ljJ++n6vNyFLgZoiV7HLia/FOGMkdt7j92CNmFHxiT6Xl7kRHAoGBAPNoWny2O7LBxzAKMLmQVHBAiKp6RMx+7URvtQDHDHPaZ7F3MvtvmYWwGzund3cQFAaV1EkJoYeI3YRuj6xdXgMyMaP54On++btArb6jUtZuvlC98qE8dEEHQNh+7TsCiMU+ivbeKFxS9A/B7OVedoMnPoJWhatbA9zB/6L1GNPh"

dummyKey512 :: C.PublicKey 'C.RSA
dummyKey512 = "MIICoDANBgkqhkiG9w0BAQEFAAOCAo0AMIICiAKCAgEArkCY9DuverJ4mmzDektv9aZMFyeRV46WZK9NsOBKEc+1ncqMs+LhLti9asKNgUBRbNzmbOe0NYYftrUpwnATaenggkTFxxbJ4JGJuGYbsEdFWkXSvrbWGtM8YUmn5RkAGme12xQ89bSM4VoJAGnrYPHwmcQd+KYCPZvTUsxaxgrJTX65ejHN9BsAn8XtGViOtHTDJO9yUMD2WrJvd7wnNa+0ugEteDLzMU++xS98VC+uA1vfauUqi3yXVchdfrLdVUuM+JE0gUEXCgzjuHkaoHiaGNiGhdPYoAJJdOKQOIHAKdk7Th6OPhirPhc9XYNB4O8JDthKhNtfokvFIFlC4QBRzJhpLIENaEBDt08WmgpOnecZB/CuxkqqOrNa8j5K5jNrtXAI67W46VEC2jeQy/gZwb64Zit2A4D00xXzGbQTPGj4ehcEMhLx5LSCygViEf0w0tN3c3TEyUcgPzvECd2ZVpQLr9Z4a07Ebr+YSuxcHhjg4Rg1VyJyOTTvaCBGm5X2B3+tI4NUttmikIHOYpBnsLmHY2BgfH2KcrIsDyAhInXmTFr/L2+erFarUnlfATd2L8Ti43TNHDedO6k6jI5Gyi62yPwjqPLEIIK8l+pIeNfHJ3pPmjhHBfzFcQLMMMXffHWNK8kWklrQXK+4j4HiPcTBvlO1FEtG9nEIZhUCgYA4a6WtI2k5YNli1C89GY5rGUY7RP71T6RWri/D3Lz9T7GvU+FemAyYmsvCQwqijUOur0uLvwSP8VdxpSUcrjJJSWur2hrPWzWlu0XbNaeizxpFeKbQP+zSrWJ1z8RwfAeUjShxt8q1TuqGqY10wQyp3nyiTGvS+KwZVj5h5qx8NQ=="

client :: forall m. (MonadUnliftIO m, MonadReader Env m) => Client -> Server -> m ()
client clnt@Client {subscriptions, ntfSubscriptions, rcvQ, sndQ} Server {subscribedQ, ntfSubscribedQ, notifiers} =
  forever $
    atomically (readTBQueue rcvQ)
      >>= processCommand
      >>= atomically . writeTBQueue sndQ
  where
    processCommand :: Transmission ClientCmd -> m (Maybe ClientParty, BrokerTransmission)
    processCommand (corrId, queueId, cmd) = do
      st <- asks queueStore
      case cmd of
        ClientCmd SSender command -> case command of
          SEND msgBody -> (Just $ CP SSender,) <$> sendMessage st msgBody
          PING -> pure (Nothing, (corrId, queueId, PONG))
        ClientCmd SNotifier NSUB -> (Just $ CP SNotifier,) <$> subscribeNotifications
        ClientCmd SRecipient command ->
          (Just $ CP SRecipient,) <$> case command of
            NEW rKey dhKey -> createQueue st rKey dhKey
            SUB -> subscribeQueue queueId
            ACK -> acknowledgeMsg
            KEY sKey -> secureQueue_ st sKey
            NKEY nKey -> addQueueNotifier_ st nKey
            OFF -> suspendQueue_ st
            DEL -> delQueueAndMsgs st
      where
        createQueue :: QueueStore -> RcvPublicVerifyKey -> RcvPublicDhKey -> m BrokerTransmission
        createQueue st recipientKey dhKey = checkKeySize recipientKey $ do
          C.SignAlg a <- asks $ trnSignAlg . config
          (rcvPublicDHKey, privDhKey) <- liftIO $ C.generateKeyPair' 0
          (rcvSrvVerifyKey, rcvSrvSignKey) <- liftIO $ C.generateSignatureKeyPair 0 a
          (sndSrvVerifyKey, sndSrvSignKey) <- liftIO $ C.generateSignatureKeyPair 0 a
          let rcvDhSecret = C.dh' dhKey privDhKey
              qik (rcvId, sndId) = QIK {rcvId, rcvSrvVerifyKey, rcvPublicDHKey, sndId, sndSrvVerifyKey}
              qRec (recipientId, senderId) =
                QueueRec
                  { recipientId,
                    senderId,
                    recipientKey,
                    rcvSrvSignKey,
                    rcvDhSecret,
                    senderKey = Nothing,
                    sndSrvSignKey,
                    notifier = Nothing,
                    status = QueueActive
                  }
          addQueueRetry 3 qik qRec
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
          atomically . checkKeySize sKey $ either ERR (const OK) <$> secureQueue st queueId sKey

        addQueueNotifier_ :: QueueStore -> NtfPublicVerifyKey -> m BrokerTransmission
        addQueueNotifier_ st nKey = checkKeySize nKey $ addNotifierRetry 3
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

        checkKeySize :: Monad m' => C.APublicVerifyKey -> m' (Command 'Broker) -> m' BrokerTransmission
        checkKeySize key action =
          (corrId,queueId,)
            <$> if C.validKeySize key
              then action
              else pure . ERR $ CMD KEY_SIZE

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
        sendMessage st msgBody = do
          qr <- atomically $ getQueue st (CP SSender) queueId
          either (return . err) storeMessage qr
          where
            storeMessage :: QueueRec -> m BrokerTransmission
            storeMessage qr = case status qr of
              QueueOff -> return $ err AUTH
              QueueActive -> do
                ms <- asks msgStore
                msg <- mkMessage
                quota <- asks $ msgQueueQuota . config
                atomically $ do
                  q <- getMsgQueue ms (recipientId qr) quota
                  ifM (isFull q) (pure $ err QUOTA) $ do
                    trySendNotification
                    writeMsg q msg
                    pure ok
              where
                mkMessage :: m Message
                mkMessage = do
                  msgId <- randomId =<< asks (msgIdBytes . config)
                  ts <- liftIO getCurrentTime
                  let c = C.cbEncrypt (rcvDhSecret qr) (C.cbNonce msgId) msgBody
                  return $ Message {msgId, ts, msgBody = c}

                trySendNotification :: STM ()
                trySendNotification =
                  forM_ (notifier qr) $ \(nId, _) ->
                    mapM_ (writeNtf nId) . M.lookup nId =<< readTVar notifiers

                writeNtf :: NotifierId -> Client -> STM ()
                writeNtf nId Client {sndQ = q} =
                  unlessM (isFullTBQueue sndQ) $
                    writeTBQueue q (Just $ CP SNotifier, (CorrId "", nId, NMSG))

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
              writeTBQueue sndQ (Just $ CP SRecipient, (CorrId "", rId, msgCmd msg))
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
