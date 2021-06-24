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
    addSubscription,
    sendConfirmation,
    sendHello,
    secureQueue,
    sendAgentMessage,
    decryptAndVerify,
    verifyMessage,
    sendAck,
    suspendQueue,
    deleteQueue,
    logServer,
    removeSubscription,
    cryptoError,
  )
where

import Control.Concurrent.STM (stateTVar)
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
import Simplex.Messaging.Agent.Protocol
import Simplex.Messaging.Agent.Store
import Simplex.Messaging.Agent.Store.SQLite (SQLiteStore)
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
    subQ :: TBQueue (ATransmission 'Agent),
    msgQ :: TBQueue SMPServerTransmission,
    smpClients :: TVar (Map SMPServer SMPClient),
    subscrSrvrs :: TVar (Map SMPServer (Set ConnId)),
    subscrConns :: TVar (Map ConnId SMPServer),
    clientId :: Int,
    store :: SQLiteStore,
    agentEnv :: Env
  }

newAgentClient :: SQLiteStore -> Env -> STM AgentClient
newAgentClient store agentEnv = do
  let qSize = tbqSize $ config agentEnv
  rcvQ <- newTBQueue qSize
  subQ <- newTBQueue qSize
  msgQ <- newTBQueue qSize
  smpClients <- newTVar M.empty
  subscrSrvrs <- newTVar M.empty
  subscrConns <- newTVar M.empty
  clientId <- stateTVar (clientCounter agentEnv) $ \i -> (i + 1, i + 1)
  return AgentClient {rcvQ, subQ, msgQ, smpClients, subscrSrvrs, subscrConns, clientId, store, agentEnv}

-- | Agent monad with MonadReader Env and MonadError AgentErrorType
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
        `E.catch` internalError
      where
        internalError :: IOException -> m SMPClient
        internalError = throwError . INTERNAL . show

    clientDisconnected :: IO ()
    clientDisconnected = do
      removeSubs >>= mapM_ (mapM_ notifySub)
      logInfo . decodeUtf8 $ "Agent disconnected from " <> showServer srv

    removeSubs :: IO (Maybe (Set ConnId))
    removeSubs = atomically $ do
      modifyTVar smpClients $ M.delete srv
      cs <- M.lookup srv <$> readTVar (subscrSrvrs c)
      modifyTVar (subscrSrvrs c) $ M.delete srv
      modifyTVar (subscrConns c) $ maybe id deleteKeys cs
      return cs
      where
        deleteKeys :: Ord k => Set k -> Map k a -> Map k a
        deleteKeys ks m = S.foldr' M.delete m ks

    notifySub :: ConnId -> IO ()
    notifySub connId = atomically $ writeTBQueue (subQ c) ("", connId, END)

closeSMPServerClients :: MonadUnliftIO m => AgentClient -> m ()
closeSMPServerClients c = liftIO $ readTVarIO (smpClients c) >>= mapM_ closeSMPClient

withSMP_ :: forall a m. AgentMonad m => AgentClient -> SMPServer -> (SMPClient -> m a) -> m a
withSMP_ c srv action =
  (getSMPServerClient c srv >>= action) `catchError` logServerError
  where
    logServerError :: AgentErrorType -> m a
    logServerError e = do
      logServer "<--" c srv "" $ bshow e
      throwError e

withLogSMP_ :: AgentMonad m => AgentClient -> SMPServer -> QueueId -> ByteString -> (SMPClient -> m a) -> m a
withLogSMP_ c srv qId cmdStr action = do
  logServer "-->" c srv qId cmdStr
  res <- withSMP_ c srv action
  logServer "<--" c srv qId "OK"
  return res

withSMP :: AgentMonad m => AgentClient -> SMPServer -> (SMPClient -> ExceptT SMPClientError IO a) -> m a
withSMP c srv action = withSMP_ c srv $ liftSMP . action

withLogSMP :: AgentMonad m => AgentClient -> SMPServer -> QueueId -> ByteString -> (SMPClient -> ExceptT SMPClientError IO a) -> m a
withLogSMP c srv qId cmdStr action = withLogSMP_ c srv qId cmdStr $ liftSMP . action

liftSMP :: AgentMonad m => ExceptT SMPClientError IO a -> m a
liftSMP = liftError smpClientError

smpClientError :: SMPClientError -> AgentErrorType
smpClientError = \case
  SMPServerError e -> SMP e
  SMPResponseError e -> BROKER $ RESPONSE e
  SMPUnexpectedResponse -> BROKER UNEXPECTED
  SMPResponseTimeout -> BROKER TIMEOUT
  SMPNetworkError -> BROKER NETWORK
  SMPTransportError e -> BROKER $ TRANSPORT e
  e -> INTERNAL $ show e

newReceiveQueue :: AgentMonad m => AgentClient -> SMPServer -> m (RcvQueue, SMPQueueInfo)
newReceiveQueue c srv = do
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
            rcvPrivateKey,
            sndId = Just sId,
            sndKey = Nothing,
            decryptKey,
            verifyKey = Nothing,
            status = New
          }
  return (rq, SMPQueueInfo srv sId encryptKey)

subscribeQueue :: AgentMonad m => AgentClient -> RcvQueue -> ConnId -> m ()
subscribeQueue c rq@RcvQueue {server, rcvPrivateKey, rcvId} connId = do
  withLogSMP c server rcvId "SUB" $ \smp ->
    subscribeSMPQueue smp rcvPrivateKey rcvId
  addSubscription c rq connId

