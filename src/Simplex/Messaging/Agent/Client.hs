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
  )
where

import Control.Logger.Simple
import Control.Monad.Except
import Control.Monad.IO.Unlift
import Control.Monad.Reader
import Control.Monad.Trans.Except
import Data.Bifunctor (first)
import Data.ByteString.Base64
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import Data.Set (Set)
import qualified Data.Set as S
import Data.Text.Encoding
import Data.Time.Clock
import Numeric.Natural
import Simplex.Messaging.Agent.Env.SQLite
import Simplex.Messaging.Agent.Store
import Simplex.Messaging.Agent.Transmission
import Simplex.Messaging.Client
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Protocol (QueueId)
import Simplex.Messaging.Server (randomBytes)
import Simplex.Messaging.Types (ErrorType (AUTH), MsgBody, PrivateKey, PublicKey, SenderKey)
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

newAgentClient :: TVar Int -> Natural -> STM AgentClient
newAgentClient cc qSize = do
  rcvQ <- newTBQueue qSize
  sndQ <- newTBQueue qSize
  msgQ <- newTBQueue qSize
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
      -- TODO how can agent know client lost the connection?
      atomically . modifyTVar smpClients $ M.insert srv smp
      return smp

    connectClient :: m SMPClient
    connectClient = do
      cfg <- asks $ smpCfg . config
      liftIO (getSMPClient srv cfg msgQ clientDisconnected)
        `E.catch` \(_ :: IOException) -> throwError (BROKER smpErrTCPConnection)

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
    runAction smp =
      liftIO (first smpClientError <$> runExceptT (action smp))
        >>= liftEither

    smpClientError :: SMPClientError -> AgentErrorType
    smpClientError = \case
      SMPServerError e -> SMP e
      -- TODO handle other errors
      _ -> INTERNAL

    logServerError :: AgentErrorType -> m a
    logServerError e = do
      logServer "<--" c srv "" $ (B.pack . show) e
      throwError e

withLogSMP :: AgentMonad m => AgentClient -> SMPServer -> QueueId -> ByteString -> (SMPClient -> ExceptT SMPClientError IO a) -> m a
withLogSMP c srv qId cmdStr action = do
  logServer "-->" c srv qId cmdStr
  res <- withSMP c srv action
  logServer "<--" c srv qId "OK"
  return res

newReceiveQueue :: AgentMonad m => AgentClient -> SMPServer -> ConnAlias -> m (ReceiveQueue, SMPQueueInfo)
newReceiveQueue c srv connAlias = do
  g <- asks idsDrg
  size <- asks $ rsaKeySize . config
  (recipientKey, rcvPrivateKey) <- liftIO $ C.generateKeyPair size
  logServer "-->" c srv "" "NEW"
  (rcvId, sId) <- withSMP c srv $ \smp -> createSMPQueue smp rcvPrivateKey recipientKey
  logServer "<--" c srv "" $ B.unwords ["IDS", logSecret rcvId, logSecret sId]
  encryptKey <- atomically $ randomBytes 16 g -- TODO replace with cryptographic key pair
  let decryptKey = encryptKey
      rq =
        ReceiveQueue
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

subscribeQueue :: AgentMonad m => AgentClient -> ReceiveQueue -> ConnAlias -> m ()
subscribeQueue c rq@ReceiveQueue {server, rcvPrivateKey, rcvId} connAlias = do
  withLogSMP c server rcvId "SUB" $ \smp ->
    subscribeSMPQueue smp rcvPrivateKey rcvId
  addSubscription c rq connAlias

addSubscription :: MonadUnliftIO m => AgentClient -> ReceiveQueue -> ConnAlias -> m ()
addSubscription c ReceiveQueue {server} connAlias = atomically $ do
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
  logInfo . decodeUtf8 $ B.unwords ["A", "(" <> (B.pack . show) clientId <> ")", dir, showServer srv, ":", logSecret qId, cmdStr]

