{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeApplications #-}

-- |
-- Module      : Simplex.Messaging.Agent
-- Copyright   : (c) simplex.chat
-- License     : AGPL-3
--
-- Maintainer  : chat@simplex.chat
-- Stability   : experimental
-- Portability : non-portable
--
-- This module defines SMP protocol agent with SQLite persistence.
--
-- See https://github.com/simplex-chat/simplexmq/blob/master/protocol/agent-protocol.md
module Simplex.Messaging.Agent
  ( -- * queue-based SMP agent
    getAgentClient,
    runAgentClient,

    -- * SMP agent functional API
    AgentClient (..),
    AgentMonad,
    AgentErrorMonad,
    getSMPAgentClient,
    disconnectAgentClient,
    resumeAgentClient,
    withConnLock,
    createUser,
    deleteUser,
    createConnectionAsync,
    joinConnectionAsync,
    allowConnectionAsync,
    acceptContactAsync,
    ackMessageAsync,
    switchConnectionAsync,
    deleteConnectionAsync,
    deleteConnectionsAsync,
    createConnection,
    joinConnection,
    allowConnection,
    acceptContact,
    rejectContact,
    subscribeConnection,
    subscribeConnections,
    getConnectionMessage,
    getNotificationMessage,
    resubscribeConnection,
    resubscribeConnections,
    sendMessage,
    ackMessage,
    switchConnection,
    stopConnectionSwitch,
    suspendConnection,
    deleteConnection,
    deleteConnections,
    getConnectionServers,
    getConnectionRatchetAdHash,
    setProtocolServers,
    testProtocolServer,
    setNtfServers,
    setNetworkConfig,
    getNetworkConfig,
    registerNtfToken,
    verifyNtfToken,
    checkNtfToken,
    deleteNtfToken,
    getNtfToken,
    getNtfTokenData,
    toggleConnectionNtfs,
    xftpStartWorkers,
    xftpReceiveFile,
    xftpDeleteRcvFile,
    xftpSendFile,
    xftpDeleteSndFileInternal,
    xftpDeleteSndFileRemote,
    foregroundAgent,
    suspendAgent,
    execAgentStoreSQL,
    getAgentMigrations,
    debugAgentLocks,
    getAgentStats,
    resetAgentStats,
    logConnection,
  )
where

import Control.Concurrent.STM (stateTVar)
import Control.Logger.Simple (logError, logInfo, showText)
import Control.Monad.Except
import Control.Monad.IO.Unlift (MonadUnliftIO)
import Control.Monad.Reader
import Crypto.Random (MonadRandom)
import Data.Bifunctor (bimap, first, second)
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.Composition ((.:), (.:.), (.::))
import Data.Foldable (foldl')
import Data.Functor (($>))
import Data.List (find)
import Data.List.NonEmpty (NonEmpty (..), (<|))
import qualified Data.List.NonEmpty as L
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import Data.Maybe (isJust, isNothing)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock
import Data.Time.Clock.System (systemToUTCTime)
import qualified Database.SQLite.Simple as DB
import Simplex.FileTransfer.Agent (closeXFTPAgent, deleteRcvFile, deleteSndFileInternal, deleteSndFileRemote, receiveFile, sendFile, startWorkers, toFSFilePath)
import Simplex.FileTransfer.Description (ValidFileDescription)
import Simplex.FileTransfer.Protocol (FileParty (..))
import Simplex.FileTransfer.Util (removePath)
import Simplex.Messaging.Agent.Client
import Simplex.Messaging.Agent.Env.SQLite
import Simplex.Messaging.Agent.Lock (withLock)
import Simplex.Messaging.Agent.NtfSubSupervisor
import Simplex.Messaging.Agent.Protocol
import Simplex.Messaging.Agent.RetryInterval
import Simplex.Messaging.Agent.Store
import Simplex.Messaging.Agent.Store.SQLite
import qualified Simplex.Messaging.Agent.Store.SQLite.Migrations as Migrations
import Simplex.Messaging.Client (ProtocolClient (..), ServerTransmission)
import qualified Simplex.Messaging.Crypto as C
import qualified Simplex.Messaging.Crypto.Ratchet as CR
import Simplex.Messaging.Encoding
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Notifications.Protocol (DeviceToken, NtfRegCode (NtfRegCode), NtfTknStatus (..), NtfTokenId)
import Simplex.Messaging.Notifications.Server.Push.APNS (PNMessageData (..))
import Simplex.Messaging.Notifications.Types
import Simplex.Messaging.Parsers (parse)
import Simplex.Messaging.Protocol (BrokerMsg, EntityId, ErrorType (AUTH), MsgBody, MsgFlags, NtfServer, ProtoServerWithAuth, ProtocolTypeI (..), SMPMsgMeta, SProtocolType (..), SndPublicVerifyKey, UserProtocol, XFTPServerWithAuth)
import qualified Simplex.Messaging.Protocol as SMP
import qualified Simplex.Messaging.TMap as TM
import Simplex.Messaging.Util
import Simplex.Messaging.Version
import UnliftIO.Async (async, race_)
import UnliftIO.Concurrent (forkFinally, forkIO, threadDelay)
import qualified UnliftIO.Exception as E
import UnliftIO.STM

-- import GHC.Conc (unsafeIOToSTM)

-- | Creates an SMP agent client instance
getSMPAgentClient :: (MonadRandom m, MonadUnliftIO m) => AgentConfig -> InitialAgentServers -> SQLiteStore -> m AgentClient
getSMPAgentClient cfg initServers store =
  liftIO (newSMPAgentEnv cfg store) >>= runReaderT runAgent
  where
    runAgent = do
      c <- getAgentClient initServers
      void $ raceAny_ [subscriber c, runNtfSupervisor c, cleanupManager c] `forkFinally` const (disconnectAgentClient c)
      pure c

disconnectAgentClient :: MonadUnliftIO m => AgentClient -> m ()
disconnectAgentClient c@AgentClient {agentEnv = Env {ntfSupervisor = ns, xftpAgent = xa}} = do
  closeAgentClient c
  closeNtfSupervisor ns
  closeXFTPAgent xa
  logConnection c False

resumeAgentClient :: MonadIO m => AgentClient -> m ()
resumeAgentClient c = atomically $ writeTVar (active c) True

type AgentErrorMonad m = (MonadUnliftIO m, MonadError AgentErrorType m)

createUser :: AgentErrorMonad m => AgentClient -> NonEmpty SMPServerWithAuth -> NonEmpty XFTPServerWithAuth -> m UserId
createUser c = withAgentEnv c .: createUser' c

-- | Delete user record optionally deleting all user's connections on SMP servers
deleteUser :: AgentErrorMonad m => AgentClient -> UserId -> Bool -> m ()
deleteUser c = withAgentEnv c .: deleteUser' c

-- | Create SMP agent connection (NEW command) asynchronously, synchronous response is new connection id
createConnectionAsync :: forall m c. (AgentErrorMonad m, ConnectionModeI c) => AgentClient -> UserId -> ACorrId -> Bool -> SConnectionMode c -> m ConnId
createConnectionAsync c userId corrId enableNtfs cMode = withAgentEnv c $ newConnAsync c userId corrId enableNtfs cMode

-- | Join SMP agent connection (JOIN command) asynchronously, synchronous response is new connection id
joinConnectionAsync :: AgentErrorMonad m => AgentClient -> UserId -> ACorrId -> Bool -> ConnectionRequestUri c -> ConnInfo -> m ConnId
joinConnectionAsync c userId corrId enableNtfs = withAgentEnv c .: joinConnAsync c userId corrId enableNtfs

-- | Allow connection to continue after CONF notification (LET command), no synchronous response
allowConnectionAsync :: AgentErrorMonad m => AgentClient -> ACorrId -> ConnId -> ConfirmationId -> ConnInfo -> m ()
allowConnectionAsync c = withAgentEnv c .:: allowConnectionAsync' c

-- | Accept contact after REQ notification (ACPT command) asynchronously, synchronous response is new connection id
acceptContactAsync :: AgentErrorMonad m => AgentClient -> ACorrId -> Bool -> ConfirmationId -> ConnInfo -> m ConnId
acceptContactAsync c corrId enableNtfs = withAgentEnv c .: acceptContactAsync' c corrId enableNtfs

-- | Acknowledge message (ACK command) asynchronously, no synchronous response
ackMessageAsync :: forall m. AgentErrorMonad m => AgentClient -> ACorrId -> ConnId -> AgentMsgId -> m ()
ackMessageAsync c = withAgentEnv c .:. ackMessageAsync' c

-- | Switch connection to the new receive queue
switchConnectionAsync :: AgentErrorMonad m => AgentClient -> ACorrId -> ConnId -> m ()
switchConnectionAsync c = withAgentEnv c .: switchConnectionAsync' c

-- | Delete SMP agent connection (DEL command) asynchronously, no synchronous response
deleteConnectionAsync :: AgentErrorMonad m => AgentClient -> ConnId -> m ()
deleteConnectionAsync c = withAgentEnv c . deleteConnectionAsync' c

-- -- | Delete SMP agent connections using batch commands asynchronously, no synchronous response
deleteConnectionsAsync :: AgentErrorMonad m => AgentClient -> [ConnId] -> m ()
deleteConnectionsAsync c = withAgentEnv c . deleteConnectionsAsync' c

-- | Create SMP agent connection (NEW command)
createConnection :: AgentErrorMonad m => AgentClient -> UserId -> Bool -> SConnectionMode c -> Maybe CRClientData -> m (ConnId, ConnectionRequestUri c)
createConnection c userId enableNtfs cMode clientData = withAgentEnv c $ newConn c userId "" enableNtfs cMode clientData

-- | Join SMP agent connection (JOIN command)
joinConnection :: AgentErrorMonad m => AgentClient -> UserId -> Bool -> ConnectionRequestUri c -> ConnInfo -> m ConnId
joinConnection c userId enableNtfs = withAgentEnv c .: joinConn c userId "" False enableNtfs

-- | Allow connection to continue after CONF notification (LET command)
allowConnection :: AgentErrorMonad m => AgentClient -> ConnId -> ConfirmationId -> ConnInfo -> m ()
allowConnection c = withAgentEnv c .:. allowConnection' c

-- | Accept contact after REQ notification (ACPT command)
acceptContact :: AgentErrorMonad m => AgentClient -> Bool -> ConfirmationId -> ConnInfo -> m ConnId
acceptContact c enableNtfs = withAgentEnv c .: acceptContact' c "" enableNtfs

-- | Reject contact (RJCT command)
rejectContact :: AgentErrorMonad m => AgentClient -> ConnId -> ConfirmationId -> m ()
rejectContact c = withAgentEnv c .: rejectContact' c

-- | Subscribe to receive connection messages (SUB command)
subscribeConnection :: AgentErrorMonad m => AgentClient -> ConnId -> m ()
subscribeConnection c = withAgentEnv c . subscribeConnection' c

-- | Subscribe to receive connection messages from multiple connections, batching commands when possible
subscribeConnections :: AgentErrorMonad m => AgentClient -> [ConnId] -> m (Map ConnId (Either AgentErrorType ()))
subscribeConnections c = withAgentEnv c . subscribeConnections' c

-- | Get connection message (GET command)
getConnectionMessage :: AgentErrorMonad m => AgentClient -> ConnId -> m (Maybe SMPMsgMeta)
getConnectionMessage c = withAgentEnv c . getConnectionMessage' c

-- | Get connection message for received notification
getNotificationMessage :: AgentErrorMonad m => AgentClient -> C.CbNonce -> ByteString -> m (NotificationInfo, [SMPMsgMeta])
getNotificationMessage c = withAgentEnv c .: getNotificationMessage' c

resubscribeConnection :: AgentErrorMonad m => AgentClient -> ConnId -> m ()
resubscribeConnection c = withAgentEnv c . resubscribeConnection' c

resubscribeConnections :: AgentErrorMonad m => AgentClient -> [ConnId] -> m (Map ConnId (Either AgentErrorType ()))
resubscribeConnections c = withAgentEnv c . resubscribeConnections' c

-- | Send message to the connection (SEND command)
sendMessage :: AgentErrorMonad m => AgentClient -> ConnId -> MsgFlags -> MsgBody -> m AgentMsgId
sendMessage c = withAgentEnv c .:. sendMessage' c

ackMessage :: AgentErrorMonad m => AgentClient -> ConnId -> AgentMsgId -> m ()
ackMessage c = withAgentEnv c .: ackMessage' c

-- | Switch connection to the new receive queue
switchConnection :: AgentErrorMonad m => AgentClient -> ConnId -> m ConnectionStats
switchConnection c = withAgentEnv c . switchConnection' c

-- | Stop switching connection to the new receive queue
stopConnectionSwitch :: AgentErrorMonad m => AgentClient -> ConnId -> m ConnectionStats
stopConnectionSwitch c = withAgentEnv c . stopConnectionSwitch' c

-- | Suspend SMP agent connection (OFF command)
suspendConnection :: AgentErrorMonad m => AgentClient -> ConnId -> m ()
suspendConnection c = withAgentEnv c . suspendConnection' c

-- | Delete SMP agent connection (DEL command)
deleteConnection :: AgentErrorMonad m => AgentClient -> ConnId -> m ()
deleteConnection c = withAgentEnv c . deleteConnection' c

-- | Delete multiple connections, batching commands when possible
deleteConnections :: AgentErrorMonad m => AgentClient -> [ConnId] -> m (Map ConnId (Either AgentErrorType ()))
deleteConnections c = withAgentEnv c . deleteConnections' c

-- | get servers used for connection
getConnectionServers :: AgentErrorMonad m => AgentClient -> ConnId -> m ConnectionStats
getConnectionServers c = withAgentEnv c . getConnectionServers' c

-- | get connection ratchet associated data hash for verification (should match peer AD hash)
getConnectionRatchetAdHash :: AgentErrorMonad m => AgentClient -> ConnId -> m ByteString
getConnectionRatchetAdHash c = withAgentEnv c . getConnectionRatchetAdHash' c

-- | Change servers to be used for creating new queues
setProtocolServers :: forall p m. (ProtocolTypeI p, UserProtocol p, AgentErrorMonad m) => AgentClient -> UserId -> NonEmpty (ProtoServerWithAuth p) -> m ()
setProtocolServers c = withAgentEnv c .: setProtocolServers' c

-- | Test protocol server
testProtocolServer :: forall p m. (ProtocolTypeI p, UserProtocol p, AgentErrorMonad m) => AgentClient -> UserId -> ProtoServerWithAuth p -> m (Maybe ProtocolTestFailure)
testProtocolServer c userId srv = withAgentEnv c $ case protocolTypeI @p of
  SPSMP -> runSMPServerTest c userId srv
  SPXFTP -> runXFTPServerTest c userId srv

setNtfServers :: MonadUnliftIO m => AgentClient -> [NtfServer] -> m ()
setNtfServers c = withAgentEnv c . setNtfServers' c

-- | set SOCKS5 proxy on/off and optionally set TCP timeout
setNetworkConfig :: MonadUnliftIO m => AgentClient -> NetworkConfig -> m ()
setNetworkConfig c cfg' = do
  cfg <- atomically $ do
    swapTVar (useNetworkConfig c) cfg'
  liftIO . when (cfg /= cfg') $ do
    closeProtocolServerClients c smpClients
    closeProtocolServerClients c ntfClients

getNetworkConfig :: AgentErrorMonad m => AgentClient -> m NetworkConfig
getNetworkConfig = readTVarIO . useNetworkConfig

-- | Register device notifications token
registerNtfToken :: AgentErrorMonad m => AgentClient -> DeviceToken -> NotificationsMode -> m NtfTknStatus
registerNtfToken c = withAgentEnv c .: registerNtfToken' c

-- | Verify device notifications token
verifyNtfToken :: AgentErrorMonad m => AgentClient -> DeviceToken -> C.CbNonce -> ByteString -> m ()
verifyNtfToken c = withAgentEnv c .:. verifyNtfToken' c

checkNtfToken :: AgentErrorMonad m => AgentClient -> DeviceToken -> m NtfTknStatus
checkNtfToken c = withAgentEnv c . checkNtfToken' c

deleteNtfToken :: AgentErrorMonad m => AgentClient -> DeviceToken -> m ()
deleteNtfToken c = withAgentEnv c . deleteNtfToken' c

getNtfToken :: AgentErrorMonad m => AgentClient -> m (DeviceToken, NtfTknStatus, NotificationsMode)
getNtfToken c = withAgentEnv c $ getNtfToken' c

getNtfTokenData :: AgentErrorMonad m => AgentClient -> m NtfToken
getNtfTokenData c = withAgentEnv c $ getNtfTokenData' c

-- | Set connection notifications on/off
toggleConnectionNtfs :: AgentErrorMonad m => AgentClient -> ConnId -> Bool -> m ()
toggleConnectionNtfs c = withAgentEnv c .: toggleConnectionNtfs' c

xftpStartWorkers :: AgentErrorMonad m => AgentClient -> Maybe FilePath -> m ()
xftpStartWorkers c = withAgentEnv c . startWorkers c

-- | Receive XFTP file
xftpReceiveFile :: AgentErrorMonad m => AgentClient -> UserId -> ValidFileDescription 'FRecipient -> m RcvFileId
xftpReceiveFile c = withAgentEnv c .: receiveFile c

-- | Delete XFTP rcv file (deletes work files from file system and db records)
xftpDeleteRcvFile :: AgentErrorMonad m => AgentClient -> RcvFileId -> m ()
xftpDeleteRcvFile c = withAgentEnv c . deleteRcvFile c

-- | Send XFTP file
xftpSendFile :: AgentErrorMonad m => AgentClient -> UserId -> FilePath -> Int -> m SndFileId
xftpSendFile c = withAgentEnv c .:. sendFile c

-- | Delete XFTP snd file internally (deletes work files from file system and db records)
xftpDeleteSndFileInternal :: AgentErrorMonad m => AgentClient -> SndFileId -> m ()
xftpDeleteSndFileInternal c = withAgentEnv c . deleteSndFileInternal c

-- | Delete XFTP snd file chunks on servers
xftpDeleteSndFileRemote :: AgentErrorMonad m => AgentClient -> UserId -> SndFileId -> ValidFileDescription 'FSender -> m ()
xftpDeleteSndFileRemote c = withAgentEnv c .:. deleteSndFileRemote c

-- | Activate operations
foregroundAgent :: MonadUnliftIO m => AgentClient -> m ()
foregroundAgent c = withAgentEnv c $ foregroundAgent' c

-- | Suspend operations with max delay to deliver pending messages
suspendAgent :: MonadUnliftIO m => AgentClient -> Int -> m ()
suspendAgent c = withAgentEnv c . suspendAgent' c

execAgentStoreSQL :: AgentErrorMonad m => AgentClient -> Text -> m [Text]
execAgentStoreSQL c = withAgentEnv c . execAgentStoreSQL' c

getAgentMigrations :: AgentErrorMonad m => AgentClient -> m [UpMigration]
getAgentMigrations c = withAgentEnv c $ getAgentMigrations' c

debugAgentLocks :: MonadUnliftIO m => AgentClient -> m AgentLocks
debugAgentLocks c = withAgentEnv c $ debugAgentLocks' c

getAgentStats :: MonadIO m => AgentClient -> m [(AgentStatsKey, Int)]
getAgentStats c = readTVarIO (agentStats c) >>= mapM (\(k, cnt) -> (k,) <$> readTVarIO cnt) . M.assocs

resetAgentStats :: MonadIO m => AgentClient -> m ()
resetAgentStats = atomically . TM.clear . agentStats

withAgentEnv :: AgentClient -> ReaderT Env m a -> m a
withAgentEnv c = (`runReaderT` agentEnv c)

-- | Creates an SMP agent client instance that receives commands and sends responses via 'TBQueue's.
getAgentClient :: AgentMonad' m => InitialAgentServers -> m AgentClient
getAgentClient initServers = ask >>= atomically . newAgentClient initServers

logConnection :: MonadUnliftIO m => AgentClient -> Bool -> m ()
logConnection c connected =
  let event = if connected then "connected to" else "disconnected from"
   in logInfo $ T.unwords ["client", showText (clientId c), event, "Agent"]

-- | Runs an SMP agent instance that receives commands and sends responses via 'TBQueue's.
runAgentClient :: AgentMonad' m => AgentClient -> m ()
runAgentClient c = race_ (subscriber c) (client c)

client :: forall m. AgentMonad' m => AgentClient -> m ()
client c@AgentClient {rcvQ, subQ} = forever $ do
  (corrId, entId, cmd) <- atomically $ readTBQueue rcvQ
  runExceptT (processCommand c (entId, cmd))
    >>= atomically . writeTBQueue subQ . \case
      Left e -> (corrId, entId, APC SAEConn $ ERR e)
      Right (entId', resp) -> (corrId, entId', resp)

-- | execute any SMP agent command
processCommand :: forall m. AgentMonad m => AgentClient -> (EntityId, APartyCmd 'Client) -> m (EntityId, APartyCmd 'Agent)
processCommand c (connId, APC e cmd) =
  second (APC e) <$> case cmd of
    NEW enableNtfs (ACM cMode) -> second (INV . ACR cMode) <$> newConn c userId connId enableNtfs cMode Nothing
    JOIN enableNtfs (ACR _ cReq) connInfo -> (,OK) <$> joinConn c userId connId False enableNtfs cReq connInfo
    LET confId ownCInfo -> allowConnection' c connId confId ownCInfo $> (connId, OK)
    ACPT invId ownCInfo -> (,OK) <$> acceptContact' c connId True invId ownCInfo
    RJCT invId -> rejectContact' c connId invId $> (connId, OK)
    SUB -> subscribeConnection' c connId $> (connId, OK)
    SEND msgFlags msgBody -> (connId,) . MID <$> sendMessage' c connId msgFlags msgBody
    ACK msgId -> ackMessage' c connId msgId $> (connId, OK)
    SWCH -> switchConnection' c connId $> (connId, OK)
    OFF -> suspendConnection' c connId $> (connId, OK)
    DEL -> deleteConnection' c connId $> (connId, OK)
    CHK -> (connId,) . STAT <$> getConnectionServers' c connId
  where
    -- command interface does not support different users
    userId :: UserId
    userId = 1

createUser' :: AgentMonad m => AgentClient -> NonEmpty SMPServerWithAuth -> NonEmpty XFTPServerWithAuth -> m UserId
createUser' c smp xftp = do
  userId <- withStore' c createUserRecord
  atomically $ TM.insert userId smp $ smpServers c
  atomically $ TM.insert userId xftp $ xftpServers c
  pure userId

deleteUser' :: AgentMonad m => AgentClient -> UserId -> Bool -> m ()
deleteUser' c userId delSMPQueues = do
  if delSMPQueues
    then withStore c (`setUserDeleted` userId) >>= deleteConnectionsAsync_ delUser c
    else withStore c (`deleteUserRecord` userId)
  atomically $ TM.delete userId $ smpServers c
  where
    delUser =
      whenM (withStore' c (`deleteUserWithoutConns` userId)) $
        atomically $ writeTBQueue (subQ c) ("", "", APC SAENone $ DEL_USER userId)

newConnAsync :: forall m c. (AgentMonad m, ConnectionModeI c) => AgentClient -> UserId -> ACorrId -> Bool -> SConnectionMode c -> m ConnId
newConnAsync c userId corrId enableNtfs cMode = do
  connId <- newConnNoQueues c userId "" enableNtfs cMode
  enqueueCommand c corrId connId Nothing $ AClientCommand $ APC SAEConn $ NEW enableNtfs (ACM cMode)
  pure connId

newConnNoQueues :: AgentMonad m => AgentClient -> UserId -> ConnId -> Bool -> SConnectionMode c -> m ConnId
newConnNoQueues c userId connId enableNtfs cMode = do
  g <- asks idsDrg
  connAgentVersion <- asks $ maxVersion . smpAgentVRange . config
  let cData = ConnData {userId, connId, connAgentVersion, enableNtfs, duplexHandshake = Nothing, deleted = False} -- connection mode is determined by the accepting agent
  withStore c $ \db -> createNewConn db g cData cMode

joinConnAsync :: AgentMonad m => AgentClient -> UserId -> ACorrId -> Bool -> ConnectionRequestUri c -> ConnInfo -> m ConnId
joinConnAsync c userId corrId enableNtfs cReqUri@(CRInvitationUri ConnReqUriData {crAgentVRange} _) cInfo = do
  aVRange <- asks $ smpAgentVRange . config
  case crAgentVRange `compatibleVersion` aVRange of
    Just (Compatible connAgentVersion) -> do
      g <- asks idsDrg
      let duplexHS = connAgentVersion /= 1
          cData = ConnData {userId, connId = "", connAgentVersion, enableNtfs, duplexHandshake = Just duplexHS, deleted = False}
      connId <- withStore c $ \db -> createNewConn db g cData SCMInvitation
      enqueueCommand c corrId connId Nothing $ AClientCommand $ APC SAEConn $ JOIN enableNtfs (ACR sConnectionMode cReqUri) cInfo
      pure connId
    _ -> throwError $ AGENT A_VERSION
joinConnAsync _c _userId _corrId _enableNtfs (CRContactUri _) _cInfo =
  throwError $ CMD PROHIBITED

allowConnectionAsync' :: AgentMonad m => AgentClient -> ACorrId -> ConnId -> ConfirmationId -> ConnInfo -> m ()
allowConnectionAsync' c corrId connId confId ownConnInfo =
  withStore c (`getConn` connId) >>= \case
    SomeConn _ (RcvConnection _ RcvQueue {server}) ->
      enqueueCommand c corrId connId (Just server) $ AClientCommand $ APC SAEConn $ LET confId ownConnInfo
    _ -> throwError $ CMD PROHIBITED

acceptContactAsync' :: AgentMonad m => AgentClient -> ACorrId -> Bool -> InvitationId -> ConnInfo -> m ConnId
acceptContactAsync' c corrId enableNtfs invId ownConnInfo = do
  Invitation {contactConnId, connReq} <- withStore c (`getInvitation` invId)
  withStore c (`getConn` contactConnId) >>= \case
    SomeConn _ (ContactConnection ConnData {userId} _) -> do
      withStore' c $ \db -> acceptInvitation db invId ownConnInfo
      joinConnAsync c userId corrId enableNtfs connReq ownConnInfo `catchError` \err -> do
        withStore' c (`unacceptInvitation` invId)
        throwError err
    _ -> throwError $ CMD PROHIBITED

ackMessageAsync' :: forall m. AgentMonad m => AgentClient -> ACorrId -> ConnId -> AgentMsgId -> m ()
ackMessageAsync' c corrId connId msgId = do
  SomeConn cType _ <- withStore c (`getConn` connId)
  case cType of
    SCDuplex -> enqueueAck
    SCRcv -> enqueueAck
    SCSnd -> throwError $ CONN SIMPLEX
    SCContact -> throwError $ CMD PROHIBITED
    SCNew -> throwError $ CMD PROHIBITED
  where
    enqueueAck :: m ()
    enqueueAck = do
      (RcvQueue {server}, _) <- withStore c $ \db -> setMsgUserAck db connId $ InternalId msgId
      enqueueCommand c corrId connId (Just server) . AClientCommand $ APC SAEConn $ ACK msgId

deleteConnectionAsync' :: forall m. AgentMonad m => AgentClient -> ConnId -> m ()
deleteConnectionAsync' c connId = deleteConnectionsAsync' c [connId]

deleteConnectionsAsync' :: AgentMonad m => AgentClient -> [ConnId] -> m ()
deleteConnectionsAsync' = deleteConnectionsAsync_ $ pure ()

deleteConnectionsAsync_ :: forall m. AgentMonad m => m () -> AgentClient -> [ConnId] -> m ()
deleteConnectionsAsync_ onSuccess c connIds = case connIds of
  [] -> onSuccess
  _ -> do
    (_, rqs, connIds') <- prepareDeleteConnections_ getConns c connIds
    withStore' c $ forM_ connIds' . setConnDeleted
    void . forkIO $
      withLock (deleteLock c) "deleteConnectionsAsync" $
        deleteConnQueues c True rqs >> onSuccess

-- | Add connection to the new receive queue
switchConnectionAsync' :: AgentMonad m => AgentClient -> ACorrId -> ConnId -> m ()
switchConnectionAsync' c corrId connId =
  withStore c (`getConn` connId) >>= \case
    SomeConn _ (DuplexConnection _ rqs@(rq :| _rqs) _) -> case findSwitchedRQ rqs of
      Nothing -> do
        let queueNotSwitched = \RcvQueue {switchStatus} -> isNothing switchStatus
            updateSwitchStatus = \db q -> setRcvQueueSwitchStatus db q (Just RSSQueueingSwch)
        withExistingRQ c rq queueNotSwitched updateSwitchStatus >>= \case
          Right _replaced' -> enqueueCommand c corrId connId Nothing $ AClientCommand $ APC SAEConn SWCH
          Left qce -> switchCannotProceedErr $ qceStr qce "queue expected to be not switched"
      Just _ -> throwError $ AGENT $ A_QUEUE "connection already switching"
    _ -> throwError $ CMD PROHIBITED

newConn :: AgentMonad m => AgentClient -> UserId -> ConnId -> Bool -> SConnectionMode c -> Maybe CRClientData -> m (ConnId, ConnectionRequestUri c)
newConn c userId connId enableNtfs cMode clientData =
  getSMPServer c userId >>= newConnSrv c userId connId enableNtfs cMode clientData

newConnSrv :: AgentMonad m => AgentClient -> UserId -> ConnId -> Bool -> SConnectionMode c -> Maybe CRClientData -> SMPServerWithAuth -> m (ConnId, ConnectionRequestUri c)
newConnSrv c userId connId enableNtfs cMode clientData srv = do
  connId' <- newConnNoQueues c userId connId enableNtfs cMode
  newRcvConnSrv c userId connId' enableNtfs cMode clientData srv

newRcvConnSrv :: AgentMonad m => AgentClient -> UserId -> ConnId -> Bool -> SConnectionMode c -> Maybe CRClientData -> SMPServerWithAuth -> m (ConnId, ConnectionRequestUri c)
newRcvConnSrv c userId connId enableNtfs cMode clientData srv = do
  AgentConfig {smpClientVRange, smpAgentVRange, e2eEncryptVRange} <- asks config
  (rq, qUri) <- newRcvQueue c userId connId srv smpClientVRange `catchError` \e -> liftIO (print e) >> throwError e
  void . withStore c $ \db -> updateNewConnRcv db connId rq
  addSubscription c rq
  when enableNtfs $ do
    ns <- asks ntfSupervisor
    atomically $ sendNtfSubCommand ns (connId, NSCCreate)
  let crData = ConnReqUriData simplexChat smpAgentVRange [qUri] clientData
  case cMode of
    SCMContact -> pure (connId, CRContactUri crData)
    SCMInvitation -> do
      (pk1, pk2, e2eRcvParams) <- liftIO . CR.generateE2EParams $ maxVersion e2eEncryptVRange
      withStore' c $ \db -> createRatchetX3dhKeys db connId pk1 pk2
      pure (connId, CRInvitationUri crData $ toVersionRangeT e2eRcvParams e2eEncryptVRange)

joinConn :: AgentMonad m => AgentClient -> UserId -> ConnId -> Bool -> Bool -> ConnectionRequestUri c -> ConnInfo -> m ConnId
joinConn c userId connId asyncMode enableNtfs cReq cInfo = do
  srv <- case cReq of
    CRInvitationUri ConnReqUriData {crSmpQueues = q :| _} _ ->
      getNextServer c userId [qServer q]
    _ -> getSMPServer c userId
  joinConnSrv c userId connId asyncMode enableNtfs cReq cInfo srv

joinConnSrv :: AgentMonad m => AgentClient -> UserId -> ConnId -> Bool -> Bool -> ConnectionRequestUri c -> ConnInfo -> SMPServerWithAuth -> m ConnId
joinConnSrv c userId connId asyncMode enableNtfs (CRInvitationUri ConnReqUriData {crAgentVRange, crSmpQueues = (qUri :| _)} e2eRcvParamsUri) cInfo srv = do
  AgentConfig {smpClientVRange, smpAgentVRange, e2eEncryptVRange} <- asks config
  case ( qUri `compatibleVersion` smpClientVRange,
         e2eRcvParamsUri `compatibleVersion` e2eEncryptVRange,
         crAgentVRange `compatibleVersion` smpAgentVRange
       ) of
    (Just qInfo, Just (Compatible e2eRcvParams@(CR.E2ERatchetParams _ _ rcDHRr)), Just aVersion@(Compatible connAgentVersion)) -> do
      (pk1, pk2, e2eSndParams) <- liftIO . CR.generateE2EParams $ version e2eRcvParams
      (_, rcDHRs) <- liftIO C.generateKeyPair'
      let rc = CR.initSndRatchet e2eEncryptVRange rcDHRr rcDHRs $ CR.x3dhSnd pk1 pk2 e2eRcvParams
      q <- newSndQueue userId "" qInfo
      let duplexHS = connAgentVersion /= 1
          cData = ConnData {userId, connId, connAgentVersion, enableNtfs, duplexHandshake = Just duplexHS, deleted = False}
      connId' <- setUpConn asyncMode cData q rc
      let sq = (q :: SndQueue) {connId = connId'}
          cData' = (cData :: ConnData) {connId = connId'}
      tryError (confirmQueue aVersion c cData' sq srv cInfo $ Just e2eSndParams) >>= \case
        Right _ -> do
          unless duplexHS . void $ enqueueMessage c cData' sq SMP.noMsgFlags HELLO
          pure connId'
        Left e -> do
          -- possible improvement: recovery for failure on network timeout, see rfcs/2022-04-20-smp-conf-timeout-recovery.md
          unless asyncMode $ withStore' c (`deleteConn` connId')
          throwError e
      where
        setUpConn True _ sq rc =
          withStore c $ \db -> runExceptT $ do
            void . ExceptT $ updateNewConnSnd db connId sq
            liftIO $ createRatchet db connId rc
            pure connId
        setUpConn False cData sq rc = do
          g <- asks idsDrg
          withStore c $ \db -> runExceptT $ do
            connId' <- ExceptT $ createSndConn db g cData sq
            liftIO $ createRatchet db connId' rc
            pure connId'
    _ -> throwError $ AGENT A_VERSION
joinConnSrv c userId connId False enableNtfs (CRContactUri ConnReqUriData {crAgentVRange, crSmpQueues = (qUri :| _)}) cInfo srv = do
  aVRange <- asks $ smpAgentVRange . config
  clientVRange <- asks $ smpClientVRange . config
  case ( qUri `compatibleVersion` clientVRange,
         crAgentVRange `compatibleVersion` aVRange
       ) of
    (Just qInfo, Just vrsn) -> do
      (connId', cReq) <- newConnSrv c userId connId enableNtfs SCMInvitation Nothing srv
      sendInvitation c userId qInfo vrsn cReq cInfo
      pure connId'
    _ -> throwError $ AGENT A_VERSION
joinConnSrv _c _userId _connId True _enableNtfs (CRContactUri _) _cInfo _srv = do
  throwError $ CMD PROHIBITED

createReplyQueue :: AgentMonad m => AgentClient -> ConnData -> SndQueue -> SMPServerWithAuth -> m SMPQueueInfo
createReplyQueue c ConnData {userId, connId, enableNtfs} SndQueue {smpClientVersion} srv = do
  (rq, qUri) <- newRcvQueue c userId connId srv $ versionToRange smpClientVersion
  let qInfo = toVersionT qUri smpClientVersion
  addSubscription c rq
  void . withStore c $ \db -> upgradeSndConnToDuplex db connId rq
  when enableNtfs $ do
    ns <- asks ntfSupervisor
    atomically $ sendNtfSubCommand ns (connId, NSCCreate)
  pure qInfo

-- | Approve confirmation (LET command) in Reader monad
allowConnection' :: AgentMonad m => AgentClient -> ConnId -> ConfirmationId -> ConnInfo -> m ()
allowConnection' c connId confId ownConnInfo = withConnLock c connId "allowConnection" $ do
  withStore c (`getConn` connId) >>= \case
    SomeConn _ (RcvConnection _ rq@RcvQueue {server, rcvId, e2ePrivKey, smpClientVersion = v}) -> do
      senderKey <- withStore c $ \db -> runExceptT $ do
        AcceptedConfirmation {ratchetState, senderConf = SMPConfirmation {senderKey, e2ePubKey, smpClientVersion = v'}} <- ExceptT $ acceptConfirmation db confId ownConnInfo
        liftIO $ createRatchet db connId ratchetState
        let dhSecret = C.dh' e2ePubKey e2ePrivKey
        liftIO $ setRcvQueueConfirmedE2E db rq dhSecret $ min v v'
        pure senderKey
      enqueueCommand c "" connId (Just server) . AInternalCommand $ ICAllowSecure rcvId senderKey
    _ -> throwError $ CMD PROHIBITED

-- | Accept contact (ACPT command) in Reader monad
acceptContact' :: AgentMonad m => AgentClient -> ConnId -> Bool -> InvitationId -> ConnInfo -> m ConnId
acceptContact' c connId enableNtfs invId ownConnInfo = withConnLock c connId "acceptContact" $ do
  Invitation {contactConnId, connReq} <- withStore c (`getInvitation` invId)
  withStore c (`getConn` contactConnId) >>= \case
    SomeConn _ (ContactConnection ConnData {userId} _) -> do
      withStore' c $ \db -> acceptInvitation db invId ownConnInfo
      joinConn c userId connId False enableNtfs connReq ownConnInfo `catchError` \err -> do
        withStore' c (`unacceptInvitation` invId)
        throwError err
    _ -> throwError $ CMD PROHIBITED

-- | Reject contact (RJCT command) in Reader monad
rejectContact' :: AgentMonad m => AgentClient -> ConnId -> InvitationId -> m ()
rejectContact' c contactConnId invId =
  withStore c $ \db -> deleteInvitation db contactConnId invId

-- | Subscribe to receive connection messages (SUB command) in Reader monad
subscribeConnection' :: AgentMonad m => AgentClient -> ConnId -> m ()
subscribeConnection' c connId = toConnResult connId =<< subscribeConnections' c [connId]

toConnResult :: AgentMonad m => ConnId -> Map ConnId (Either AgentErrorType ()) -> m ()
toConnResult connId rs = case M.lookup connId rs of
  Just (Right ()) -> when (M.size rs > 1) $ logError $ T.pack $ "too many results " <> show (M.size rs)
  Just (Left e) -> throwError e
  _ -> throwError $ INTERNAL $ "no result for connection " <> B.unpack connId

type QCmdResult = (QueueStatus, Either AgentErrorType ())

subscribeConnections' :: forall m. AgentMonad m => AgentClient -> [ConnId] -> m (Map ConnId (Either AgentErrorType ()))
subscribeConnections' _ [] = pure M.empty
subscribeConnections' c connIds = do
  conns :: Map ConnId (Either StoreError SomeConn) <- M.fromList . zip connIds <$> withStore' c (`getConns` connIds)
  let (errs, cs) = M.mapEither id conns
      errs' = M.map (Left . storeError) errs
      (subRs, rcvQs) = M.mapEither rcvQueueOrResult cs
  mapM_ (mapM_ (\(cData, sqs) -> mapM_ (resumeMsgDelivery c cData) sqs) . sndQueue) cs
  mapM_ (resumeConnCmds c) $ M.keys cs
  rcvRs <- connResults <$> subscribeQueues c (concat $ M.elems rcvQs)
  ns <- asks ntfSupervisor
  tkn <- readTVarIO (ntfTkn ns)
  when (instantNotifications tkn) . void . forkIO $ sendNtfCreate ns rcvRs conns
  let rs = M.unions ([errs', subRs, rcvRs] :: [Map ConnId (Either AgentErrorType ())])
  notifyResultError rs
  pure rs
  where
    rcvQueueOrResult :: SomeConn -> Either (Either AgentErrorType ()) [RcvQueue]
    rcvQueueOrResult (SomeConn _ conn) = case conn of
      DuplexConnection _ rqs _ -> Right $ L.toList rqs
      SndConnection _ sq -> Left $ sndSubResult sq
      RcvConnection _ rq -> Right [rq]
      ContactConnection _ rq -> Right [rq]
      NewConnection _ -> Left (Right ())
    sndSubResult :: SndQueue -> Either AgentErrorType ()
    sndSubResult sq = case status (sq :: SndQueue) of
      Confirmed -> Right ()
      Active -> Left $ CONN SIMPLEX
      _ -> Left $ INTERNAL "unexpected queue status"
    connResults :: [(RcvQueue, Either AgentErrorType ())] -> Map ConnId (Either AgentErrorType ())
    connResults = M.map snd . foldl' addResult M.empty
      where
        -- collects results by connection ID
        addResult :: Map ConnId QCmdResult -> (RcvQueue, Either AgentErrorType ()) -> Map ConnId QCmdResult
        addResult rs (RcvQueue {connId, status}, r) = M.alter (combineRes (status, r)) connId rs
        -- combines two results for one connection, by using only Active queues (if there is at least one Active queue)
        combineRes :: QCmdResult -> Maybe QCmdResult -> Maybe QCmdResult
        combineRes r' (Just r) = Just $ if order r <= order r' then r else r'
        combineRes r' _ = Just r'
        order :: QCmdResult -> Int
        order (Active, Right _) = 1
        order (Active, _) = 2
        order (_, Right _) = 3
        order _ = 4
    sendNtfCreate :: NtfSupervisor -> Map ConnId (Either AgentErrorType ()) -> Map ConnId (Either StoreError SomeConn) -> m ()
    sendNtfCreate ns rcvRs conns =
      forM_ (M.assocs rcvRs) $ \case
        (connId, Right _) -> forM_ (M.lookup connId conns) $ \case
          Right (SomeConn _ conn) -> do
            let cmd = if enableNtfs $ connData conn then NSCCreate else NSCDelete
            atomically $ writeTBQueue (ntfSubQ ns) (connId, cmd)
          _ -> pure ()
        _ -> pure ()
    sndQueue :: SomeConn -> Maybe (ConnData, NonEmpty SndQueue)
    sndQueue (SomeConn _ conn) = case conn of
      DuplexConnection cData _ sqs -> Just (cData, sqs)
      SndConnection cData sq -> Just (cData, [sq])
      _ -> Nothing
    notifyResultError :: Map ConnId (Either AgentErrorType ()) -> m ()
    notifyResultError rs = do
      let actual = M.size rs
          expected = length connIds
      when (actual /= expected) . atomically $
        writeTBQueue (subQ c) ("", "", APC SAEConn $ ERR $ INTERNAL $ "subscribeConnections result size: " <> show actual <> ", expected " <> show expected)

resubscribeConnection' :: AgentMonad m => AgentClient -> ConnId -> m ()
resubscribeConnection' c connId = toConnResult connId =<< resubscribeConnections' c [connId]

resubscribeConnections' :: forall m. AgentMonad m => AgentClient -> [ConnId] -> m (Map ConnId (Either AgentErrorType ()))
resubscribeConnections' _ [] = pure M.empty
resubscribeConnections' c connIds = do
  let r = M.fromList . zip connIds . repeat $ Right ()
  connIds' <- filterM (fmap not . atomically . hasActiveSubscription c) connIds
  -- union is left-biased, so results returned by subscribeConnections' take precedence
  (`M.union` r) <$> subscribeConnections' c connIds'

getConnectionMessage' :: AgentMonad m => AgentClient -> ConnId -> m (Maybe SMPMsgMeta)
getConnectionMessage' c connId = do
  whenM (atomically $ hasActiveSubscription c connId) . throwError $ CMD PROHIBITED
  SomeConn _ conn <- withStore c (`getConn` connId)
  case conn of
    DuplexConnection _ (rq :| _) _ -> getQueueMessage c rq
    RcvConnection _ rq -> getQueueMessage c rq
    ContactConnection _ rq -> getQueueMessage c rq
    SndConnection _ _ -> throwError $ CONN SIMPLEX
    NewConnection _ -> throwError $ CMD PROHIBITED

getNotificationMessage' :: forall m. AgentMonad m => AgentClient -> C.CbNonce -> ByteString -> m (NotificationInfo, [SMPMsgMeta])
getNotificationMessage' c nonce encNtfInfo = do
  withStore' c getActiveNtfToken >>= \case
    Just NtfToken {ntfDhSecret = Just dhSecret} -> do
      ntfData <- agentCbDecrypt dhSecret nonce encNtfInfo
      PNMessageData {smpQueue, ntfTs, nmsgNonce, encNMsgMeta} <- liftEither (parse strP (INTERNAL "error parsing PNMessageData") ntfData)
      (ntfConnId, rcvNtfDhSecret) <- withStore c (`getNtfRcvQueue` smpQueue)
      ntfMsgMeta <- (eitherToMaybe . smpDecode <$> agentCbDecrypt rcvNtfDhSecret nmsgNonce encNMsgMeta) `catchError` \_ -> pure Nothing
      maxMsgs <- asks $ ntfMaxMessages . config
      (NotificationInfo {ntfConnId, ntfTs, ntfMsgMeta},) <$> getNtfMessages ntfConnId maxMsgs ntfMsgMeta []
    _ -> throwError $ CMD PROHIBITED
  where
    getNtfMessages ntfConnId maxMs nMeta ms
      | length ms < maxMs =
        getConnectionMessage' c ntfConnId >>= \case
          Just m@SMP.SMPMsgMeta {msgId, msgTs, msgFlags} -> case nMeta of
            Just SMP.NMsgMeta {msgId = msgId', msgTs = msgTs'}
              | msgId == msgId' || msgTs > msgTs' -> pure $ reverse (m : ms)
              | otherwise -> getMsg (m : ms)
            _
              | SMP.notification msgFlags -> pure $ reverse (m : ms)
              | otherwise -> getMsg (m : ms)
          _ -> pure $ reverse ms
      | otherwise = pure $ reverse ms
      where
        getMsg = getNtfMessages ntfConnId maxMs nMeta

-- | Send message to the connection (SEND command) in Reader monad
sendMessage' :: forall m. AgentMonad m => AgentClient -> ConnId -> MsgFlags -> MsgBody -> m AgentMsgId
sendMessage' c connId msgFlags msg = withConnLock c connId "sendMessage" $ do
  SomeConn _ conn <- withStore c (`getConn` connId)
  case conn of
    DuplexConnection cData _ sqs -> enqueueMsgs cData sqs
    SndConnection cData sq -> enqueueMsgs cData [sq]
    _ -> throwError $ CONN SIMPLEX
  where
    enqueueMsgs :: ConnData -> NonEmpty SndQueue -> m AgentMsgId
    enqueueMsgs cData sqs = enqueueMessages c cData sqs msgFlags $ A_MSG msg

-- / async command processing v v v

enqueueCommand :: AgentMonad m => AgentClient -> ACorrId -> ConnId -> Maybe SMPServer -> AgentCommand -> m ()
enqueueCommand c corrId connId server aCommand = do
  resumeSrvCmds c server
  commandId <- withStore c $ \db -> createCommand db corrId connId server aCommand
  queuePendingCommands c server [commandId]

resumeSrvCmds :: forall m. AgentMonad m => AgentClient -> Maybe SMPServer -> m ()
resumeSrvCmds c server =
  unlessM (cmdProcessExists c server) $
    async (runCommandProcessing c server)
      >>= \a -> atomically (TM.insert server a $ asyncCmdProcesses c)

resumeConnCmds :: forall m. AgentMonad m => AgentClient -> ConnId -> m ()
resumeConnCmds c connId =
  unlessM connQueued $
    withStore' c (`getPendingCommands` connId)
      >>= mapM_ (uncurry enqueueConnCmds)
  where
    enqueueConnCmds srv cmdIds = do
      resumeSrvCmds c srv
      queuePendingCommands c srv cmdIds
    connQueued = atomically $ isJust <$> TM.lookupInsert connId True (connCmdsQueued c)

cmdProcessExists :: AgentMonad' m => AgentClient -> Maybe SMPServer -> m Bool
cmdProcessExists c srv = atomically $ TM.member srv (asyncCmdProcesses c)

queuePendingCommands :: AgentMonad' m => AgentClient -> Maybe SMPServer -> [AsyncCmdId] -> m ()
queuePendingCommands c server cmdIds = atomically $ do
  q <- getPendingCommandQ c server
  mapM_ (writeTQueue q) cmdIds

getPendingCommandQ :: AgentClient -> Maybe SMPServer -> STM (TQueue AsyncCmdId)
getPendingCommandQ c server = do
  maybe newMsgQueue pure =<< TM.lookup server (asyncCmdQueues c)
  where
    newMsgQueue = do
      cq <- newTQueue
      TM.insert server cq $ asyncCmdQueues c
      pure cq

runCommandProcessing :: forall m. AgentMonad m => AgentClient -> Maybe SMPServer -> m ()
runCommandProcessing c@AgentClient {subQ} server_ = do
  cq <- atomically $ getPendingCommandQ c server_
  ri <- asks $ messageRetryInterval . config -- different retry interval?
  forever $ do
    atomically $ endAgentOperation c AOSndNetwork
    atomically $ throwWhenInactive c
    cmdId <- atomically $ readTQueue cq
    atomically $ beginAgentOperation c AOSndNetwork
    E.try (withStore c $ \db -> getPendingCommand db cmdId) >>= \case
      Left (e :: E.SomeException) -> atomically $ writeTBQueue subQ ("", "", APC SAEConn $ ERR $ INTERNAL $ show e)
      Right cmd -> processCmd (riFast ri) cmdId cmd
  where
    processCmd :: RetryInterval -> AsyncCmdId -> PendingCommand -> m ()
    processCmd ri cmdId PendingCommand {corrId, userId, connId, command} = case command of
      AClientCommand (APC _ cmd) -> case cmd of
        NEW enableNtfs (ACM cMode) -> noServer $ do
          usedSrvs <- newTVarIO ([] :: [SMPServer])
          tryCommand . withNextSrv c userId usedSrvs [] $ \srv -> do
            (_, cReq) <- newRcvConnSrv c userId connId enableNtfs cMode Nothing srv
            notify $ INV (ACR cMode cReq)
        JOIN enableNtfs (ACR _ cReq@(CRInvitationUri ConnReqUriData {crSmpQueues = q :| _} _)) connInfo -> noServer $ do
          let initUsed = [qServer q]
          usedSrvs <- newTVarIO initUsed
          tryCommand . withNextSrv c userId usedSrvs initUsed $ \srv -> do
            void $ joinConnSrv c userId connId True enableNtfs cReq connInfo srv
            notify OK
        LET confId ownCInfo -> withServer' . tryCommand $ allowConnection' c connId confId ownCInfo >> notify OK
        ACK msgId -> withServer' . tryCommand $ ackMessage' c connId msgId >> notify OK
        SWCH ->
          noServer $
            tryCommand $
              withStore c (`getConn` connId) >>= \case
                SomeConn _ conn@(DuplexConnection _ (replaced :| rqs_) _) ->
                  withSwitchedRQ c replaced RSSQueueingSwch (\db q -> setRcvQueueSwitchStatus db q (Just RSSSwchStarted)) >>= \case
                    Right replaced' -> switchDuplexConnection c conn replaced' rqs_ >>= notify . SWITCH QDRcv SPStarted
                    Left qce -> switchCannotProceedErr $ qceStr qce ("expected switch status " <> show RSSQueueingSwch)
                _ -> throwError $ CMD PROHIBITED
        DEL -> withServer' . tryCommand $ deleteConnection' c connId >> notify OK
        _ -> notify $ ERR $ INTERNAL $ "unsupported async command " <> show (aCommandTag cmd)
      AInternalCommand cmd -> case cmd of
        ICAckDel rId srvMsgId msgId -> withServer $ \srv -> tryWithLock "ICAckDel" $ ack srv rId srvMsgId >> withStore' c (\db -> deleteMsg db connId msgId)
        ICAck rId srvMsgId -> withServer $ \srv -> tryWithLock "ICAck" $ ack srv rId srvMsgId
        ICAllowSecure _rId senderKey -> withServer' . tryWithLock "ICAllowSecure" $ do
          (SomeConn _ conn, AcceptedConfirmation {senderConf, ownConnInfo}) <-
            withStore c $ \db -> runExceptT $ (,) <$> ExceptT (getConn db connId) <*> ExceptT (getAcceptedConfirmation db connId)
          case conn of
            RcvConnection cData rq -> do
              secure rq senderKey
              mapM_ (connectReplyQueues c cData ownConnInfo) (L.nonEmpty $ smpReplyQueues senderConf)
            _ -> throwError $ INTERNAL $ "incorrect connection type " <> show (internalCmdTag cmd)
        ICDuplexSecure _rId senderKey -> withServer' . tryWithLock "ICDuplexSecure" . withDuplexConn $ \(DuplexConnection cData (rq :| _) (sq :| _)) -> do
          secure rq senderKey
          when (duplexHandshake cData == Just True) . void $
            enqueueMessage c cData sq SMP.MsgFlags {notification = True} HELLO
        -- ICDeleteConn is no longer used, but it can be present in old client databases
        ICDeleteConn -> withStore' c (`deleteCommand` cmdId)
        ICQSecure rId senderKey -> do
          withServer $ \srv -> tryWithLock "ICQSecure" . withDuplexConn $ \(DuplexConnection cData rqs sqs) ->
            case findSwitchedRQ rqs of
              Just replaced -> do
                withSwitchedRQ c replaced RSSQueueingSecure (\db q -> setRcvQueueSwitchStatus db q (Just RSSSecureStarted)) >>= \case
                  Left qce -> switchCannotProceedErr $ qceStr qce ("expected switch status " <> show RSSQueueingSecure)
                  Right replaced' -> case find (sameQueue (srv, rId)) rqs of
                    Just rq'@RcvQueue {server, sndId, status} -> when (status == Confirmed) $ do
                      secureQueue c rq' senderKey
                      withStore' c $ \db -> setRcvQueueStatus db rq' Secured
                      let updateSwitchStatus = \db q -> do
                            void $ setRcvQueueSwitchStatus db q (Just RSSQueueingQUSE)
                            getRcvQueuesByConnId db connId
                      withSwitchedRQ c replaced' RSSSecureStarted updateSwitchStatus >>= \case
                        Right (Just rqs') -> do
                          void . enqueueMessages c cData sqs SMP.noMsgFlags $ QUSE [((server, sndId), True)]
                          let conn' = DuplexConnection cData rqs' sqs
                          notify . SWITCH QDRcv SPFinalizing $ connectionStats conn'
                        Right _ -> throwError $ INTERNAL "no rcv queues in connection after processing ICQSecure"
                        Left qce -> switchCannotProceedErr $ qceStr qce ("expected switch status " <> show RSSSecureStarted)
                    _ -> internalErr "ICQSecure: queue address not found in connection"
              Nothing -> internalErr "ICQSecure: no switched queue found"
        ICQDelete rId -> do
          withServer $ \srv -> tryWithLock "ICQDelete" . withDuplexConn $ \(DuplexConnection cData rqs sqs) -> do
            case removeQ (srv, rId) rqs of
              Nothing -> internalErr "ICQDelete: queue address not found in connection"
              Just (replaced@RcvQueue {primary}, rq'' : rqs')
                | primary -> internalErr "ICQDelete: cannot delete primary rcv queue"
                | otherwise ->
                  withSwitchedRQ c replaced RSSQueueingDelete (\db q -> setRcvQueueSwitchStatus db q (Just RSSDeleteStarted)) >>= \case
                    Left qce -> switchCannotProceedErr $ qceStr qce ("expected switch status " <> show RSSQueueingDelete)
                    Right replaced' ->
                      tryError (deleteQueue c replaced') >>= \case
                        Left e
                          | temporaryOrHostError e -> throwError e
                          | otherwise -> finalizeSwitch replaced' >> throwError e
                        Right () -> finalizeSwitch replaced'
                where
                  finalizeSwitch replaced' = do
                    withStore' c $ \db -> deleteConnRcvQueue db replaced'
                    when (enableNtfs cData) $ do
                      ns <- asks ntfSupervisor
                      atomically $ sendNtfSubCommand ns (connId, NSCCreate)
                    let conn' = DuplexConnection cData (rq'' :| rqs') sqs
                    notify $ SWITCH QDRcv SPCompleted $ connectionStats conn'
              _ -> internalErr "ICQDelete: cannot delete the only queue in connection"
        where
          ack srv rId srvMsgId = do
            rq <- withStore c $ \db -> getRcvQueue db connId srv rId
            ackQueueMessage c rq srvMsgId
          secure :: RcvQueue -> SMP.SndPublicVerifyKey -> m ()
          secure rq senderKey = do
            secureQueue c rq senderKey
            withStore' c $ \db -> setRcvQueueStatus db rq Secured
      where
        withServer a = case server_ of
          Just srv -> a srv
          _ -> internalErr "command requires server"
        withServer' = withServer . const
        noServer a = case server_ of
          Nothing -> a
          _ -> internalErr "command requires no server"
        withDuplexConn :: (Connection 'CDuplex -> m ()) -> m ()
        withDuplexConn a =
          withStore c (`getConn` connId) >>= \case
            SomeConn _ conn@DuplexConnection {} -> a conn
            _ -> internalErr "command requires duplex connection"
        tryCommand action = withRetryInterval ri $ \_ loop ->
          tryError action >>= \case
            Left e
              | temporaryOrHostError e -> retrySndOp c loop
              | otherwise -> cmdError e
            Right () -> withStore' c (`deleteCommand` cmdId)
        tryWithLock name = tryCommand . withConnLock c connId name
        internalErr s = cmdError $ INTERNAL $ s <> ": " <> show (agentCommandTag command)
        cmdError e = notify (ERR e) >> withStore' c (`deleteCommand` cmdId)
        notify :: forall e. AEntityI e => ACommand 'Agent e -> m ()
        notify cmd = atomically $ writeTBQueue subQ (corrId, connId, APC (sAEntity @e) cmd)
-- ^ ^ ^ async command processing /

enqueueMessages :: AgentMonad m => AgentClient -> ConnData -> NonEmpty SndQueue -> MsgFlags -> AMessage -> m AgentMsgId
enqueueMessages c cData (sq :| sqs) msgFlags aMessage = do
  msgId <- enqueueMessage c cData sq msgFlags aMessage
  mapM_ (enqueueSavedMessage c cData msgId) $
    filter (\SndQueue {status} -> status == Secured || status == Active) sqs
  pure msgId

enqueueMessage :: forall m. AgentMonad m => AgentClient -> ConnData -> SndQueue -> MsgFlags -> AMessage -> m AgentMsgId
enqueueMessage c cData@ConnData {connId, connAgentVersion} sq msgFlags aMessage = do
  resumeMsgDelivery c cData sq
  msgId <- storeSentMsg
  queuePendingMsgs c sq [msgId]
  pure $ unId msgId
  where
    storeSentMsg :: m InternalId
    storeSentMsg = withStore c $ \db -> runExceptT $ do
      internalTs <- liftIO getCurrentTime
      (internalId, internalSndId, prevMsgHash) <- liftIO $ updateSndIds db connId
      let privHeader = APrivHeader (unSndId internalSndId) prevMsgHash
          agentMsg = AgentMessage privHeader aMessage
          agentMsgStr = smpEncode agentMsg
          internalHash = C.sha256Hash agentMsgStr
      encAgentMessage <- agentRatchetEncrypt db connId agentMsgStr e2eEncUserMsgLength
      let msgBody = smpEncode $ AgentMsgEnvelope {agentVersion = connAgentVersion, encAgentMessage}
          msgType = agentMessageType agentMsg
          msgData = SndMsgData {internalId, internalSndId, internalTs, msgType, msgFlags, msgBody, internalHash, prevMsgHash}
      liftIO $ createSndMsg db connId msgData
      liftIO $ createSndMsgDelivery db connId sq internalId
      pure internalId

enqueueSavedMessage :: AgentMonad m => AgentClient -> ConnData -> AgentMsgId -> SndQueue -> m ()
enqueueSavedMessage c cData@ConnData {connId} msgId sq = do
  resumeMsgDelivery c cData sq
  let mId = InternalId msgId
  queuePendingMsgs c sq [mId]
  withStore' c $ \db -> createSndMsgDelivery db connId sq mId

resumeMsgDelivery :: forall m. AgentMonad m => AgentClient -> ConnData -> SndQueue -> m ()
resumeMsgDelivery c cData@ConnData {connId} sq@SndQueue {server, sndId} = do
  let qKey = (server, sndId)
  unlessM (queueDelivering qKey) $
    async (runSmpQueueMsgDelivery c cData sq)
      >>= \a -> atomically (TM.insert qKey a $ smpQueueMsgDeliveries c)
  unlessM msgsQueued $
    withStore' c (\db -> getPendingMsgs db connId sq)
      >>= queuePendingMsgs c sq
  where
    queueDelivering qKey = atomically $ TM.member qKey (smpQueueMsgDeliveries c)
    msgsQueued = atomically $ isJust <$> TM.lookupInsert (server, sndId) True (pendingMsgsQueued c)

queuePendingMsgs :: AgentMonad' m => AgentClient -> SndQueue -> [InternalId] -> m ()
queuePendingMsgs c sq msgIds = atomically $ do
  modifyTVar' (msgDeliveryOp c) $ \s -> s {opsInProgress = opsInProgress s + length msgIds}
  -- s <- readTVar (msgDeliveryOp c)
  -- unsafeIOToSTM $ putStrLn $ "msgDeliveryOp: " <> show (opsInProgress s)
  (mq, _) <- getPendingMsgQ c sq
  mapM_ (writeTQueue mq) msgIds

getPendingMsgQ :: AgentClient -> SndQueue -> STM (TQueue InternalId, TMVar ())
getPendingMsgQ c SndQueue {server, sndId} = do
  let qKey = (server, sndId)
  maybe (newMsgQueue qKey) pure =<< TM.lookup qKey (smpQueueMsgQueues c)
  where
    newMsgQueue qKey = do
      q <- (,) <$> newTQueue <*> newEmptyTMVar
      TM.insert qKey q $ smpQueueMsgQueues c
      pure q

runSmpQueueMsgDelivery :: forall m. AgentMonad m => AgentClient -> ConnData -> SndQueue -> m ()
runSmpQueueMsgDelivery c@AgentClient {subQ} cData@ConnData {userId, connId, duplexHandshake} sq = do
  (mq, qLock) <- atomically $ getPendingMsgQ c sq
  ri <- asks $ messageRetryInterval . config
  forever $ do
    atomically $ endAgentOperation c AOSndNetwork
    atomically $ throwWhenInactive c
    atomically $ throwWhenNoDelivery c sq
    msgId <- atomically $ readTQueue mq
    atomically $ beginAgentOperation c AOSndNetwork
    atomically $ endAgentOperation c AOMsgDelivery -- this operation begins in queuePendingMsgs
    let mId = unId msgId
    E.try (withStore c $ \db -> getPendingMsgData db connId msgId) >>= \case
      Left (e :: E.SomeException) ->
        notify $ MERR mId (INTERNAL $ show e)
      Right (rq_, PendingMsgData {msgType, msgBody, msgFlags, msgRetryState, internalTs}) -> do
        let ri' = maybe id updateRetryInterval2 msgRetryState ri
        withRetryLock2 ri' qLock $ \riState loop -> do
          resp <- tryError $ case msgType of
            AM_CONN_INFO -> sendConfirmation c sq msgBody
            _ -> sendAgentMessage c sq msgFlags msgBody
          case resp of
            Left e -> do
              let err = if msgType == AM_A_MSG_ then MERR mId e else ERR e
              case e of
                SMP SMP.QUOTA -> case msgType of
                  AM_CONN_INFO -> connError msgId NOT_AVAILABLE
                  AM_CONN_INFO_REPLY -> connError msgId NOT_AVAILABLE
                  _ -> retrySndMsg RISlow
                SMP SMP.AUTH -> case msgType of
                  AM_CONN_INFO -> connError msgId NOT_AVAILABLE
                  AM_CONN_INFO_REPLY -> connError msgId NOT_AVAILABLE
                  AM_HELLO_
                    -- in duplexHandshake mode (v2) HELLO is only sent once, without retrying,
                    -- because the queue must be secured by the time the confirmation or the first HELLO is received
                    | duplexHandshake == Just True -> connErr
                    | otherwise ->
                      ifM (msgExpired helloTimeout) connErr (retrySndMsg RIFast)
                    where
                      connErr = case rq_ of
                        -- party initiating connection
                        Just _ -> connError msgId NOT_AVAILABLE
                        -- party joining connection
                        _ -> connError msgId NOT_ACCEPTED
                  AM_REPLY_ -> notifyDel msgId err
                  AM_A_MSG_ -> notifyDel msgId err
                  AM_QCONT_ -> notifyDel msgId err
                  AM_QADD_ -> qError msgId "QADD: AUTH"
                  AM_QKEY_ -> qError msgId "QKEY: AUTH"
                  AM_QUSE_ -> qError msgId "QUSE: AUTH"
                  AM_QTEST_ -> qError msgId "QTEST: AUTH"
                _
                  -- for other operations BROKER HOST is treated as a permanent error (e.g., when connecting to the server),
                  -- the message sending would be retried
                  | temporaryOrHostError e -> do
                    let timeoutSel = if msgType == AM_HELLO_ then helloTimeout else messageTimeout
                    ifM (msgExpired timeoutSel) (notifyDel msgId err) (retrySndMsg RIFast)
                  | otherwise -> notifyDel msgId err
              where
                msgExpired timeoutSel = do
                  msgTimeout <- asks $ timeoutSel . config
                  currentTime <- liftIO getCurrentTime
                  pure $ diffUTCTime currentTime internalTs > msgTimeout
                retrySndMsg riMode = do
                  withStore' c $ \db -> updatePendingMsgRIState db connId msgId riState
                  retrySndOp c $ loop riMode
            Right () -> do
              case msgType of
                AM_CONN_INFO -> do
                  withStore' c $ \db -> do
                    setSndQueueStatus db sq Confirmed
                    when (isJust rq_) $ removeConfirmations db connId
                  unless (duplexHandshake == Just True) . void $ enqueueMessage c cData sq SMP.noMsgFlags HELLO
                AM_CONN_INFO_REPLY -> pure ()
                AM_REPLY_ -> pure ()
                AM_HELLO_ -> do
                  withStore' c $ \db -> setSndQueueStatus db sq Active
                  case rq_ of
                    -- party initiating connection (in v1)
                    Just RcvQueue {status} ->
                      -- it is unclear why subscribeQueue was needed here,
                      -- message delivery can only be enabled for queues that were created in the current session or subscribed
                      -- subscribeQueue c rq connId
                      --
                      -- If initiating party were to send CON to the user without waiting for reply HELLO (to reduce handshake time),
                      -- it would lead to the non-deterministic internal ID of the first sent message, at to some other race conditions,
                      -- because it can be sent before HELLO is received
                      -- With `status == Active` condition, CON is sent here only by the accepting party, that previously received HELLO
                      when (status == Active) $ notify CON
                    -- Party joining connection sends REPLY after HELLO in v1,
                    -- it is an error to send REPLY in duplexHandshake mode (v2),
                    -- and this branch should never be reached as receive is created before the confirmation,
                    -- so the condition is not necessary here, strictly speaking.
                    _ -> unless (duplexHandshake == Just True) $ do
                      srv <- getSMPServer c userId
                      qInfo <- createReplyQueue c cData sq srv
                      void . enqueueMessage c cData sq SMP.noMsgFlags $ REPLY [qInfo]
                AM_A_MSG_ -> notify $ SENT mId
                AM_QCONT_ -> pure ()
                AM_QADD_ -> pure ()
                AM_QKEY_ -> pure ()
                AM_QUSE_ -> pure ()
                AM_QTEST_ -> do
                  withStore' c $ \db -> setSndQueueStatus db sq Active
                  SomeConn _ conn <- withStore c (`getConn` connId)
                  case conn of
                    DuplexConnection cData' rqs sqs -> do
                      -- remove old snd queue from connection once QTEST is sent to the new queue
                      let addr = qAddress sq
                      case findQ addr sqs of
                        -- this is the same queue where this loop delivers messages to but with updated state
                        Just SndQueue {dbReplaceQueueId = Just replacedId, primary} ->
                          -- second part of this condition is a sanity check because dbReplaceQueueId cannot point to the same queue, see switchConnection'
                          case removeQP (\replaced@SndQueue {dbQueueId} -> dbQueueId == replacedId && not (sameQueue addr replaced)) sqs of
                            Nothing -> internalErr msgId "sent QTEST: queue not found in connection"
                            Just (replaced, sq' : sqs') -> do
                              withSwitchedSQ c replaced SSSQueueingQTEST (\db q -> setSndQueueSwitchStatus db q (Just SSSSentQTEST)) >>= \case
                                Left qce -> switchCannotProceedErr $ qceStr qce ("expected switch status " <> show SSSQueueingQTEST)
                                Right replaced' -> do
                                  let deleteSwitchedQueue = \db _ -> do
                                        when primary $ setSndQueuePrimary db connId sq
                                        deletePendingMsgs db connId replaced'
                                        deleteConnSndQueue db connId replaced'
                                  -- the only condition we will not proceed to delete switched queue
                                  -- is if switching queue was already deleted from db
                                  withExistingSQ c sq' (const True) deleteSwitchedQueue >>= \case
                                    Left qce -> switchCannotProceedErr $ qceStr qce "no predicate"
                                    Right () -> do
                                      atomically $ TM.delete (qAddress replaced') $ smpQueueMsgQueues c
                                      let sqs'' = sq' :| sqs'
                                          conn' = DuplexConnection cData' rqs sqs''
                                      notify . SWITCH QDSnd SPCompleted $ connectionStats conn'
                            _ -> internalErr msgId "sent QTEST: there is only one queue in connection"
                        _ -> internalErr msgId "sent QTEST: queue not in connection or not replacing another queue"
                    _ -> internalErr msgId "QTEST sent not in duplex connection"
              delMsg msgId
  where
    delMsg :: InternalId -> m ()
    delMsg msgId = withStore' c $ \db -> deleteSndMsgDelivery db connId sq msgId
    notify :: forall e. AEntityI e => ACommand 'Agent e -> m ()
    notify cmd = atomically $ writeTBQueue subQ ("", connId, APC (sAEntity @e) cmd)
    notifyDel :: AEntityI e => InternalId -> ACommand 'Agent e -> m ()
    notifyDel msgId cmd = notify cmd >> delMsg msgId
    connError msgId = notifyDel msgId . ERR . CONN
    qError msgId = notifyDel msgId . ERR . AGENT . A_QUEUE
    internalErr msgId = notifyDel msgId . ERR . INTERNAL

retrySndOp :: AgentMonad m => AgentClient -> m () -> m ()
retrySndOp c loop = do
  -- end... is in a separate atomically because if begin... blocks, SUSPENDED won't be sent
  atomically $ endAgentOperation c AOSndNetwork
  atomically $ throwWhenInactive c
  atomically $ beginAgentOperation c AOSndNetwork
  loop

ackMessage' :: forall m. AgentMonad m => AgentClient -> ConnId -> AgentMsgId -> m ()
ackMessage' c connId msgId = withConnLock c connId "ackMessage" $ do
  SomeConn _ conn <- withStore c (`getConn` connId)
  case conn of
    DuplexConnection {} -> ack
    RcvConnection {} -> ack
    SndConnection {} -> throwError $ CONN SIMPLEX
    ContactConnection {} -> throwError $ CMD PROHIBITED
    NewConnection _ -> throwError $ CMD PROHIBITED
  where
    ack :: m ()
    ack = do
      let mId = InternalId msgId
      (rq, srvMsgId) <- withStore c $ \db -> setMsgUserAck db connId mId
      ackQueueMessage c rq srvMsgId
      withStore' c $ \db -> deleteMsg db connId mId

switchConnection' :: AgentMonad m => AgentClient -> ConnId -> m ConnectionStats
switchConnection' c connId =
  withStore c (`getConn` connId) >>= \case
    SomeConn _ conn@(DuplexConnection _ rqs@(replaced :| rqs_) _) -> case findSwitchedRQ rqs of
      Nothing -> do
        let queueNotSwitched = \RcvQueue {switchStatus} -> isNothing switchStatus
            updateSwitchStatus = \db q -> setRcvQueueSwitchStatus db q (Just RSSSwchStarted)
        withExistingRQ c replaced queueNotSwitched updateSwitchStatus >>= \case
          Right replaced' -> switchDuplexConnection c conn replaced' rqs_
          Left qce -> switchCannotProceedErr $ qceStr qce "queue expected to be not switched"
      Just _ -> throwError $ AGENT $ A_QUEUE "connection already switching"
    _ -> throwError $ CMD PROHIBITED

switchDuplexConnection :: AgentMonad m => AgentClient -> Connection 'CDuplex -> RcvQueue -> [RcvQueue] -> m ConnectionStats
switchDuplexConnection c (DuplexConnection cData@ConnData {connId, userId} rqs sqs) replaced@RcvQueue {server, dbQueueId, sndId} rqs_ =
  withConnLock c connId "switchConnection" $ do
    clientVRange <- asks $ smpClientVRange . config
    -- try to get the server that is different from all queues, or at least from the primary rcv queue
    srvAuth@(ProtoServerWithAuth srv _) <- getNextServer c userId $ map qServer (L.toList rqs) <> map qServer (L.toList sqs)
    srv' <- if srv == server then getNextServer c userId [server] else pure srvAuth
    (newQ, qUri) <- newRcvQueue c userId connId srv' clientVRange
    let rq' = (newQ :: RcvQueue) {primary = True, dbReplaceQueueId = Just dbQueueId}
        addQueueUpdateSwitchStatus = \db q -> do
          void $ addConnRcvQueue db connId rq'
          void $ setRcvQueueSwitchStatus db q (Just RSSQueueingQADD)
          getRcvQueuesByConnId db connId
    withSwitchedRQ c replaced RSSSwchStarted addQueueUpdateSwitchStatus >>= \case
      Right (Just rqs') -> do
        addSubscription c rq'
        void . enqueueMessages c cData sqs SMP.noMsgFlags $ QADD [(qUri, Just (server, sndId))]
        pure . connectionStats $ DuplexConnection cData rqs' sqs
      Right _ -> throwError $ INTERNAL "no rcv queues in connection after processing switchDuplexConnection"
      Left qce -> do
        deleteQueue c rq' `catchError` \_ -> pure ()
        switchCannotProceedErr $ qceStr qce ("expected switch status " <> show RSSSwchStarted)

stopConnectionSwitch' :: AgentMonad m => AgentClient -> ConnId -> m ConnectionStats
stopConnectionSwitch' c connId = do
  withStore c (`getConn` connId) >>= \case
    SomeConn _ (DuplexConnection cData rqs sqs) -> case findSwitchedRQ rqs of
      Just replaced -> do
        let stopSwitch = \db q@RcvQueue {dbQueueId} -> do
              -- multiple switching queues were possible when repeating switch while in progress was allowed
              switchingQueues <- getSwitchingRcvQueues db dbQueueId
              forM_ switchingQueues $ \switchingQ -> deleteConnRcvQueue db switchingQ
              void $ setRcvQueueSwitchStatus db q Nothing
              rqs' <- getRcvQueuesByConnId db connId
              pure (rqs', switchingQueues)
        withExistingRQ c replaced canStopRcvSwitch stopSwitch >>= \case
          Right (Just rqs', switchingQueues) -> do
            forM_ switchingQueues $ \q -> deleteQueue c q `catchError` \_ -> pure ()
            let conn' = DuplexConnection cData rqs' sqs
            pure $ connectionStats conn'
          Right _ -> throwError $ INTERNAL "no rcv queues in connection after stopping switch"
          Left qce -> throwError $ AGENT $ A_QUEUE $ "cannot proceed with switch stop, " <> qceStr qce "switch cannot be stopped"
      Nothing -> throwError $ AGENT $ A_QUEUE "connection not switching"
    _ -> throwError $ CMD PROHIBITED

canStopRcvSwitch :: RcvQueue -> Bool
canStopRcvSwitch RcvQueue {switchStatus} = case switchStatus of
  Just ss -> case ss of
    RSSQueueingSwch -> True
    RSSSwchStarted -> True
    RSSQueueingQADD -> True
    RSSReceivedQKEY -> True
    RSSQueueingSecure -> True
    RSSSecureStarted -> True
    -- if switch is in RSSQueueingQUSE, a race condition with sender deleting the original queue is possible
    RSSQueueingQUSE -> False
    -- if switch is in RSSQueueingDelete status or past it, stopping switch (deleting new queue)
    -- will break the connection because the sender would have original queue deleted
    RSSQueueingDelete -> False
    RSSDeleteStarted -> False
  Nothing -> False

ackQueueMessage :: AgentMonad m => AgentClient -> RcvQueue -> SMP.MsgId -> m ()
ackQueueMessage c rq srvMsgId =
  sendAck c rq srvMsgId `catchError` \case
    SMP SMP.NO_MSG -> pure ()
    e -> throwError e

-- | Suspend SMP agent connection (OFF command) in Reader monad
suspendConnection' :: AgentMonad m => AgentClient -> ConnId -> m ()
suspendConnection' c connId = withConnLock c connId "suspendConnection" $ do
  SomeConn _ conn <- withStore c (`getConn` connId)
  case conn of
    DuplexConnection _ rqs _ -> mapM_ (suspendQueue c) rqs
    RcvConnection _ rq -> suspendQueue c rq
    ContactConnection _ rq -> suspendQueue c rq
    SndConnection _ _ -> throwError $ CONN SIMPLEX
    NewConnection _ -> throwError $ CMD PROHIBITED

-- | Delete SMP agent connection (DEL command) in Reader monad
-- unlike deleteConnectionAsync, this function does not mark connection as deleted in case of deletion failure
-- currently it is used only in tests
deleteConnection' :: forall m. AgentMonad m => AgentClient -> ConnId -> m ()
deleteConnection' c connId = toConnResult connId =<< deleteConnections' c [connId]

connRcvQueues :: Connection d -> [RcvQueue]
connRcvQueues = \case
  DuplexConnection _ rqs _ -> L.toList rqs
  RcvConnection _ rq -> [rq]
  ContactConnection _ rq -> [rq]
  SndConnection _ _ -> []
  NewConnection _ -> []

disableConn :: AgentMonad m => AgentClient -> ConnId -> m ()
disableConn c connId = do
  atomically $ removeSubscription c connId
  ns <- asks ntfSupervisor
  atomically $ writeTBQueue (ntfSubQ ns) (connId, NSCDelete)

-- Unlike deleteConnectionsAsync, this function does not mark connections as deleted in case of deletion failure.
deleteConnections' :: forall m. AgentMonad m => AgentClient -> [ConnId] -> m (Map ConnId (Either AgentErrorType ()))
deleteConnections' = deleteConnections_ getConns False

deleteDeletedConns :: forall m. AgentMonad m => AgentClient -> [ConnId] -> m (Map ConnId (Either AgentErrorType ()))
deleteDeletedConns = deleteConnections_ getDeletedConns True

prepareDeleteConnections_ ::
  forall m.
  AgentMonad m =>
  (DB.Connection -> [ConnId] -> IO [Either StoreError SomeConn]) ->
  AgentClient ->
  [ConnId] ->
  m (Map ConnId (Either AgentErrorType ()), [RcvQueue], [ConnId])
prepareDeleteConnections_ getConnections c connIds = do
  conns :: Map ConnId (Either StoreError SomeConn) <- M.fromList . zip connIds <$> withStore' c (`getConnections` connIds)
  let (errs, cs) = M.mapEither id conns
      errs' = M.map (Left . storeError) errs
      (delRs, rcvQs) = M.mapEither rcvQueues cs
      rqs = concat $ M.elems rcvQs
      connIds' = M.keys rcvQs
  forM_ connIds' $ disableConn c
  withStore' c $ forM_ (M.keys delRs) . deleteConn
  pure (errs' <> delRs, rqs, connIds')
  where
    rcvQueues :: SomeConn -> Either (Either AgentErrorType ()) [RcvQueue]
    rcvQueues (SomeConn _ conn) = case connRcvQueues conn of
      [] -> Left $ Right ()
      rqs -> Right rqs

deleteConnQueues :: forall m. AgentMonad m => AgentClient -> Bool -> [RcvQueue] -> m (Map ConnId (Either AgentErrorType ()))
deleteConnQueues c ntf rqs = do
  rs <- connResults <$> (deleteQueueRecs =<< deleteQueues c rqs)
  forM_ (M.assocs rs) $ \case
    (connId, Right _) -> withStore' c (`deleteConn` connId) >> notify ("", connId, APC SAEConn DEL_CONN)
    _ -> pure ()
  pure rs
  where
    deleteQueueRecs :: [(RcvQueue, Either AgentErrorType ())] -> m [(RcvQueue, Either AgentErrorType ())]
    deleteQueueRecs rs = do
      maxErrs <- asks $ deleteErrorCount . config
      forM rs $ \(rq, r) -> do
        r' <- case r of
          Right _ -> withStore' c (`deleteConnRcvQueue` rq) >> notifyRQ rq Nothing $> r
          Left e
            | temporaryOrHostError e && deleteErrors rq + 1 < maxErrs -> withStore' c (`incRcvDeleteErrors` rq) $> r
            | otherwise -> withStore' c (`deleteConnRcvQueue` rq) >> notifyRQ rq (Just e) $> Right ()
        pure (rq, r')
    notifyRQ rq e_ = notify ("", qConnId rq, APC SAEConn $ DEL_RCVQ (qServer rq) (queueId rq) e_)
    notify = when ntf . atomically . writeTBQueue (subQ c)
    connResults :: [(RcvQueue, Either AgentErrorType ())] -> Map ConnId (Either AgentErrorType ())
    connResults = M.map snd . foldl' addResult M.empty
      where
        -- collects results by connection ID
        addResult :: Map ConnId QCmdResult -> (RcvQueue, Either AgentErrorType ()) -> Map ConnId QCmdResult
        addResult rs (RcvQueue {connId, status}, r) = M.alter (combineRes (status, r)) connId rs
        -- combines two results for one connection, by prioritizing errors in Active queues
        combineRes :: QCmdResult -> Maybe QCmdResult -> Maybe QCmdResult
        combineRes r' (Just r) = Just $ if order r <= order r' then r else r'
        combineRes r' _ = Just r'
        order :: QCmdResult -> Int
        order (Active, Left _) = 1
        order (_, Left _) = 2
        order _ = 3

deleteConnections_ ::
  forall m.
  AgentMonad m =>
  (DB.Connection -> [ConnId] -> IO [Either StoreError SomeConn]) ->
  Bool ->
  AgentClient ->
  [ConnId] ->
  m (Map ConnId (Either AgentErrorType ()))
deleteConnections_ _ _ _ [] = pure M.empty
deleteConnections_ getConnections ntf c connIds = do
  (rs, rqs, _) <- prepareDeleteConnections_ getConnections c connIds
  rcvRs <- deleteConnQueues c ntf rqs
  let rs' = M.union rs rcvRs
  notifyResultError rs'
  pure rs'
  where
    notifyResultError :: Map ConnId (Either AgentErrorType ()) -> m ()
    notifyResultError rs = do
      let actual = M.size rs
          expected = length connIds
      when (actual /= expected) . atomically $
        writeTBQueue (subQ c) ("", "", APC SAEConn $ ERR $ INTERNAL $ "deleteConnections result size: " <> show actual <> ", expected " <> show expected)

getConnectionServers' :: AgentMonad m => AgentClient -> ConnId -> m ConnectionStats
getConnectionServers' c connId = do
  SomeConn _ conn <- withStore c (`getConn` connId)
  pure $ connectionStats conn

getConnectionRatchetAdHash' :: AgentMonad m => AgentClient -> ConnId -> m ByteString
getConnectionRatchetAdHash' c connId = do
  CR.Ratchet {rcAD = Str rcAD} <- withStore c (`getRatchet` connId)
  pure $ C.sha256Hash rcAD

connectionStats :: Connection c -> ConnectionStats
connectionStats = \case
  RcvConnection _ rq -> ConnectionStats {rcvQueuesInfo = [rcvQueueInfo rq], sndQueuesInfo = []}
  SndConnection _ sq -> ConnectionStats {rcvQueuesInfo = [], sndQueuesInfo = [sndQueueInfo sq]}
  DuplexConnection _ rqs sqs -> ConnectionStats {rcvQueuesInfo = map rcvQueueInfo $ L.toList rqs, sndQueuesInfo = map sndQueueInfo $ L.toList sqs}
  ContactConnection _ rq -> ConnectionStats {rcvQueuesInfo = [rcvQueueInfo rq], sndQueuesInfo = []}
  NewConnection _ -> ConnectionStats {rcvQueuesInfo = [], sndQueuesInfo = []}

-- | Change servers to be used for creating new queues, in Reader monad
setProtocolServers' :: forall p m. (ProtocolTypeI p, UserProtocol p, AgentMonad m) => AgentClient -> UserId -> NonEmpty (ProtoServerWithAuth p) -> m ()
setProtocolServers' c userId srvs = atomically $ TM.insert userId srvs (userServers c)

registerNtfToken' :: forall m. AgentMonad m => AgentClient -> DeviceToken -> NotificationsMode -> m NtfTknStatus
registerNtfToken' c suppliedDeviceToken suppliedNtfMode =
  withStore' c getSavedNtfToken >>= \case
    Just tkn@NtfToken {deviceToken = savedDeviceToken, ntfTokenId, ntfTknStatus, ntfTknAction, ntfMode = savedNtfMode} -> do
      status <- case (ntfTokenId, ntfTknAction) of
        (Nothing, Just NTARegister) -> do
          when (savedDeviceToken /= suppliedDeviceToken) $ withStore' c $ \db -> updateDeviceToken db tkn suppliedDeviceToken
          registerToken tkn $> NTRegistered
        -- possible improvement: add minimal time before repeat registration
        (Just tknId, Nothing)
          | savedDeviceToken == suppliedDeviceToken ->
            when (ntfTknStatus == NTRegistered) (registerToken tkn) $> NTRegistered
          | otherwise -> replaceToken tknId
        (Just tknId, Just (NTAVerify code))
          | savedDeviceToken == suppliedDeviceToken ->
            t tkn (NTActive, Just NTACheck) $ agentNtfVerifyToken c tknId tkn code
          | otherwise -> replaceToken tknId
        (Just tknId, Just NTACheck)
          | savedDeviceToken == suppliedDeviceToken -> do
            ns <- asks ntfSupervisor
            atomically $ nsUpdateToken ns tkn {ntfMode = suppliedNtfMode}
            when (ntfTknStatus == NTActive) $ do
              cron <- asks $ ntfCron . config
              agentNtfEnableCron c tknId tkn cron
              when (suppliedNtfMode == NMInstant) $ initializeNtfSubs c
              when (suppliedNtfMode == NMPeriodic && savedNtfMode == NMInstant) $ deleteNtfSubs c NSCDelete
            -- possible improvement: get updated token status from the server, or maybe TCRON could return the current status
            pure ntfTknStatus
          | otherwise -> replaceToken tknId
        (Just tknId, Just NTADelete) -> do
          agentNtfDeleteToken c tknId tkn
          withStore' c (`removeNtfToken` tkn)
          ns <- asks ntfSupervisor
          atomically $ nsRemoveNtfToken ns
          pure NTExpired
        _ -> pure ntfTknStatus
      withStore' c $ \db -> updateNtfMode db tkn suppliedNtfMode
      pure status
      where
        replaceToken :: NtfTokenId -> m NtfTknStatus
        replaceToken tknId = do
          ns <- asks ntfSupervisor
          tryReplace ns `catchError` \e ->
            if temporaryOrHostError e
              then throwError e
              else do
                withStore' c $ \db -> removeNtfToken db tkn
                atomically $ nsRemoveNtfToken ns
                createToken
          where
            tryReplace ns = do
              agentNtfReplaceToken c tknId tkn suppliedDeviceToken
              withStore' c $ \db -> updateDeviceToken db tkn suppliedDeviceToken
              atomically $ nsUpdateToken ns tkn {deviceToken = suppliedDeviceToken, ntfTknStatus = NTRegistered, ntfMode = suppliedNtfMode}
              pure NTRegistered
    _ -> createToken
  where
    t tkn = withToken c tkn Nothing
    createToken :: m NtfTknStatus
    createToken =
      getNtfServer c >>= \case
        Just ntfServer ->
          asks (cmdSignAlg . config) >>= \case
            C.SignAlg a -> do
              tknKeys <- liftIO $ C.generateSignatureKeyPair a
              dhKeys <- liftIO C.generateKeyPair'
              let tkn = newNtfToken suppliedDeviceToken ntfServer tknKeys dhKeys suppliedNtfMode
              withStore' c (`createNtfToken` tkn)
              registerToken tkn
              pure NTRegistered
        _ -> throwError $ CMD PROHIBITED
    registerToken :: NtfToken -> m ()
    registerToken tkn@NtfToken {ntfPubKey, ntfDhKeys = (pubDhKey, privDhKey)} = do
      (tknId, srvPubDhKey) <- agentNtfRegisterToken c tkn ntfPubKey pubDhKey
      let dhSecret = C.dh' srvPubDhKey privDhKey
      withStore' c $ \db -> updateNtfTokenRegistration db tkn tknId dhSecret
      ns <- asks ntfSupervisor
      atomically $ nsUpdateToken ns tkn {deviceToken = suppliedDeviceToken, ntfTknStatus = NTRegistered, ntfMode = suppliedNtfMode}

verifyNtfToken' :: AgentMonad m => AgentClient -> DeviceToken -> C.CbNonce -> ByteString -> m ()
verifyNtfToken' c deviceToken nonce code =
  withStore' c getSavedNtfToken >>= \case
    Just tkn@NtfToken {deviceToken = savedDeviceToken, ntfTokenId = Just tknId, ntfDhSecret = Just dhSecret, ntfMode} -> do
      when (deviceToken /= savedDeviceToken) . throwError $ CMD PROHIBITED
      code' <- liftEither . bimap cryptoError NtfRegCode $ C.cbDecrypt dhSecret nonce code
      toStatus <-
        withToken c tkn (Just (NTConfirmed, NTAVerify code')) (NTActive, Just NTACheck) $
          agentNtfVerifyToken c tknId tkn code'
      when (toStatus == NTActive) $ do
        cron <- asks $ ntfCron . config
        agentNtfEnableCron c tknId tkn cron
        when (ntfMode == NMInstant) $ initializeNtfSubs c
    _ -> throwError $ CMD PROHIBITED

checkNtfToken' :: AgentMonad m => AgentClient -> DeviceToken -> m NtfTknStatus
checkNtfToken' c deviceToken =
  withStore' c getSavedNtfToken >>= \case
    Just tkn@NtfToken {deviceToken = savedDeviceToken, ntfTokenId = Just tknId} -> do
      when (deviceToken /= savedDeviceToken) . throwError $ CMD PROHIBITED
      agentNtfCheckToken c tknId tkn
    _ -> throwError $ CMD PROHIBITED

deleteNtfToken' :: AgentMonad m => AgentClient -> DeviceToken -> m ()
deleteNtfToken' c deviceToken =
  withStore' c getSavedNtfToken >>= \case
    Just tkn@NtfToken {deviceToken = savedDeviceToken} -> do
      when (deviceToken /= savedDeviceToken) . throwError $ CMD PROHIBITED
      deleteToken_ c tkn
      deleteNtfSubs c NSCSmpDelete
    _ -> throwError $ CMD PROHIBITED

getNtfToken' :: AgentMonad m => AgentClient -> m (DeviceToken, NtfTknStatus, NotificationsMode)
getNtfToken' c =
  withStore' c getSavedNtfToken >>= \case
    Just NtfToken {deviceToken, ntfTknStatus, ntfMode} -> pure (deviceToken, ntfTknStatus, ntfMode)
    _ -> throwError $ CMD PROHIBITED

getNtfTokenData' :: AgentMonad m => AgentClient -> m NtfToken
getNtfTokenData' c =
  withStore' c getSavedNtfToken >>= \case
    Just tkn -> pure tkn
    _ -> throwError $ CMD PROHIBITED

-- | Set connection notifications, in Reader monad
toggleConnectionNtfs' :: forall m. AgentMonad m => AgentClient -> ConnId -> Bool -> m ()
toggleConnectionNtfs' c connId enable = do
  SomeConn _ conn <- withStore c (`getConn` connId)
  case conn of
    DuplexConnection cData _ _ -> toggle cData
    RcvConnection cData _ -> toggle cData
    ContactConnection cData _ -> toggle cData
    _ -> throwError $ CONN SIMPLEX
  where
    toggle :: ConnData -> m ()
    toggle cData
      | enableNtfs cData == enable = pure ()
      | otherwise = do
        withStore' c $ \db -> setConnectionNtfs db connId enable
        ns <- asks ntfSupervisor
        let cmd = if enable then NSCCreate else NSCDelete
        atomically $ sendNtfSubCommand ns (connId, cmd)

deleteToken_ :: AgentMonad m => AgentClient -> NtfToken -> m ()
deleteToken_ c tkn@NtfToken {ntfTokenId, ntfTknStatus} = do
  ns <- asks ntfSupervisor
  forM_ ntfTokenId $ \tknId -> do
    let ntfTknAction = Just NTADelete
    withStore' c $ \db -> updateNtfToken db tkn ntfTknStatus ntfTknAction
    atomically $ nsUpdateToken ns tkn {ntfTknStatus, ntfTknAction}
    agentNtfDeleteToken c tknId tkn `catchError` \case
      NTF AUTH -> pure ()
      e -> throwError e
  withStore' c $ \db -> removeNtfToken db tkn
  atomically $ nsRemoveNtfToken ns

withToken :: AgentMonad m => AgentClient -> NtfToken -> Maybe (NtfTknStatus, NtfTknAction) -> (NtfTknStatus, Maybe NtfTknAction) -> m a -> m NtfTknStatus
withToken c tkn@NtfToken {deviceToken, ntfMode} from_ (toStatus, toAction_) f = do
  ns <- asks ntfSupervisor
  forM_ from_ $ \(status, action) -> do
    withStore' c $ \db -> updateNtfToken db tkn status (Just action)
    atomically $ nsUpdateToken ns tkn {ntfTknStatus = status, ntfTknAction = Just action}
  tryError f >>= \case
    Right _ -> do
      withStore' c $ \db -> updateNtfToken db tkn toStatus toAction_
      let updatedToken = tkn {ntfTknStatus = toStatus, ntfTknAction = toAction_}
      atomically $ nsUpdateToken ns updatedToken
      pure toStatus
    Left e@(NTF AUTH) -> do
      withStore' c $ \db -> removeNtfToken db tkn
      atomically $ nsRemoveNtfToken ns
      void $ registerNtfToken' c deviceToken ntfMode
      throwError e
    Left e -> throwError e

initializeNtfSubs :: AgentMonad m => AgentClient -> m ()
initializeNtfSubs c = sendNtfConnCommands c NSCCreate

deleteNtfSubs :: AgentMonad m => AgentClient -> NtfSupervisorCommand -> m ()
deleteNtfSubs c deleteCmd = do
  ns <- asks ntfSupervisor
  void . atomically . flushTBQueue $ ntfSubQ ns
  sendNtfConnCommands c deleteCmd

sendNtfConnCommands :: AgentMonad m => AgentClient -> NtfSupervisorCommand -> m ()
sendNtfConnCommands c cmd = do
  ns <- asks ntfSupervisor
  connIds <- atomically $ getSubscriptions c
  forM_ connIds $ \connId -> do
    withStore' c (`getConnData` connId) >>= \case
      Just (ConnData {enableNtfs}, _) ->
        when enableNtfs . atomically $ writeTBQueue (ntfSubQ ns) (connId, cmd)
      _ ->
        atomically $ writeTBQueue (subQ c) ("", connId, APC SAEConn $ ERR $ INTERNAL "no connection data")

setNtfServers' :: AgentMonad' m => AgentClient -> [NtfServer] -> m ()
setNtfServers' c = atomically . writeTVar (ntfServers c)

foregroundAgent' :: AgentMonad' m => AgentClient -> m ()
foregroundAgent' c = do
  atomically $ writeTVar (agentState c) ASForeground
  mapM_ activate $ reverse agentOperations
  where
    activate opSel = atomically $ modifyTVar' (opSel c) $ \s -> s {opSuspended = False}

suspendAgent' :: AgentMonad' m => AgentClient -> Int -> m ()
suspendAgent' c 0 = do
  atomically $ writeTVar (agentState c) ASSuspended
  mapM_ suspend agentOperations
  where
    suspend opSel = atomically $ modifyTVar' (opSel c) $ \s -> s {opSuspended = True}
suspendAgent' c@AgentClient {agentState = as} maxDelay = do
  state <-
    atomically $ do
      writeTVar as ASSuspending
      suspendOperation c AONtfNetwork $ pure ()
      suspendOperation c AORcvNetwork $
        suspendOperation c AOMsgDelivery $
          suspendSendingAndDatabase c
      readTVar as
  when (state == ASSuspending) . void . forkIO $ do
    threadDelay maxDelay
    -- liftIO $ putStrLn "suspendAgent after timeout"
    atomically . whenSuspending c $ do
      -- unsafeIOToSTM $ putStrLn $ "in timeout: suspendSendingAndDatabase"
      suspendSendingAndDatabase c

execAgentStoreSQL' :: AgentMonad m => AgentClient -> Text -> m [Text]
execAgentStoreSQL' c sql = withStore' c (`execSQL` sql)

getAgentMigrations' :: AgentMonad m => AgentClient -> m [UpMigration]
getAgentMigrations' c = map upMigration <$> withStore' c Migrations.getCurrent

debugAgentLocks' :: AgentMonad' m => AgentClient -> m AgentLocks
debugAgentLocks' AgentClient {connLocks = cs, reconnectLocks = rs, deleteLock = d} = do
  connLocks <- getLocks cs
  srvLocks <- getLocks rs
  delLock <- atomically $ tryReadTMVar d
  pure AgentLocks {connLocks, srvLocks, delLock}
  where
    getLocks ls = atomically $ M.mapKeys (B.unpack . strEncode) . M.mapMaybe id <$> (mapM tryReadTMVar =<< readTVar ls)

getSMPServer :: AgentMonad m => AgentClient -> UserId -> m SMPServerWithAuth
getSMPServer c userId = withUserServers c userId pickServer

subscriber :: AgentMonad' m => AgentClient -> m ()
subscriber c@AgentClient {msgQ} = forever $ do
  t <- atomically $ readTBQueue msgQ
  agentOperationBracket c AORcvNetwork waitUntilActive $
    runExceptT (processSMPTransmission c t) >>= \case
      Left e -> liftIO $ print e
      Right _ -> return ()

cleanupManager :: forall m. AgentMonad' m => AgentClient -> m ()
cleanupManager c@AgentClient {subQ} = do
  delay <- asks (initialCleanupDelay . config)
  liftIO $ threadDelay' delay
  int <- asks (cleanupInterval . config)
  forever $ do
    void . runExceptT $ do
      deleteConns `catchError` (notify "" . ERR)
      deleteRcvMsgHashes `catchError` (notify "" . ERR)
      deleteRcvFilesExpired `catchError` (notify "" . RFERR)
      deleteRcvFilesDeleted `catchError` (notify "" . RFERR)
      deleteRcvFilesTmpPaths `catchError` (notify "" . RFERR)
      deleteSndFilesExpired `catchError` (notify "" . SFERR)
      deleteSndFilesDeleted `catchError` (notify "" . SFERR)
      deleteSndFilesPrefixPaths `catchError` (notify "" . SFERR)
      deleteExpiredReplicasForDeletion `catchError` (notify "" . SFERR)
    liftIO $ threadDelay' int
  where
    deleteConns =
      withLock (deleteLock c) "cleanupManager" $ do
        void $ withStore' c getDeletedConnIds >>= deleteDeletedConns c
        withStore' c deleteUsersWithoutConns >>= mapM_ (notify "" . DEL_USER)
    deleteRcvMsgHashes = do
      rcvMsgHashesTTL <- asks $ rcvMsgHashesTTL . config
      withStore' c (`deleteRcvMsgHashesExpired` rcvMsgHashesTTL)
    deleteRcvFilesExpired = do
      rcvFilesTTL <- asks $ rcvFilesTTL . config
      rcvExpired <- withStore' c (`getRcvFilesExpired` rcvFilesTTL)
      forM_ rcvExpired $ \(dbId, entId, p) -> flip catchError (notify entId . RFERR) $ do
        removePath =<< toFSFilePath p
        withStore' c (`deleteRcvFile'` dbId)
    deleteRcvFilesDeleted = do
      rcvDeleted <- withStore' c getCleanupRcvFilesDeleted
      forM_ rcvDeleted $ \(dbId, entId, p) -> flip catchError (notify entId . RFERR) $ do
        removePath =<< toFSFilePath p
        withStore' c (`deleteRcvFile'` dbId)
    deleteRcvFilesTmpPaths = do
      rcvTmpPaths <- withStore' c getCleanupRcvFilesTmpPaths
      forM_ rcvTmpPaths $ \(dbId, entId, p) -> flip catchError (notify entId . RFERR) $ do
        removePath =<< toFSFilePath p
        withStore' c (`updateRcvFileNoTmpPath` dbId)
    deleteSndFilesExpired = do
      sndFilesTTL <- asks $ sndFilesTTL . config
      sndExpired <- withStore' c (`getSndFilesExpired` sndFilesTTL)
      forM_ sndExpired $ \(dbId, entId, p) -> flip catchError (notify entId . SFERR) $ do
        forM_ p $ removePath <=< toFSFilePath
        withStore' c (`deleteSndFile'` dbId)
    deleteSndFilesDeleted = do
      sndDeleted <- withStore' c getCleanupSndFilesDeleted
      forM_ sndDeleted $ \(dbId, entId, p) -> flip catchError (notify entId . SFERR) $ do
        forM_ p $ removePath <=< toFSFilePath
        withStore' c (`deleteSndFile'` dbId)
    deleteSndFilesPrefixPaths = do
      sndPrefixPaths <- withStore' c getCleanupSndFilesPrefixPaths
      forM_ sndPrefixPaths $ \(dbId, entId, p) -> flip catchError (notify entId . SFERR) $ do
        removePath =<< toFSFilePath p
        withStore' c (`updateSndFileNoPrefixPath` dbId)
    deleteExpiredReplicasForDeletion = do
      rcvFilesTTL <- asks $ rcvFilesTTL . config
      withStore' c (`deleteDeletedSndChunkReplicasExpired` rcvFilesTTL)
    notify :: forall e. AEntityI e => EntityId -> ACommand 'Agent e -> ExceptT AgentErrorType m ()
    notify entId cmd = atomically $ writeTBQueue subQ ("", entId, APC (sAEntity @e) cmd)

-- | make sure to ACK or throw in each message processing branch
-- it cannot be finally, unfortunately, as sometimes it needs to be ACK+DEL
processSMPTransmission :: forall m. AgentMonad m => AgentClient -> ServerTransmission BrokerMsg -> m ()
processSMPTransmission c@AgentClient {smpClients, subQ} (tSess@(_, srv, _), v, sessId, rId, cmd) = do
  (rq, SomeConn _ conn) <- withStore c (\db -> getRcvConn db srv rId)
  processSMP rq conn $ connData conn
  where
    processSMP :: RcvQueue -> Connection c -> ConnData -> m ()
    processSMP rq@RcvQueue {e2ePrivKey, e2eDhSecret, status} conn cData@ConnData {userId, connId, duplexHandshake} = withConnLock c connId "processSMP" $
      case cmd of
        SMP.MSG msg@SMP.RcvMessage {msgId = srvMsgId} ->
          handleNotifyAck $
            decryptSMPMessage v rq msg >>= \case
              SMP.ClientRcvMsgBody {msgTs = srvTs, msgFlags, msgBody} -> processClientMsg srvTs msgFlags msgBody
              SMP.ClientRcvMsgQuota {} -> queueDrained >> ack
          where
            queueDrained = case conn of
              DuplexConnection _ _ sqs -> void $ enqueueMessages c cData sqs SMP.noMsgFlags $ QCONT (sndAddress rq)
              _ -> pure ()
            processClientMsg srvTs msgFlags msgBody = do
              clientMsg@SMP.ClientMsgEnvelope {cmHeader = SMP.PubHeader phVer e2ePubKey_} <-
                parseMessage msgBody
              clientVRange <- asks $ smpClientVRange . config
              unless (phVer `isCompatible` clientVRange) . throwError $ AGENT A_VERSION
              case (e2eDhSecret, e2ePubKey_) of
                (Nothing, Just e2ePubKey) -> do
                  let e2eDh = C.dh' e2ePubKey e2ePrivKey
                  decryptClientMessage e2eDh clientMsg >>= \case
                    (SMP.PHConfirmation senderKey, AgentConfirmation {e2eEncryption, encConnInfo, agentVersion}) ->
                      smpConfirmation senderKey e2ePubKey e2eEncryption encConnInfo phVer agentVersion >> ack
                    (SMP.PHEmpty, AgentInvitation {connReq, connInfo}) ->
                      smpInvitation connReq connInfo >> ack
                    _ -> prohibited >> ack
                (Just e2eDh, Nothing) -> do
                  decryptClientMessage e2eDh clientMsg >>= \case
                    (SMP.PHEmpty, AgentMsgEnvelope _ encAgentMsg) -> do
                      -- primary queue is set as Active in helloMsg, below is to set additional queues Active
                      let RcvQueue {primary, dbReplaceQueueId} = rq
                      unless (status == Active) . withStore' c $ \db -> setRcvQueueStatus db rq Active
                      case (conn, dbReplaceQueueId) of
                        (DuplexConnection _ rqs _, Just replacedId) -> do
                          when primary . withStore' c $ \db -> setRcvQueuePrimary db connId rq
                          case find (\RcvQueue {dbQueueId} -> dbQueueId == replacedId) rqs of
                            Just replaced@RcvQueue {server, rcvId} -> do
                              withSwitchedRQ c replaced RSSQueueingQUSE (\db q -> setRcvQueueSwitchStatus db q (Just RSSQueueingDelete)) >>= \case
                                Right _replaced' -> enqueueCommand c "" connId (Just server) $ AInternalCommand $ ICQDelete rcvId
                                Left qce -> switchCannotProceedErr $ qceStr qce ("expected switch status " <> show RSSQueueingQUSE)
                            _ -> notify . ERR . AGENT $ A_QUEUE "replaced RcvQueue not found in connection"
                        _ -> pure ()
                      let encryptedMsgHash = C.sha256Hash encAgentMsg
                      tryError (agentClientMsg encryptedMsgHash) >>= \case
                        Right (Just (msgId, msgMeta, aMessage)) -> case aMessage of
                          HELLO -> helloMsg >> ackDel msgId
                          REPLY cReq -> replyMsg cReq >> ackDel msgId
                          -- note that there is no ACK sent for A_MSG, it is sent with agent's user ACK command
                          A_MSG body -> do
                            logServer "<--" c srv rId "MSG <MSG>"
                            notify $ MSG msgMeta msgFlags body
                          QCONT addr -> qDuplex "QCONT" $ continueSending addr
                          QADD qs -> qDuplex "QADD" $ qAddMsg qs
                          QKEY qs -> qDuplex "QKEY" $ qKeyMsg qs
                          QUSE qs -> qDuplex "QUSE" $ qUseMsg qs
                          -- no action needed for QTEST
                          -- any message in the new queue will mark it active and trigger deletion of the old queue
                          QTEST _ -> logServer "<--" c srv rId "MSG <QTEST>" >> ackDel msgId
                          where
                            qDuplex :: String -> (Connection 'CDuplex -> m ()) -> m ()
                            qDuplex name a = case conn of
                              DuplexConnection {} -> a conn >> ackDel msgId
                              _ -> qError $ name <> ": message must be sent to duplex connection"
                        Right _ -> prohibited >> ack
                        Left e@(AGENT A_DUPLICATE) -> do
                          withStore' c (\db -> getLastMsg db connId srvMsgId) >>= \case
                            Just RcvMsg {internalId, msgMeta, msgBody = agentMsgBody, userAck}
                              | userAck -> ackDel internalId
                              | otherwise -> do
                                liftEither (parse smpP (AGENT A_MESSAGE) agentMsgBody) >>= \case
                                  AgentMessage _ (A_MSG body) -> do
                                    logServer "<--" c srv rId "MSG <MSG>"
                                    notify $ MSG msgMeta msgFlags body
                                  _ -> pure ()
                            _ -> checkDuplicateHash e encryptedMsgHash >> ack
                        Left e -> checkDuplicateHash e encryptedMsgHash >> ack
                      where
                        checkDuplicateHash :: AgentErrorType -> ByteString -> m ()
                        checkDuplicateHash e encryptedMsgHash =
                          unlessM (withStore' c $ \db -> checkRcvMsgHashExists db connId encryptedMsgHash) $
                            throwError e
                        agentClientMsg :: ByteString -> m (Maybe (InternalId, MsgMeta, AMessage))
                        agentClientMsg encryptedMsgHash = withStore c $ \db -> runExceptT $ do
                          agentMsgBody <- agentRatchetDecrypt db connId encAgentMsg
                          liftEither (parse smpP (SEAgentError $ AGENT A_MESSAGE) agentMsgBody) >>= \case
                            agentMsg@(AgentMessage APrivHeader {sndMsgId, prevMsgHash} aMessage) -> do
                              let msgType = agentMessageType agentMsg
                                  internalHash = C.sha256Hash agentMsgBody
                              internalTs <- liftIO getCurrentTime
                              (internalId, internalRcvId, prevExtSndId, prevRcvMsgHash) <- liftIO $ updateRcvIds db connId
                              let integrity = checkMsgIntegrity prevExtSndId sndMsgId prevRcvMsgHash prevMsgHash
                                  recipient = (unId internalId, internalTs)
                                  broker = (srvMsgId, systemToUTCTime srvTs)
                                  msgMeta = MsgMeta {integrity, recipient, broker, sndMsgId}
                                  rcvMsg = RcvMsgData {msgMeta, msgType, msgFlags, msgBody = agentMsgBody, internalRcvId, internalHash, externalPrevSndHash = prevMsgHash, encryptedMsgHash}
                              liftIO $ createRcvMsg db connId rq rcvMsg
                              pure $ Just (internalId, msgMeta, aMessage)
                            _ -> pure Nothing
                    _ -> prohibited >> ack
                _ -> prohibited >> ack
            ack :: m ()
            ack = enqueueCmd $ ICAck rId srvMsgId
            ackDel :: InternalId -> m ()
            ackDel = enqueueCmd . ICAckDel rId srvMsgId
            handleNotifyAck :: m () -> m ()
            handleNotifyAck m = m `catchError` \e -> notify (ERR e) >> ack
        SMP.END ->
          atomically (TM.lookup tSess smpClients $>>= tryReadTMVar >>= processEND)
            >>= logServer "<--" c srv rId
          where
            processEND = \case
              Just (Right clnt)
                | sessId == sessionId clnt -> do
                  removeSubscription c connId
                  notify' END
                  pure "END"
                | otherwise -> ignored
              _ -> ignored
            ignored = pure "END from disconnected client - ignored"
        _ -> do
          logServer "<--" c srv rId $ "unexpected: " <> bshow cmd
          notify . ERR $ BROKER (B.unpack $ strEncode srv) UNEXPECTED
      where
        notify :: forall e. AEntityI e => ACommand 'Agent e -> m ()
        notify = atomically . notify'

        notify' :: forall e. AEntityI e => ACommand 'Agent e -> STM ()
        notify' msg = writeTBQueue subQ ("", connId, APC (sAEntity @e) msg)

        prohibited :: m ()
        prohibited = notify . ERR $ AGENT A_PROHIBITED

        enqueueCmd :: InternalCommand -> m ()
        enqueueCmd = enqueueCommand c "" connId (Just srv) . AInternalCommand

        decryptClientMessage :: C.DhSecretX25519 -> SMP.ClientMsgEnvelope -> m (SMP.PrivHeader, AgentMsgEnvelope)
        decryptClientMessage e2eDh SMP.ClientMsgEnvelope {cmNonce, cmEncBody} = do
          clientMsg <- agentCbDecrypt e2eDh cmNonce cmEncBody
          SMP.ClientMessage privHeader clientBody <- parseMessage clientMsg
          agentEnvelope <- parseMessage clientBody
          -- Version check is removed here, because when connecting via v1 contact address the agent still sends v2 message,
          -- to allow duplexHandshake mode, in case the receiving agent was updated to v2 after the address was created.
          -- aVRange <- asks $ smpAgentVRange . config
          -- if agentVersion agentEnvelope `isCompatible` aVRange
          --   then pure (privHeader, agentEnvelope)
          --   else throwError $ AGENT A_VERSION
          pure (privHeader, agentEnvelope)

        parseMessage :: Encoding a => ByteString -> m a
        parseMessage = liftEither . parse smpP (AGENT A_MESSAGE)

        smpConfirmation :: C.APublicVerifyKey -> C.PublicKeyX25519 -> Maybe (CR.E2ERatchetParams 'C.X448) -> ByteString -> Version -> Version -> m ()
        smpConfirmation senderKey e2ePubKey e2eEncryption encConnInfo smpClientVersion agentVersion = do
          logServer "<--" c srv rId "MSG <CONF>"
          AgentConfig {smpClientVRange, smpAgentVRange, e2eEncryptVRange} <- asks config
          unless
            (agentVersion `isCompatible` smpAgentVRange && smpClientVersion `isCompatible` smpClientVRange)
            (throwError $ AGENT A_VERSION)
          case status of
            New -> case (conn, e2eEncryption) of
              -- party initiating connection
              (RcvConnection {}, Just e2eSndParams@(CR.E2ERatchetParams e2eVersion _ _)) -> do
                unless (e2eVersion `isCompatible` e2eEncryptVRange) (throwError $ AGENT A_VERSION)
                (pk1, rcDHRs) <- withStore c (`getRatchetX3dhKeys` connId)
                let rc = CR.initRcvRatchet e2eEncryptVRange rcDHRs $ CR.x3dhRcv pk1 rcDHRs e2eSndParams
                (agentMsgBody_, rc', skipped) <- liftError cryptoError $ CR.rcDecrypt rc M.empty encConnInfo
                case (agentMsgBody_, skipped) of
                  (Right agentMsgBody, CR.SMDNoChange) ->
                    parseMessage agentMsgBody >>= \case
                      AgentConnInfo connInfo ->
                        processConf connInfo SMPConfirmation {senderKey, e2ePubKey, connInfo, smpReplyQueues = [], smpClientVersion} False
                      AgentConnInfoReply smpQueues connInfo ->
                        processConf connInfo SMPConfirmation {senderKey, e2ePubKey, connInfo, smpReplyQueues = L.toList smpQueues, smpClientVersion} True
                      _ -> prohibited
                    where
                      processConf connInfo senderConf duplexHS = do
                        let newConfirmation = NewConfirmation {connId, senderConf, ratchetState = rc'}
                        g <- asks idsDrg
                        confId <- withStore c $ \db -> do
                          setHandshakeVersion db connId agentVersion duplexHS
                          createConfirmation db g newConfirmation
                        let srvs = map qServer $ smpReplyQueues senderConf
                        notify $ CONF confId srvs connInfo
                  _ -> prohibited
              -- party accepting connection
              (DuplexConnection _ (RcvQueue {smpClientVersion = v'} :| _) _, Nothing) -> do
                withStore c (\db -> runExceptT $ agentRatchetDecrypt db connId encConnInfo) >>= parseMessage >>= \case
                  AgentConnInfo connInfo -> do
                    notify $ INFO connInfo
                    let dhSecret = C.dh' e2ePubKey e2ePrivKey
                    withStore' c $ \db -> setRcvQueueConfirmedE2E db rq dhSecret $ min v' smpClientVersion
                    enqueueCmd $ ICDuplexSecure rId senderKey
                  _ -> prohibited
              _ -> prohibited
            _ -> prohibited

        helloMsg :: m ()
        helloMsg = do
          logServer "<--" c srv rId "MSG <HELLO>"
          case status of
            Active -> prohibited
            _ ->
              case conn of
                DuplexConnection _ _ (sq@SndQueue {status = sndStatus} :| _)
                  -- `sndStatus == Active` when HELLO was previously sent, and this is the reply HELLO
                  -- this branch is executed by the accepting party in duplexHandshake mode (v2)
                  -- and by the initiating party in v1
                  -- Also see comment where HELLO is sent.
                  | sndStatus == Active -> notify CON
                  | duplexHandshake == Just True -> enqueueDuplexHello sq
                  | otherwise -> pure ()
                _ -> pure ()

        enqueueDuplexHello :: SndQueue -> m ()
        enqueueDuplexHello sq = void $ enqueueMessage c cData sq SMP.MsgFlags {notification = True} HELLO

        replyMsg :: NonEmpty SMPQueueInfo -> m ()
        replyMsg smpQueues = do
          logServer "<--" c srv rId "MSG <REPLY>"
          case duplexHandshake of
            Just True -> prohibited
            _ -> case conn of
              RcvConnection {} -> do
                AcceptedConfirmation {ownConnInfo} <- withStore c (`getAcceptedConfirmation` connId)
                connectReplyQueues c cData ownConnInfo smpQueues `catchError` (notify . ERR)
              _ -> prohibited

        continueSending :: (SMPServer, SMP.SenderId) -> Connection 'CDuplex -> m ()
        continueSending addr (DuplexConnection _ _ sqs) =
          case findQ addr sqs of
            Just sq -> do
              logServer "<--" c srv rId "MSG <QCONT>"
              atomically $ do
                (_, qLock) <- getPendingMsgQ c sq
                void $ tryPutTMVar qLock ()
            Nothing -> qError "QCONT: queue address not found"

        -- processed by queue sender
        qAddMsg :: NonEmpty (SMPQueueUri, Maybe SndQAddr) -> Connection 'CDuplex -> m ()
        qAddMsg ((_, Nothing) :| _) _ = qError "adding queue without switching is not supported"
        qAddMsg ((qUri, Just addr) :| _) (DuplexConnection _ rqs sqs) = do
          clientVRange <- asks $ smpClientVRange . config
          case qUri `compatibleVersion` clientVRange of
            Just qInfo@(Compatible sqInfo@SMPQueueInfo {queueAddress}) ->
              case (findQ (qAddress sqInfo) sqs, findQ addr sqs) of
                -- ! this check is outside of transaction that adds new queue to connection (addConnSndQueue),
                -- ! race condition with other queue receiving same message might be possible with redundant delivery
                -- TODO addConnSndQueue should be in the same transaction as reading current snd queues
                (Just _, _) -> qError "QADD: queue address is already used in connection"
                (_, Just replaced@SndQueue {dbQueueId}) -> do
                  let resetUpdateSwitchStatus = \db q@SndQueue {connId = cId} -> do
                        -- multiple switching queues were possible when repeating switch while in progress was allowed
                        switchingQueues <- getSwitchingSndQueues db dbQueueId
                        forM_ switchingQueues $ \switchingQ -> deleteConnSndQueue db cId switchingQ
                        setSndQueueSwitchStatus db q (Just SSSReceivedQADD)
                  -- the only condition we will not proceed to delete switching queues
                  -- is if switched queue was already deleted from db
                  withExistingSQ c replaced (const True) resetUpdateSwitchStatus >>= \case
                    Left qce -> switchCannotProceedErr $ qceStr qce "no predicate"
                    Right replaced' -> do
                      sq_@SndQueue {sndPublicKey, e2ePubKey} <- newSndQueue userId connId qInfo
                      let sq' = (sq_ :: SndQueue) {primary = True, dbReplaceQueueId = Just dbQueueId}
                      void . withStore c $ \db -> addConnSndQueue db connId sq'
                      case (sndPublicKey, e2ePubKey) of
                        (Just sndPubKey, Just dhPublicKey) -> do
                          logServer "<--" c srv rId $ "MSG <QADD> " <> logSecret (senderId queueAddress)
                          let sqInfo' = (sqInfo :: SMPQueueInfo) {queueAddress = queueAddress {dhPublicKey}}
                              updateSwitchStatus = \db q -> do
                                void $ setSndQueueSwitchStatus db q (Just SSSQueueingQKEY)
                                getSndQueuesByConnId db connId
                          withSwitchedSQ c replaced' SSSReceivedQADD updateSwitchStatus >>= \case
                            Right (Just sqs') -> do
                              void . enqueueMessages c cData sqs SMP.noMsgFlags $ QKEY [(sqInfo', sndPubKey)]
                              let conn' = DuplexConnection cData rqs sqs'
                              notify . SWITCH QDSnd SPStarted $ connectionStats conn' -- SPConfirmed?
                            Right Nothing -> throwError $ INTERNAL "no snd queues in connection after starting switch"
                            Left qce -> switchCannotProceedErr $ qceStr qce ("expected switch status " <> show SSSReceivedQADD)
                        _ -> qError "absent sender keys"
                _ -> qError "QADD: replaced queue address is not found in connection"
            _ -> throwError $ AGENT A_VERSION

        -- processed by queue recipient
        qKeyMsg :: NonEmpty (SMPQueueInfo, SndPublicVerifyKey) -> Connection 'CDuplex -> m ()
        qKeyMsg ((qInfo, senderKey) :| _) (DuplexConnection _ rqs sqs) = do
          withSwitchedRQ c rq RSSQueueingQADD (\db q -> setRcvQueueSwitchStatus db q (Just RSSReceivedQKEY)) >>= \case
            Left qce -> switchCannotProceedErr $ qceStr qce ("expected switch status " <> show RSSQueueingQADD)
            Right replaced -> do
              clientVRange <- asks $ smpClientVRange . config
              unless (qInfo `isCompatible` clientVRange) . throwError $ AGENT A_VERSION
              case findRQ (smpServer, senderId) rqs of
                Just rq'@RcvQueue {rcvId, e2ePrivKey = dhPrivKey, smpClientVersion = cVer, status = status'}
                  | status' == New || status' == Confirmed -> do
                    logServer "<--" c srv rId $ "MSG <QKEY> " <> logSecret senderId
                    let dhSecret = C.dh' dhPublicKey dhPrivKey
                    withStore' c $ \db -> setRcvQueueConfirmedE2E db rq' dhSecret $ min cVer cVer'
                    let updateSwitchStatus = \db q -> do
                          void $ setRcvQueueSwitchStatus db q (Just RSSQueueingSecure)
                          getRcvQueuesByConnId db connId
                    withSwitchedRQ c replaced RSSReceivedQKEY updateSwitchStatus >>= \case
                      Right (Just rqs') -> do
                        enqueueCommand c "" connId (Just smpServer) $ AInternalCommand $ ICQSecure rcvId senderKey
                        let conn' = DuplexConnection cData rqs' sqs
                        notify . SWITCH QDRcv SPConfirmed $ connectionStats conn'
                      Right _ -> throwError $ INTERNAL "no rcv queues in connection after processing QKEY"
                      Left qce -> switchCannotProceedErr $ qceStr qce ("expected switch status " <> show RSSReceivedQKEY)
                  | otherwise -> qError "QKEY: queue already secured"
                _ -> qError "QKEY: queue address not found in connection"
          where
            SMPQueueInfo cVer' SMPQueueAddress {smpServer, senderId, dhPublicKey} = qInfo

        -- processed by queue sender
        -- mark queue as Secured and to start sending messages to it
        qUseMsg :: NonEmpty ((SMPServer, SMP.SenderId), Bool) -> Connection 'CDuplex -> m ()
        -- NOTE: does not yet support the change of the primary status during the rotation
        qUseMsg ((addr, _primary) :| _) (DuplexConnection _ rqs sqs) =
          case findSwitchedSQ sqs of
            Just replaced -> do
              withSwitchedSQ c replaced SSSQueueingQKEY (\db q -> setSndQueueSwitchStatus db q (Just SSSReceivedQUSE)) >>= \case
                Left qce -> switchCannotProceedErr $ qceStr qce ("expected switch status " <> show SSSQueueingQKEY)
                Right replaced' -> do
                  case findQ addr sqs of
                    Just sq' -> do
                      logServer "<--" c srv rId $ "MSG <QUSE> " <> logSecret (snd addr)
                      withStore' c $ \db -> setSndQueueStatus db sq' Secured
                      let sq'' = (sq' :: SndQueue) {status = Secured}
                          updateSwitchStatus = \db q -> do
                            void $ setSndQueueSwitchStatus db q (Just SSSQueueingQTEST)
                            getSndQueuesByConnId db connId
                      withSwitchedSQ c replaced' SSSReceivedQUSE updateSwitchStatus >>= \case
                        Right (Just sqs') -> do
                          -- sending QTEST to the new queue only, the old one will be removed if sent successfully
                          void $ enqueueMessages c cData [sq''] SMP.noMsgFlags $ QTEST [addr]
                          let conn' = DuplexConnection cData rqs sqs'
                          notify . SWITCH QDSnd SPConfirmed $ connectionStats conn' -- SPFinalizing?
                        Right Nothing -> throwError $ INTERNAL "no snd queues in connection after processing QUSE"
                        Left qce -> switchCannotProceedErr $ qceStr qce ("expected switch status " <> show SSSReceivedQUSE)
                    _ -> qError "QUSE: queue address not found in connection"
            _ -> qError "QUSE: switched SndQueue not found in connection"

        qError :: String -> m ()
        qError = throwError . AGENT . A_QUEUE

        smpInvitation :: ConnectionRequestUri 'CMInvitation -> ConnInfo -> m ()
        smpInvitation connReq@(CRInvitationUri crData _) cInfo = do
          logServer "<--" c srv rId "MSG <KEY>"
          case conn of
            ContactConnection {} -> do
              g <- asks idsDrg
              let newInv = NewInvitation {contactConnId = connId, connReq, recipientConnInfo = cInfo}
              invId <- withStore c $ \db -> createInvitation db g newInv
              let srvs = L.map qServer $ crSmpQueues crData
              notify $ REQ invId srvs cInfo
            _ -> prohibited

        checkMsgIntegrity :: PrevExternalSndId -> ExternalSndId -> PrevRcvMsgHash -> ByteString -> MsgIntegrity
        checkMsgIntegrity prevExtSndId extSndId internalPrevMsgHash receivedPrevMsgHash
          | extSndId == prevExtSndId + 1 && internalPrevMsgHash == receivedPrevMsgHash = MsgOk
          | extSndId < prevExtSndId = MsgError $ MsgBadId extSndId
          | extSndId == prevExtSndId = MsgError MsgDuplicate -- ? deduplicate
          | extSndId > prevExtSndId + 1 = MsgError $ MsgSkipped (prevExtSndId + 1) (extSndId - 1)
          | internalPrevMsgHash /= receivedPrevMsgHash = MsgError MsgBadHash
          | otherwise = MsgError MsgDuplicate -- this case is not possible

withSwitchedRQ :: AgentMonad m => AgentClient -> RcvQueue -> RcvSwitchStatus -> (DB.Connection -> RcvQueue -> IO a) -> m (Either QueueCheckError a)
withSwitchedRQ c rq expected =
  withExistingRQ c rq (\RcvQueue {switchStatus} -> switchStatus == Just expected)

withExistingRQ :: AgentMonad m => AgentClient -> RcvQueue -> (RcvQueue -> Bool) -> (DB.Connection -> RcvQueue -> IO a) -> m (Either QueueCheckError a)
withExistingRQ c RcvQueue {connId, dbQueueId} qp action =
  withStore c $ \db ->
    getRcvQueueById db connId dbQueueId >>= \case
      Right rq ->
        if qp rq
          then do
            r <- action db rq
            pure $ Right (Right r)
          else pure $ Right (Left QCEPredicateFailed)
      _ -> pure $ Right (Left QCEQueueNotFound)

withSwitchedSQ :: AgentMonad m => AgentClient -> SndQueue -> SndSwitchStatus -> (DB.Connection -> SndQueue -> IO a) -> m (Either QueueCheckError a)
withSwitchedSQ c sq expected =
  withExistingSQ c sq (\SndQueue {switchStatus} -> switchStatus == Just expected)

withExistingSQ :: AgentMonad m => AgentClient -> SndQueue -> (SndQueue -> Bool) -> (DB.Connection -> SndQueue -> IO a) -> m (Either QueueCheckError a)
withExistingSQ c SndQueue {connId, dbQueueId} qp action =
  withStore c $ \db ->
    getSndQueueById db connId dbQueueId >>= \case
      Right sq ->
        if qp sq
          then do
            r <- action db sq
            pure $ Right (Right r)
          else pure $ Right (Left QCEPredicateFailed)
      _ -> pure $ Right (Left QCEQueueNotFound)

data QueueCheckError = QCEQueueNotFound | QCEPredicateFailed

qceStr :: QueueCheckError -> String -> String
qceStr qce qpFailedStr = case qce of
  QCEQueueNotFound -> "queue not found"
  QCEPredicateFailed -> qpFailedStr

switchCannotProceedErr :: AgentMonad m => String -> m a
switchCannotProceedErr errStr = throwError $ AGENT $ A_QUEUE $ "cannot proceed with switch, " <> errStr

connectReplyQueues :: AgentMonad m => AgentClient -> ConnData -> ConnInfo -> NonEmpty SMPQueueInfo -> m ()
connectReplyQueues c cData@ConnData {userId, connId} ownConnInfo (qInfo :| _) = do
  clientVRange <- asks $ smpClientVRange . config
  case qInfo `proveCompatible` clientVRange of
    Nothing -> throwError $ AGENT A_VERSION
    Just qInfo' -> do
      sq <- newSndQueue userId connId qInfo'
      dbQueueId <- withStore c $ \db -> upgradeRcvConnToDuplex db connId sq
      enqueueConfirmation c cData sq {dbQueueId} ownConnInfo Nothing

confirmQueue :: forall m. AgentMonad m => Compatible Version -> AgentClient -> ConnData -> SndQueue -> SMPServerWithAuth -> ConnInfo -> Maybe (CR.E2ERatchetParams 'C.X448) -> m ()
confirmQueue (Compatible agentVersion) c cData@ConnData {connId} sq srv connInfo e2eEncryption = do
  aMessage <- mkAgentMessage agentVersion
  msg <- mkConfirmation aMessage
  sendConfirmation c sq msg
  withStore' c $ \db -> setSndQueueStatus db sq Confirmed
  where
    mkConfirmation :: AgentMessage -> m MsgBody
    mkConfirmation aMessage = withStore c $ \db -> runExceptT $ do
      void . liftIO $ updateSndIds db connId
      encConnInfo <- agentRatchetEncrypt db connId (smpEncode aMessage) e2eEncConnInfoLength
      pure . smpEncode $ AgentConfirmation {agentVersion, e2eEncryption, encConnInfo}
    mkAgentMessage :: Version -> m AgentMessage
    mkAgentMessage 1 = pure $ AgentConnInfo connInfo
    mkAgentMessage _ = do
      qInfo <- createReplyQueue c cData sq srv
      pure $ AgentConnInfoReply (qInfo :| []) connInfo

enqueueConfirmation :: forall m. AgentMonad m => AgentClient -> ConnData -> SndQueue -> ConnInfo -> Maybe (CR.E2ERatchetParams 'C.X448) -> m ()
enqueueConfirmation c cData@ConnData {connId, connAgentVersion} sq connInfo e2eEncryption = do
  resumeMsgDelivery c cData sq
  msgId <- storeConfirmation
  queuePendingMsgs c sq [msgId]
  where
    storeConfirmation :: m InternalId
    storeConfirmation = withStore c $ \db -> runExceptT $ do
      internalTs <- liftIO getCurrentTime
      (internalId, internalSndId, prevMsgHash) <- liftIO $ updateSndIds db connId
      let agentMsg = AgentConnInfo connInfo
          agentMsgStr = smpEncode agentMsg
          internalHash = C.sha256Hash agentMsgStr
      encConnInfo <- agentRatchetEncrypt db connId agentMsgStr e2eEncConnInfoLength
      let msgBody = smpEncode $ AgentConfirmation {agentVersion = connAgentVersion, e2eEncryption, encConnInfo}
          msgType = agentMessageType agentMsg
          msgData = SndMsgData {internalId, internalSndId, internalTs, msgType, msgBody, msgFlags = SMP.MsgFlags {notification = True}, internalHash, prevMsgHash}
      liftIO $ createSndMsg db connId msgData
      pure internalId

-- encoded AgentMessage -> encoded EncAgentMessage
agentRatchetEncrypt :: DB.Connection -> ConnId -> ByteString -> Int -> ExceptT StoreError IO ByteString
agentRatchetEncrypt db connId msg paddedLen = do
  rc <- ExceptT $ getRatchet db connId
  (encMsg, rc') <- liftE (SEAgentError . cryptoError) $ CR.rcEncrypt rc paddedLen msg
  liftIO $ updateRatchet db connId rc' CR.SMDNoChange
  pure encMsg

-- encoded EncAgentMessage -> encoded AgentMessage
agentRatchetDecrypt :: DB.Connection -> ConnId -> ByteString -> ExceptT StoreError IO ByteString
agentRatchetDecrypt db connId encAgentMsg = do
  rc <- ExceptT $ getRatchet db connId
  skipped <- liftIO $ getSkippedMsgKeys db connId
  (agentMsgBody_, rc', skippedDiff) <- liftE (SEAgentError . cryptoError) $ CR.rcDecrypt rc skipped encAgentMsg
  liftIO $ updateRatchet db connId rc' skippedDiff
  liftEither $ first (SEAgentError . cryptoError) agentMsgBody_

newSndQueue :: (MonadUnliftIO m, MonadReader Env m) => UserId -> ConnId -> Compatible SMPQueueInfo -> m SndQueue
newSndQueue userId connId (Compatible (SMPQueueInfo smpClientVersion SMPQueueAddress {smpServer, senderId, dhPublicKey = rcvE2ePubDhKey})) = do
  C.SignAlg a <- asks $ cmdSignAlg . config
  (sndPublicKey, sndPrivateKey) <- liftIO $ C.generateSignatureKeyPair a
  (e2ePubKey, e2ePrivKey) <- liftIO C.generateKeyPair'
  pure
    SndQueue
      { userId,
        connId,
        server = smpServer,
        sndId = senderId,
        sndPublicKey = Just sndPublicKey,
        sndPrivateKey,
        e2eDhSecret = C.dh' rcvE2ePubDhKey e2ePrivKey,
        e2ePubKey = Just e2ePubKey,
        status = New,
        dbQueueId = 0,
        primary = True,
        dbReplaceQueueId = Nothing,
        switchStatus = Nothing,
        smpClientVersion
      }