addSubscription :: MonadUnliftIO m => AgentClient -> RcvQueue -> ConnId -> m ()
addSubscription c RcvQueue {server} connId = atomically $ do
  modifyTVar (subscrConns c) $ M.insert connId server
  modifyTVar (subscrSrvrs c) $ M.alter (Just . addSub) server
  where
    addSub :: Maybe (Set ConnId) -> Set ConnId
    addSub (Just cs) = S.insert connId cs
    addSub _ = S.singleton connId

removeSubscription :: AgentMonad m => AgentClient -> ConnId -> m ()
removeSubscription AgentClient {subscrConns, subscrSrvrs} connId = atomically $ do
  cs <- readTVar subscrConns
  writeTVar subscrConns $ M.delete connId cs
  mapM_
    (modifyTVar subscrSrvrs . M.alter (>>= delSub))
    (M.lookup connId cs)
  where
    delSub :: Set ConnId -> Maybe (Set ConnId)
    delSub cs =
      let cs' = S.delete connId cs
       in if S.null cs' then Nothing else Just cs'

logServer :: AgentMonad m => ByteString -> AgentClient -> SMPServer -> QueueId -> ByteString -> m ()
logServer dir AgentClient {clientId} srv qId cmdStr =
  logInfo . decodeUtf8 $ B.unwords ["A", "(" <> bshow clientId <> ")", dir, showServer srv, ":", logSecret qId, cmdStr]

showServer :: SMPServer -> ByteString
showServer srv = B.pack $ host srv <> maybe "" (":" <>) (port srv)

logSecret :: ByteString -> ByteString
logSecret bs = encode $ B.take 3 bs

sendConfirmation :: forall m. AgentMonad m => AgentClient -> SndQueue -> SenderPublicKey -> ConnInfo -> m ()
sendConfirmation c sq@SndQueue {server, sndId} senderKey cInfo =
  withLogSMP_ c server sndId "SEND <KEY>" $ \smp -> do
    msg <- mkConfirmation smp
    liftSMP $ sendSMPMessage smp Nothing sndId msg
  where
    mkConfirmation :: SMPClient -> m MsgBody
    mkConfirmation smp = encryptAndSign smp sq . serializeSMPMessage $ SMPConfirmation senderKey cInfo

sendHello :: forall m. AgentMonad m => AgentClient -> SndQueue -> VerificationKey -> m ()
sendHello c sq@SndQueue {server, sndId, sndPrivateKey} verifyKey =
  withLogSMP_ c server sndId "SEND <HELLO> (retrying)" $ \smp -> do
    msg <- mkHello smp $ AckMode On
    liftSMP $ send 8 100000 msg smp
  where
    mkHello :: SMPClient -> AckMode -> m ByteString
    mkHello smp ackMode = do
      senderTimestamp <- liftIO getCurrentTime
      encryptAndSign smp sq . serializeSMPMessage $
        SMPMessage
          { senderMsgId = 0,
            senderTimestamp,
            previousMsgHash = "",
            agentMessage = HELLO verifyKey ackMode
          }

    send :: Int -> Int -> ByteString -> SMPClient -> ExceptT SMPClientError IO ()
    send 0 _ _ _ = throwE $ SMPServerError AUTH
    send retry delay msg smp =
      sendSMPMessage smp (Just sndPrivateKey) sndId msg `catchE` \case
        SMPServerError AUTH -> do
          threadDelay delay
          send (retry - 1) (delay * 3 `div` 2) msg smp
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

sendAgentMessage :: AgentMonad m => AgentClient -> SndQueue -> ByteString -> m ()
sendAgentMessage c sq@SndQueue {server, sndId, sndPrivateKey} msg =
  withLogSMP_ c server sndId "SEND <message>" $ \smp -> do
    msg' <- encryptAndSign smp sq msg
    liftSMP $ sendSMPMessage smp (Just sndPrivateKey) sndId msg'

encryptAndSign :: AgentMonad m => SMPClient -> SndQueue -> ByteString -> m ByteString
encryptAndSign smp SndQueue {encryptKey, signKey} msg = do
  paddedSize <- asks $ (blockSize smp -) . reservedMsgSize
  liftError cryptoError $ do
    enc <- C.encrypt encryptKey paddedSize msg
    C.Signature sig <- C.sign signKey enc
    pure $ sig <> enc

decryptAndVerify :: AgentMonad m => RcvQueue -> ByteString -> m ByteString
decryptAndVerify RcvQueue {decryptKey, verifyKey} msg =
  verifyMessage verifyKey msg
    >>= liftError cryptoError . C.decrypt decryptKey

verifyMessage :: AgentMonad m => Maybe VerificationKey -> ByteString -> m ByteString
verifyMessage verifyKey msg = do
  size <- asks $ rsaKeySize . config
  let (sig, enc) = B.splitAt size msg
  case verifyKey of
    Nothing -> pure enc
    Just k
      | C.verify k (C.Signature sig) enc -> pure enc
      | otherwise -> throwError $ AGENT A_SIGNATURE

cryptoError :: C.CryptoError -> AgentErrorType
cryptoError = \case
  C.CryptoLargeMsgError -> CMD LARGE
  C.RSADecryptError _ -> AGENT A_ENCRYPTION
  C.CryptoHeaderError _ -> AGENT A_ENCRYPTION
  C.AESDecryptError -> AGENT A_ENCRYPTION
  e -> INTERNAL $ show e
