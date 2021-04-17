{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Simplex.Messaging.Agent.Client
  ( AgentClient (..),
    newAgentClient,
    AgentMonad,
    getSMPServerClient,
    closeSMPServerClients,
    newReceiveQueue,
    subscribeQueue,
    sendConfirmation,
    sendHello,
    secureQueue,
    sendAgentMessage,
    sendAck,
    suspendQueue,
    deleteQueue,
    logServer,
    removeSubscription,
    cryptoError,
  )
where

import Control.Logger.Simple
import Control.Monad.Except
import Control.Monad.IO.Unlift
import Control.Monad.Reader
import Control.Monad.Trans.Except
import Data.ByteString.Base64
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import Data.Set (Set)
import qualified Data.Set as S
import Data.Text.Encoding
import Data.Time.Clock
import Simplex.Messaging.Agent.Env.SQLite
import Simplex.Messaging.Agent.Store
import Simplex.Messaging.Agent.Transmission
import Simplex.Messaging.Client
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Protocol (ErrorType (AUTH), MsgBody, QueueId, SenderPublicKey)
import Simplex.Messaging.Util (bshow, liftEitherError, liftError)
import UnliftIO.Concurrent
import UnliftIO.Exception (IOException)
import qualified UnliftIO.Exception as E
import UnliftIO.STM

data AgentClient = AgentClient
  { rcvQ :: TBQueue (ATransmission 'Client),
    sndQ :: TBQueue (ATransmission 'Agent),
    msgQ :: TBQueue SMPServerTransmission,
    smpClients :: TVar (Map SMPServer SMPClient),
    subscrSrvrs :: TVar (Map SMPServer (Set ConnAlias)),
    subscrConns :: TVar (Map ConnAlias SMPServer),
    clientId :: Int
  }

newAgentClient :: TVar Int -> AgentConfig -> STM AgentClient
newAgentClient cc AgentConfig {tbqSize} = do
  rcvQ <- newTBQueue tbqSize
  sndQ <- newTBQueue tbqSize
  msgQ <- newTBQueue tbqSize
  smpClients <- newTVar M.empty
  subscrSrvrs <- newTVar M.empty
  subscrConns <- newTVar M.empty
  clientId <- (+ 1) <$> readTVar cc
  writeTVar cc clientId
  return AgentClient {rcvQ, sndQ, msgQ, smpClients, subscrSrvrs, subscrConns, clientId}

type AgentMonad m = (MonadUnliftIO m, MonadReader Env m, MonadError AgentErrorType m)

getSMPServerClient :: forall m. AgentMonad m => AgentClient -> SMPServer -> m SMPClient
getSMPServerClient c@AgentClient {smpClients, msgQ} srv =
  readTVarIO smpClients
    >>= maybe newSMPClient return . M.lookup srv
  where
    newSMPClient :: m SMPClient
    newSMPClient = do
      smp <- connectClient
      logInfo . decodeUtf8 $ "Agent connected to " <> showServer srv
      atomically . modifyTVar smpClients $ M.insert srv smp
      return smp

    connectClient :: m SMPClient
    connectClient = do
      cfg <- asks $ smpCfg . config
      liftEitherError smpClientError (getSMPClient srv cfg msgQ clientDisconnected)
        `E.catch` \(e :: IOException) -> throwError (INTERNAL $ bshow e)

    clientDisconnected :: IO ()
    clientDisconnected = do
      removeSubs >>= mapM_ (mapM_ notifySub)
      logInfo . decodeUtf8 $ "Agent disconnected from " <> showServer srv

    removeSubs :: IO (Maybe (Set ConnAlias))
    removeSubs = atomically $ do
      modifyTVar smpClients $ M.delete srv
      cs <- M.lookup srv <$> readTVar (subscrSrvrs c)
      modifyTVar (subscrSrvrs c) $ M.delete srv
      modifyTVar (subscrConns c) $ maybe id deleteKeys cs
      return cs
      where
        deleteKeys :: Ord k => Set k -> Map k a -> Map k a
        deleteKeys ks m = S.foldr' M.delete m ks

    notifySub :: ConnAlias -> IO ()
    notifySub connAlias = atomically $ writeTBQueue (sndQ c) ("", connAlias, END)

closeSMPServerClients :: MonadUnliftIO m => AgentClient -> m ()
closeSMPServerClients c = liftIO $ readTVarIO (smpClients c) >>= mapM_ closeSMPClient

withSMP :: forall a m. AgentMonad m => AgentClient -> SMPServer -> (SMPClient -> ExceptT SMPClientError IO a) -> m a
withSMP c srv action =
  (getSMPServerClient c srv >>= runAction) `catchError` logServerError
  where
    runAction :: SMPClient -> m a
    runAction smp = liftError smpClientError $ action smp

    logServerError :: AgentErrorType -> m a
    logServerError e = do
      logServer "<--" c srv "" $ bshow e
      throwError e

withLogSMP :: AgentMonad m => AgentClient -> SMPServer -> QueueId -> ByteString -> (SMPClient -> ExceptT SMPClientError IO a) -> m a
withLogSMP c srv qId cmdStr action = do
  logServer "-->" c srv qId cmdStr
  res <- withSMP c srv action
  logServer "<--" c srv qId "OK"
  return res

smpClientError :: SMPClientError -> AgentErrorType
smpClientError = \case
  SMPServerError e -> SMP e
  SMPResponseError e -> BROKER $ RESPONSE e
  SMPQueueIdError -> BROKER QUEUE
  SMPUnexpectedResponse -> BROKER UNEXPECTED
  SMPResponseTimeout -> BROKER TIMEOUT
  SMPNetworkError -> BROKER NETWORK
  SMPTransportError e -> BROKER $ TRANSPORT e
  e@(SMPCryptoError _) -> INTERNAL $ bshow e

newReceiveQueue :: AgentMonad m => AgentClient -> SMPServer -> ConnAlias -> m (RcvQueue, SMPQueueInfo)
newReceiveQueue c srv connAlias = do
  size <- asks $ rsaKeySize . config
  (recipientKey, rcvPrivateKey) <- liftIO $ C.generateKeyPair size
  logServer "-->" c srv "" "NEW"
  (rcvId, sId) <- withSMP c srv $ \smp -> createSMPQueue smp rcvPrivateKey recipientKey
  logServer "<--" c srv "" $ B.unwords ["IDS", logSecret rcvId, logSecret sId]
  (encryptKey, decryptKey) <- liftIO $ C.generateKeyPair size
  let rq =
        RcvQueue
          { server = srv,
            rcvId,
            connAlias,
            rcvPrivateKey,
            sndId = Just sId,
            sndKey = Nothing,
            decryptKey,
            verifyKey = Nothing,
            status = New
          }
  addSubscription c rq connAlias
  return (rq, SMPQueueInfo srv sId encryptKey)

subscribeQueue :: AgentMonad m => AgentClient -> RcvQueue -> ConnAlias -> m ()
subscribeQueue c rq@RcvQueue {server, rcvPrivateKey, rcvId} connAlias = do
  withLogSMP c server rcvId "SUB" $ \smp ->
    subscribeSMPQueue smp rcvPrivateKey rcvId
  addSubscription c rq connAlias

addSubscription :: MonadUnliftIO m => AgentClient -> RcvQueue -> ConnAlias -> m ()
addSubscription c RcvQueue {server} connAlias = atomically $ do
  modifyTVar (subscrConns c) $ M.insert connAlias server
  modifyTVar (subscrSrvrs c) $ M.alter (Just . addSub) server
  where
    addSub :: Maybe (Set ConnAlias) -> Set ConnAlias
    addSub (Just cs) = S.insert connAlias cs
    addSub _ = S.singleton connAlias

removeSubscription :: AgentMonad m => AgentClient -> ConnAlias -> m ()
removeSubscription AgentClient {subscrConns, subscrSrvrs} connAlias = atomically $ do
  cs <- readTVar subscrConns
  writeTVar subscrConns $ M.delete connAlias cs
  mapM_
    (modifyTVar subscrSrvrs . M.alter (>>= delSub))
    (M.lookup connAlias cs)
  where
    delSub :: Set ConnAlias -> Maybe (Set ConnAlias)
    delSub cs =
      let cs' = S.delete connAlias cs
       in if S.null cs' then Nothing else Just cs'

logServer :: AgentMonad m => ByteString -> AgentClient -> SMPServer -> QueueId -> ByteString -> m ()
logServer dir AgentClient {clientId} srv qId cmdStr =
  logInfo . decodeUtf8 $ B.unwords ["A", "(" <> bshow clientId <> ")", dir, showServer srv, ":", logSecret qId, cmdStr]

showServer :: SMPServer -> ByteString
showServer srv = B.pack $ host srv <> maybe "" (":" <>) (port srv)

logSecret :: ByteString -> ByteString
logSecret bs = encode $ B.take 3 bs

sendConfirmation :: forall m. AgentMonad m => AgentClient -> SndQueue -> SenderPublicKey -> m ()
sendConfirmation c SndQueue {server, sndId, encryptKey} senderKey = do
  msg <- mkConfirmation
  withLogSMP c server sndId "SEND <KEY>" $ \smp ->
    sendSMPMessage smp Nothing sndId msg
  where
    mkConfirmation :: m MsgBody
    mkConfirmation = do
      let msg = serializeSMPMessage $ SMPConfirmation senderKey
      paddedSize <- asks paddedMsgSize
      liftError cryptoError $ C.encrypt encryptKey paddedSize msg

sendHello :: forall m. AgentMonad m => AgentClient -> SndQueue -> VerificationKey -> m ()
sendHello c SndQueue {server, sndId, sndPrivateKey, encryptKey} verifyKey = do
  msg <- mkHello $ AckMode On
  withLogSMP c server sndId "SEND <HELLO> (retrying)" $
    send 20 msg
  where
    mkHello :: AckMode -> m ByteString
    mkHello ackMode = do
      senderTs <- liftIO getCurrentTime
      mkAgentMessage encryptKey senderTs $ HELLO verifyKey ackMode

    send :: Int -> ByteString -> SMPClient -> ExceptT SMPClientError IO ()
    send 0 _ _ = throwE $ SMPServerError AUTH
    send retry msg smp =
      sendSMPMessage smp (Just sndPrivateKey) sndId msg `catchE` \case
        SMPServerError AUTH -> do
          threadDelay 200000
          send (retry - 1) msg smp
        e -> throwE e

secureQueue :: AgentMonad m => AgentClient -> RcvQueue -> SenderPublicKey -> m ()
secureQueue c RcvQueue {server, rcvId, rcvPrivateKey} senderKey =
  withLogSMP c server rcvId "KEY <key>" $ \smp ->
    secureSMPQueue smp rcvPrivateKey rcvId senderKey

sendAck :: AgentMonad m => AgentClient -> RcvQueue -> m ()
sendAck c RcvQueue {server, rcvId, rcvPrivateKey} =
  withLogSMP c server rcvId "ACK" $ \smp ->
    ackSMPMessage smp rcvPrivateKey rcvId

suspendQueue :: AgentMonad m => AgentClient -> RcvQueue -> m ()
suspendQueue c RcvQueue {server, rcvId, rcvPrivateKey} =
  withLogSMP c server rcvId "OFF" $ \smp ->
    suspendSMPQueue smp rcvPrivateKey rcvId

deleteQueue :: AgentMonad m => AgentClient -> RcvQueue -> m ()
deleteQueue c RcvQueue {server, rcvId, rcvPrivateKey} =
  withLogSMP c server rcvId "DEL" $ \smp ->
    deleteSMPQueue smp rcvPrivateKey rcvId

sendAgentMessage :: AgentMonad m => AgentClient -> SndQueue -> SenderTimestamp -> AMessage -> m ()
sendAgentMessage c SndQueue {server, sndId, sndPrivateKey, encryptKey} senderTs agentMsg = do
  msg <- mkAgentMessage encryptKey senderTs agentMsg
  withLogSMP c server sndId "SEND <message>" $ \smp ->
    sendSMPMessage smp (Just sndPrivateKey) sndId msg

mkAgentMessage :: AgentMonad m => EncryptionKey -> SenderTimestamp -> AMessage -> m ByteString
mkAgentMessage encKey senderTs agentMessage = do
  let msg =
        serializeSMPMessage
          SMPMessage
            { senderMsgId = 0,
              senderTimestamp = senderTs,
              previousMsgHash = "1234", -- TODO hash of the previous message
              agentMessage
            }
  paddedSize <- asks paddedMsgSize
  liftError cryptoError $ C.encrypt encKey paddedSize msg

cryptoError :: C.CryptoError -> AgentErrorType
cryptoError = \case
  C.CryptoLargeMsgError -> CMD LARGE
  e -> INTERNAL $ bshow e