showServer :: SMPServer -> ByteString
showServer srv = B.pack $ host srv <> maybe "" (":" <>) (port srv)

logSecret :: ByteString -> ByteString
logSecret bs = encode $ B.take 3 bs

sendConfirmation :: forall m. AgentMonad m => AgentClient -> SendQueue -> SenderKey -> m ()
sendConfirmation c SendQueue {server, sndId} senderKey = do
  msg <- mkConfirmation
  withLogSMP c server sndId "SEND <KEY>" $ \smp ->
    sendSMPMessage smp Nothing sndId msg
  where
    mkConfirmation :: m MsgBody
    mkConfirmation = do
      let msg = serializeSMPMessage $ SMPConfirmation senderKey
      -- TODO encryption
      return msg

sendHello :: forall m. AgentMonad m => AgentClient -> SendQueue -> m ()
sendHello c SendQueue {server, sndId, sndPrivateKey, encryptKey} = do
  msg <- mkHello "5678" $ AckMode On -- TODO verifyKey
  withLogSMP c server sndId "SEND <HELLO> (retrying)" $
    send 20 msg
  where
    mkHello :: PublicKey -> AckMode -> m ByteString
    mkHello verifyKey ackMode =
      mkAgentMessage encryptKey $ HELLO verifyKey ackMode

    send :: Int -> ByteString -> SMPClient -> ExceptT SMPClientError IO ()
    send 0 _ _ = throwE SMPResponseTimeout -- TODO different error
    send retry msg smp =
      sendSMPMessage smp (Just sndPrivateKey) sndId msg `catchE` \case
        SMPServerError AUTH -> do
          threadDelay 100000
          send (retry - 1) msg smp
        e -> throwE e

secureQueue :: AgentMonad m => AgentClient -> ReceiveQueue -> SenderKey -> m ()
secureQueue c ReceiveQueue {server, rcvId, rcvPrivateKey} senderKey =
  withLogSMP c server rcvId "KEY <key>" $ \smp ->
    secureSMPQueue smp rcvPrivateKey rcvId senderKey

sendAck :: AgentMonad m => AgentClient -> ReceiveQueue -> m ()
sendAck c ReceiveQueue {server, rcvId, rcvPrivateKey} =
  withLogSMP c server rcvId "ACK" $ \smp ->
    ackSMPMessage smp rcvPrivateKey rcvId

suspendQueue :: AgentMonad m => AgentClient -> ReceiveQueue -> m ()
suspendQueue c ReceiveQueue {server, rcvId, rcvPrivateKey} =
  withLogSMP c server rcvId "OFF" $ \smp ->
    suspendSMPQueue smp rcvPrivateKey rcvId

deleteQueue :: AgentMonad m => AgentClient -> ReceiveQueue -> m ()
deleteQueue c ReceiveQueue {server, rcvId, rcvPrivateKey} =
  withLogSMP c server rcvId "DEL" $ \smp ->
    deleteSMPQueue smp rcvPrivateKey rcvId

sendAgentMessage :: AgentMonad m => AgentClient -> SendQueue -> AMessage -> m ()
sendAgentMessage c SendQueue {server, sndId, sndPrivateKey, encryptKey} agentMsg = do
  msg <- mkAgentMessage encryptKey agentMsg
  withLogSMP c server sndId "SEND <message>" $ \smp ->
    sendSMPMessage smp (Just sndPrivateKey) sndId msg

mkAgentMessage :: MonadUnliftIO m => PrivateKey -> AMessage -> m ByteString
mkAgentMessage _encKey agentMessage = do
  senderTimestamp <- liftIO getCurrentTime
  let msg =
        serializeSMPMessage
          SMPMessage
            { senderMsgId = 0,
              senderTimestamp,
              previousMsgHash = "1234", -- TODO hash of the previous message
              agentMessage
            }
  -- TODO encryption
  return msg
