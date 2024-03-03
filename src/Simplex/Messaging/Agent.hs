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
{-# OPTIONS_GHC -fno-warn-ambiguous-fields #-}

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
    SubscriptionsInfo (..),
    getSMPAgentClient,
    getSMPAgentClient_,
    disconnectAgentClient,
    resumeAgentClient,
    withConnLock,
    withInvLock,
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
    sendMessages,
    sendMessagesB,
    ackMessage,
    switchConnection,
    abortConnectionSwitch,
    synchronizeRatchet,
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
    reconnectAllServers,
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
    xftpDeleteRcvFiles,
    xftpSendFile,
    xftpSendDescription,
    xftpDeleteSndFileInternal,
    xftpDeleteSndFilesInternal,
    xftpDeleteSndFileRemote,
    xftpDeleteSndFilesRemote,
    rcNewHostPairing,
    rcConnectHost,
    rcConnectCtrl,
    rcDiscoverCtrl,
    foregroundAgent,
    suspendAgent,
    execAgentStoreSQL,
    getAgentMigrations,
    debugAgentLocks,
    getAgentStats,
    resetAgentStats,
    getAgentSubscriptions,
    logConnection,
  )
where

import Control.Logger.Simple (logError, logInfo, showText)
import Control.Monad
import Control.Monad.Except
import Control.Monad.IO.Unlift (MonadUnliftIO)
import Control.Monad.Reader
import Crypto.Random (ChaChaDRG, MonadRandom)
import qualified Data.Aeson as J
import Data.Bifunctor (bimap, first, second)
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.Composition ((.:), (.:.), (.::), (.::.))
import Data.Either (isRight, rights)
import Data.Foldable (foldl', toList)
import Data.Functor (($>))
import Data.Functor.Identity
import Data.List (find)
import Data.List.NonEmpty (NonEmpty (..))
import qualified Data.List.NonEmpty as L
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import Data.Maybe (catMaybes, fromMaybe, isJust, isNothing, mapMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock
import Data.Time.Clock.System (systemToUTCTime)
import Data.Word (Word16)
import Simplex.FileTransfer.Agent (closeXFTPAgent, deleteSndFileInternal, deleteSndFileRemote, deleteSndFilesInternal, deleteSndFilesRemote, startXFTPWorkers, toFSFilePath, xftpDeleteRcvFile', xftpDeleteRcvFiles', xftpReceiveFile', xftpSendDescription', xftpSendFile')
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
import qualified Simplex.Messaging.Agent.Store.SQLite.DB as DB
import qualified Simplex.Messaging.Agent.Store.SQLite.Migrations as Migrations
import Simplex.Messaging.Client (ProtocolClient (..), ServerTransmission)
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Crypto.File (CryptoFile, CryptoFileArgs)
import qualified Simplex.Messaging.Crypto.Ratchet as CR
import Simplex.Messaging.Encoding
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Notifications.Protocol (DeviceToken, NtfRegCode (NtfRegCode), NtfTknStatus (..), NtfTokenId)
import Simplex.Messaging.Notifications.Server.Push.APNS (PNMessageData (..))
import Simplex.Messaging.Notifications.Types
import Simplex.Messaging.Parsers (parse)
import Simplex.Messaging.Protocol (BrokerMsg, EntityId, ErrorType (AUTH), MsgBody, MsgFlags (..), NtfServer, ProtoServerWithAuth, ProtocolTypeI (..), SMPMsgMeta, SProtocolType (..), SndPublicAuthKey, SubscriptionMode (..), UserProtocol, XFTPServerWithAuth)
import qualified Simplex.Messaging.Protocol as SMP
import Simplex.Messaging.ServiceScheme (ServiceScheme (..))
import qualified Simplex.Messaging.TMap as TM
import Simplex.Messaging.Transport (THandleParams (sessionId))
import Simplex.Messaging.Util
import Simplex.Messaging.Version
import Simplex.RemoteControl.Client
import Simplex.RemoteControl.Invitation
import Simplex.RemoteControl.Types
import UnliftIO.Async (race_)
import UnliftIO.Concurrent (forkFinally, forkIO, threadDelay)
import UnliftIO.STM

-- import GHC.Conc (unsafeIOToSTM)

-- | Creates an SMP agent client instance
getSMPAgentClient :: (MonadRandom m, MonadUnliftIO m) => AgentConfig -> InitialAgentServers -> SQLiteStore -> Bool -> m AgentClient
getSMPAgentClient = getSMPAgentClient_ 1
{-# INLINE getSMPAgentClient #-}

getSMPAgentClient_ :: (MonadRandom m, MonadUnliftIO m) => Int -> AgentConfig -> InitialAgentServers -> SQLiteStore -> Bool -> m AgentClient
getSMPAgentClient_ clientId cfg initServers store backgroundMode =
  liftIO (newSMPAgentEnv cfg store) >>= runReaderT runAgent
  where
    runAgent = do
      c <- getAgentClient clientId initServers
      void $ runAgentThreads c `forkFinally` const (disconnectAgentClient c)
      pure c
    runAgentThreads c
      | backgroundMode = subscriber c
      | otherwise = raceAny_ [subscriber c, runNtfSupervisor c, cleanupManager c]

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
createConnectionAsync :: forall m c. (AgentErrorMonad m, ConnectionModeI c) => AgentClient -> UserId -> ACorrId -> Bool -> SConnectionMode c -> CR.InitialKeys -> SubscriptionMode -> m ConnId
createConnectionAsync c userId aCorrId enableNtfs = withAgentEnv c .:. newConnAsync c userId aCorrId enableNtfs

-- | Join SMP agent connection (JOIN command) asynchronously, synchronous response is new connection id
joinConnectionAsync :: AgentErrorMonad m => AgentClient -> UserId -> ACorrId -> Bool -> ConnectionRequestUri c -> ConnInfo -> CR.PQEncryption -> SubscriptionMode -> m ConnId
joinConnectionAsync c userId aCorrId enableNtfs = withAgentEnv c .:: joinConnAsync c userId aCorrId enableNtfs

-- | Allow connection to continue after CONF notification (LET command), no synchronous response
allowConnectionAsync :: AgentErrorMonad m => AgentClient -> ACorrId -> ConnId -> ConfirmationId -> ConnInfo -> m ()
allowConnectionAsync c = withAgentEnv c .:: allowConnectionAsync' c

-- | Accept contact after REQ notification (ACPT command) asynchronously, synchronous response is new connection id
acceptContactAsync :: AgentErrorMonad m => AgentClient -> ACorrId -> Bool -> ConfirmationId -> ConnInfo -> CR.PQEncryption -> SubscriptionMode -> m ConnId
acceptContactAsync c aCorrId enableNtfs = withAgentEnv c .:: acceptContactAsync' c aCorrId enableNtfs

-- | Acknowledge message (ACK command) asynchronously, no synchronous response
ackMessageAsync :: forall m. AgentErrorMonad m => AgentClient -> ACorrId -> ConnId -> AgentMsgId -> Maybe MsgReceiptInfo -> m ()
ackMessageAsync c = withAgentEnv c .:: ackMessageAsync' c

-- | Switch connection to the new receive queue
switchConnectionAsync :: AgentErrorMonad m => AgentClient -> ACorrId -> ConnId -> m ConnectionStats
switchConnectionAsync c = withAgentEnv c .: switchConnectionAsync' c

-- | Delete SMP agent connection (DEL command) asynchronously, no synchronous response
deleteConnectionAsync :: AgentErrorMonad m => AgentClient -> Bool -> ConnId -> m ()
deleteConnectionAsync c waitDelivery = withAgentEnv c . deleteConnectionAsync' c waitDelivery

-- | Delete SMP agent connections using batch commands asynchronously, no synchronous response
deleteConnectionsAsync :: AgentErrorMonad m => AgentClient -> Bool -> [ConnId] -> m ()
deleteConnectionsAsync c waitDelivery = withAgentEnv c . deleteConnectionsAsync' c waitDelivery

-- | Create SMP agent connection (NEW command)
createConnection :: AgentErrorMonad m => AgentClient -> UserId -> Bool -> SConnectionMode c -> Maybe CRClientData -> CR.InitialKeys -> SubscriptionMode -> m (ConnId, ConnectionRequestUri c)
createConnection c userId enableNtfs = withAgentEnv c .:: newConn c userId "" enableNtfs

-- | Join SMP agent connection (JOIN command)
joinConnection :: AgentErrorMonad m => AgentClient -> UserId -> Bool -> ConnectionRequestUri c -> ConnInfo -> CR.PQEncryption -> SubscriptionMode -> m ConnId
joinConnection c userId enableNtfs = withAgentEnv c .:: joinConn c userId "" enableNtfs

-- | Allow connection to continue after CONF notification (LET command)
allowConnection :: AgentErrorMonad m => AgentClient -> ConnId -> ConfirmationId -> ConnInfo -> m ()
allowConnection c = withAgentEnv c .:. allowConnection' c

-- | Accept contact after REQ notification (ACPT command)
acceptContact :: AgentErrorMonad m => AgentClient -> Bool -> ConfirmationId -> ConnInfo -> CR.PQEncryption -> SubscriptionMode -> m ConnId
acceptContact c enableNtfs = withAgentEnv c .:: acceptContact' c "" enableNtfs

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
sendMessage :: AgentErrorMonad m => AgentClient -> ConnId -> CR.PQEncryption -> MsgFlags -> MsgBody -> m (AgentMsgId, CR.PQEncryption)
sendMessage c = withAgentEnv c .:: sendMessage' c

type MsgReq = (ConnId, MsgFlags, MsgBody)

-- | Send multiple messages to different connections (SEND command)
sendMessages :: MonadUnliftIO m => AgentClient -> CR.PQEncryption -> [MsgReq] -> m [Either AgentErrorType (AgentMsgId, CR.PQEncryption)]
sendMessages c = withAgentEnv c .: sendMessages' c

sendMessagesB :: (MonadUnliftIO m, Traversable t) => AgentClient -> CR.PQEncryption -> t (Either AgentErrorType MsgReq) -> m (t (Either AgentErrorType (AgentMsgId, CR.PQEncryption)))
sendMessagesB c = withAgentEnv c .: sendMessagesB' c

ackMessage :: AgentErrorMonad m => AgentClient -> ConnId -> AgentMsgId -> Maybe MsgReceiptInfo -> m ()
ackMessage c = withAgentEnv c .:. ackMessage' c

-- | Switch connection to the new receive queue
switchConnection :: AgentErrorMonad m => AgentClient -> ConnId -> m ConnectionStats
switchConnection c = withAgentEnv c . switchConnection' c

-- | Abort switching connection to the new receive queue
abortConnectionSwitch :: AgentErrorMonad m => AgentClient -> ConnId -> m ConnectionStats
abortConnectionSwitch c = withAgentEnv c . abortConnectionSwitch' c

-- | Re-synchronize connection ratchet keys
synchronizeRatchet :: AgentErrorMonad m => AgentClient -> ConnId -> CR.PQEncryption -> Bool -> m ConnectionStats
synchronizeRatchet c = withAgentEnv c .:. synchronizeRatchet' c

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
testProtocolServer :: forall p m. (ProtocolTypeI p, AgentErrorMonad m) => AgentClient -> UserId -> ProtoServerWithAuth p -> m (Maybe ProtocolTestFailure)
testProtocolServer c userId srv = withAgentEnv c $ case protocolTypeI @p of
  SPSMP -> runSMPServerTest c userId srv
  SPXFTP -> runXFTPServerTest c userId srv
  SPNTF -> runNTFServerTest c userId srv

setNtfServers :: MonadUnliftIO m => AgentClient -> [NtfServer] -> m ()
setNtfServers c = withAgentEnv c . setNtfServers' c

-- | set SOCKS5 proxy on/off and optionally set TCP timeout
setNetworkConfig :: MonadUnliftIO m => AgentClient -> NetworkConfig -> m ()
setNetworkConfig c cfg' = do
  cfg <- atomically $ do
    swapTVar (useNetworkConfig c) cfg'
  when (cfg /= cfg') $ reconnectAllServers c

getNetworkConfig :: AgentErrorMonad m => AgentClient -> m NetworkConfig
getNetworkConfig = readTVarIO . useNetworkConfig

reconnectAllServers :: MonadUnliftIO m => AgentClient -> m ()
reconnectAllServers c = liftIO $ do
  reconnectServerClients c smpClients
  reconnectServerClients c ntfClients

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

getNtfToken :: AgentErrorMonad m => AgentClient -> m (DeviceToken, NtfTknStatus, NotificationsMode, NtfServer)
getNtfToken c = withAgentEnv c $ getNtfToken' c

getNtfTokenData :: AgentErrorMonad m => AgentClient -> m NtfToken
getNtfTokenData c = withAgentEnv c $ getNtfTokenData' c

-- | Set connection notifications on/off
toggleConnectionNtfs :: AgentErrorMonad m => AgentClient -> ConnId -> Bool -> m ()
toggleConnectionNtfs c = withAgentEnv c .: toggleConnectionNtfs' c

xftpStartWorkers :: AgentErrorMonad m => AgentClient -> Maybe FilePath -> m ()
xftpStartWorkers c = withAgentEnv c . startXFTPWorkers c

-- | Receive XFTP file
xftpReceiveFile :: AgentErrorMonad m => AgentClient -> UserId -> ValidFileDescription 'FRecipient -> Maybe CryptoFileArgs -> m RcvFileId
xftpReceiveFile c = withAgentEnv c .:. xftpReceiveFile' c

-- | Delete XFTP rcv file (deletes work files from file system and db records)
xftpDeleteRcvFile :: AgentErrorMonad m => AgentClient -> RcvFileId -> m ()
xftpDeleteRcvFile c = withAgentEnv c . xftpDeleteRcvFile' c

-- | Delete multiple rcv files, batching operations when possible (deletes work files from file system and db records)
xftpDeleteRcvFiles :: AgentErrorMonad m => AgentClient -> [RcvFileId] -> m ()
xftpDeleteRcvFiles c = withAgentEnv c . xftpDeleteRcvFiles' c

-- | Send XFTP file
xftpSendFile :: AgentErrorMonad m => AgentClient -> UserId -> CryptoFile -> Int -> m SndFileId
xftpSendFile c = withAgentEnv c .:. xftpSendFile' c

-- | Send XFTP file
xftpSendDescription :: AgentErrorMonad m => AgentClient -> UserId -> ValidFileDescription 'FRecipient -> Int -> m SndFileId
xftpSendDescription c = withAgentEnv c .:. xftpSendDescription' c

-- | Delete XFTP snd file internally (deletes work files from file system and db records)
xftpDeleteSndFileInternal :: AgentErrorMonad m => AgentClient -> SndFileId -> m ()
xftpDeleteSndFileInternal c = withAgentEnv c . deleteSndFileInternal c

-- | Delete multiple snd files internally, batching operations when possible (deletes work files from file system and db records)
xftpDeleteSndFilesInternal :: AgentErrorMonad m => AgentClient -> [SndFileId] -> m ()
xftpDeleteSndFilesInternal c = withAgentEnv c . deleteSndFilesInternal c

-- | Delete XFTP snd file chunks on servers
xftpDeleteSndFileRemote :: AgentErrorMonad m => AgentClient -> UserId -> SndFileId -> ValidFileDescription 'FSender -> m ()
xftpDeleteSndFileRemote c = withAgentEnv c .:. deleteSndFileRemote c

-- | Delete XFTP snd file chunks on servers for multiple snd files, batching operations when possible
xftpDeleteSndFilesRemote :: AgentErrorMonad m => AgentClient -> UserId -> [(SndFileId, ValidFileDescription 'FSender)] -> m ()
xftpDeleteSndFilesRemote c = withAgentEnv c .: deleteSndFilesRemote c

-- | Create new remote host pairing
rcNewHostPairing :: AgentErrorMonad m => AgentClient -> m RCHostPairing
rcNewHostPairing c = withAgentEnv c $ liftIO . newRCHostPairing =<< asks random

-- | start TLS server for remote host with optional multicast
rcConnectHost :: AgentErrorMonad m => AgentClient -> RCHostPairing -> J.Value -> Bool -> Maybe RCCtrlAddress -> Maybe Word16 -> m RCHostConnection
rcConnectHost c = withAgentEnv c .::. rcConnectHost'

rcConnectHost' :: AgentMonad m => RCHostPairing -> J.Value -> Bool -> Maybe RCCtrlAddress -> Maybe Word16 -> m RCHostConnection
rcConnectHost' pairing ctrlAppInfo multicast rcAddr_ port_ = do
  drg <- asks random
  liftError RCP $ connectRCHost drg pairing ctrlAppInfo multicast rcAddr_ port_

-- | connect to remote controller via URI
rcConnectCtrl :: AgentErrorMonad m => AgentClient -> RCVerifiedInvitation -> Maybe RCCtrlPairing -> J.Value -> m RCCtrlConnection
rcConnectCtrl c = withAgentEnv c .:. rcConnectCtrl'

rcConnectCtrl' :: AgentMonad m => RCVerifiedInvitation -> Maybe RCCtrlPairing -> J.Value -> m RCCtrlConnection
rcConnectCtrl' verifiedInv pairing_ hostAppInfo = do
  drg <- asks random
  liftError RCP $ connectRCCtrl drg verifiedInv pairing_ hostAppInfo

-- | connect to known remote controller via multicast
rcDiscoverCtrl :: AgentErrorMonad m => AgentClient -> NonEmpty RCCtrlPairing -> m (RCCtrlPairing, RCVerifiedInvitation)
rcDiscoverCtrl c = withAgentEnv c . rcDiscoverCtrl'

rcDiscoverCtrl' :: AgentMonad m => NonEmpty RCCtrlPairing -> m (RCCtrlPairing, RCVerifiedInvitation)
rcDiscoverCtrl' pairings = do
  subs <- asks multicastSubscribers
  liftError RCP $ discoverRCCtrl subs pairings

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
getAgentClient :: AgentMonad' m => Int -> InitialAgentServers -> m AgentClient
getAgentClient clientId initServers = ask >>= atomically . newAgentClient clientId initServers
{-# INLINE getAgentClient #-}

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
    NEW enableNtfs (ACM cMode) pqIK subMode -> second (INV . ACR cMode) <$> newConn c userId connId enableNtfs cMode Nothing pqIK subMode
    JOIN enableNtfs (ACR _ cReq) pqEnc subMode connInfo -> (,OK) <$> joinConn c userId connId enableNtfs cReq connInfo pqEnc subMode
    LET confId ownCInfo -> allowConnection' c connId confId ownCInfo $> (connId, OK)
    ACPT invId pqEnc ownCInfo -> (,OK) <$> acceptContact' c connId True invId ownCInfo pqEnc SMSubscribe
    RJCT invId -> rejectContact' c connId invId $> (connId, OK)
    SUB -> subscribeConnection' c connId $> (connId, OK)
    SEND pqEnc msgFlags msgBody -> (connId,) . uncurry MID <$> sendMessage' c connId pqEnc msgFlags msgBody
    ACK msgId rcptInfo_ -> ackMessage' c connId msgId rcptInfo_ $> (connId, OK)
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
    then withStore c (`setUserDeleted` userId) >>= deleteConnectionsAsync_ delUser c False
    else withStore c (`deleteUserRecord` userId)
  atomically $ TM.delete userId $ smpServers c
  where
    delUser =
      whenM (withStore' c (`deleteUserWithoutConns` userId)) . atomically $
        writeTBQueue (subQ c) ("", "", APC SAENone $ DEL_USER userId)

newConnAsync :: forall m c. (AgentMonad m, ConnectionModeI c) => AgentClient -> UserId -> ACorrId -> Bool -> SConnectionMode c -> CR.InitialKeys -> SubscriptionMode -> m ConnId
newConnAsync c userId corrId enableNtfs cMode pqInitKeys subMode = do
  connId <- newConnNoQueues c userId "" enableNtfs cMode (CR.connPQEncryption pqInitKeys)
  enqueueCommand c corrId connId Nothing $ AClientCommand $ APC SAEConn $ NEW enableNtfs (ACM cMode) pqInitKeys subMode
  pure connId

newConnNoQueues :: AgentMonad m => AgentClient -> UserId -> ConnId -> Bool -> SConnectionMode c -> CR.PQEncryption -> m ConnId
newConnNoQueues c userId connId enableNtfs cMode pqEncryption = do
  g <- asks random
  connAgentVersion <- asks $ maxVersion . smpAgentVRange . config
  let cData = ConnData {userId, connId, connAgentVersion, enableNtfs, lastExternalSndId = 0, deleted = False, ratchetSyncState = RSOk, pqEncryption}
  withStore c $ \db -> createNewConn db g cData cMode

joinConnAsync :: AgentMonad m => AgentClient -> UserId -> ACorrId -> Bool -> ConnectionRequestUri c -> ConnInfo -> CR.PQEncryption -> SubscriptionMode -> m ConnId
joinConnAsync c userId corrId enableNtfs cReqUri@(CRInvitationUri ConnReqUriData {crAgentVRange} _) cInfo pqEncryption subMode = do
  withInvLock c (strEncode cReqUri) "joinConnAsync" $ do
    aVRange <- asks $ smpAgentVRange . config
    case crAgentVRange `compatibleVersion` aVRange of
      Just (Compatible connAgentVersion) -> do
        g <- asks random
        let cData = ConnData {userId, connId = "", connAgentVersion, enableNtfs, lastExternalSndId = 0, deleted = False, ratchetSyncState = RSOk, pqEncryption}
        connId <- withStore c $ \db -> createNewConn db g cData SCMInvitation
        enqueueCommand c corrId connId Nothing $ AClientCommand $ APC SAEConn $ JOIN enableNtfs (ACR sConnectionMode cReqUri) pqEncryption subMode cInfo
        pure connId
      _ -> throwError $ AGENT A_VERSION
joinConnAsync _c _userId _corrId _enableNtfs (CRContactUri _) _subMode _cInfo _pqEncryption =
  throwError $ CMD PROHIBITED

allowConnectionAsync' :: AgentMonad m => AgentClient -> ACorrId -> ConnId -> ConfirmationId -> ConnInfo -> m ()
allowConnectionAsync' c corrId connId confId ownConnInfo =
  withStore c (`getConn` connId) >>= \case
    SomeConn _ (RcvConnection _ RcvQueue {server}) ->
      enqueueCommand c corrId connId (Just server) $ AClientCommand $ APC SAEConn $ LET confId ownConnInfo
    _ -> throwError $ CMD PROHIBITED

acceptContactAsync' :: AgentMonad m => AgentClient -> ACorrId -> Bool -> InvitationId -> ConnInfo -> CR.PQEncryption -> SubscriptionMode -> m ConnId
acceptContactAsync' c corrId enableNtfs invId ownConnInfo pqEnc subMode = do
  Invitation {contactConnId, connReq} <- withStore c (`getInvitation` invId)
  withStore c (`getConn` contactConnId) >>= \case
    SomeConn _ (ContactConnection ConnData {userId} _) -> do
      withStore' c $ \db -> acceptInvitation db invId ownConnInfo
      joinConnAsync c userId corrId enableNtfs connReq ownConnInfo pqEnc subMode `catchAgentError` \err -> do
        withStore' c (`unacceptInvitation` invId)
        throwError err
    _ -> throwError $ CMD PROHIBITED

ackMessageAsync' :: forall m. AgentMonad m => AgentClient -> ACorrId -> ConnId -> AgentMsgId -> Maybe MsgReceiptInfo -> m ()
ackMessageAsync' c corrId connId msgId rcptInfo_ = do
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
      let mId = InternalId msgId
      RcvMsg {msgType} <- withStoreCtx "ackMessageAsync': getRcvMsg" c $ \db -> getRcvMsg db connId mId
      when (isJust rcptInfo_ && msgType /= AM_A_MSG_) $ throwError $ CMD PROHIBITED
      (RcvQueue {server}, _) <- withStoreCtx "ackMessageAsync': setMsgUserAck" c $ \db -> setMsgUserAck db connId mId
      enqueueCommand c corrId connId (Just server) . AClientCommand $ APC SAEConn $ ACK msgId rcptInfo_

deleteConnectionAsync' :: forall m. AgentMonad m => AgentClient -> Bool -> ConnId -> m ()
deleteConnectionAsync' c waitDelivery connId = deleteConnectionsAsync' c waitDelivery [connId]

deleteConnectionsAsync' :: AgentMonad m => AgentClient -> Bool -> [ConnId] -> m ()
deleteConnectionsAsync' = deleteConnectionsAsync_ $ pure ()

deleteConnectionsAsync_ :: forall m. AgentMonad m => m () -> AgentClient -> Bool -> [ConnId] -> m ()
deleteConnectionsAsync_ onSuccess c waitDelivery connIds = case connIds of
  [] -> onSuccess
  _ -> do
    (_, rqs, connIds') <- prepareDeleteConnections_ getConns c waitDelivery connIds
    withStore' c $ \db -> forM_ connIds' $ setConnDeleted db waitDelivery
    void . forkIO $
      withLock (deleteLock c) "deleteConnectionsAsync" $
        deleteConnQueues c waitDelivery True rqs >> onSuccess

-- | Add connection to the new receive queue
switchConnectionAsync' :: AgentMonad m => AgentClient -> ACorrId -> ConnId -> m ConnectionStats
switchConnectionAsync' c corrId connId =
  withConnLock c connId "switchConnectionAsync" $
    withStore c (`getConn` connId) >>= \case
      SomeConn _ (DuplexConnection cData rqs@(rq :| _rqs) sqs)
        | isJust (switchingRQ rqs) -> throwError $ CMD PROHIBITED
        | otherwise -> do
            when (ratchetSyncSendProhibited cData) $ throwError $ CMD PROHIBITED
            rq1 <- withStore' c $ \db -> setRcvSwitchStatus db rq $ Just RSSwitchStarted
            enqueueCommand c corrId connId Nothing $ AClientCommand $ APC SAEConn SWCH
            let rqs' = updatedQs rq1 rqs
            pure . connectionStats $ DuplexConnection cData rqs' sqs
      _ -> throwError $ CMD PROHIBITED

newConn :: AgentMonad m => AgentClient -> UserId -> ConnId -> Bool -> SConnectionMode c -> Maybe CRClientData -> CR.InitialKeys -> SubscriptionMode -> m (ConnId, ConnectionRequestUri c)
newConn c userId connId enableNtfs cMode clientData pqInitKeys subMode =
  getSMPServer c userId >>= newConnSrv c userId connId enableNtfs cMode clientData pqInitKeys subMode

newConnSrv :: AgentMonad m => AgentClient -> UserId -> ConnId -> Bool -> SConnectionMode c -> Maybe CRClientData -> CR.InitialKeys -> SubscriptionMode -> SMPServerWithAuth -> m (ConnId, ConnectionRequestUri c)
newConnSrv c userId connId enableNtfs cMode clientData pqInitKeys subMode srv = do
  connId' <- newConnNoQueues c userId connId enableNtfs cMode (CR.connPQEncryption pqInitKeys)
  newRcvConnSrv c userId connId' enableNtfs cMode clientData pqInitKeys subMode srv

newRcvConnSrv :: AgentMonad m => AgentClient -> UserId -> ConnId -> Bool -> SConnectionMode c -> Maybe CRClientData -> CR.InitialKeys -> SubscriptionMode -> SMPServerWithAuth -> m (ConnId, ConnectionRequestUri c)
newRcvConnSrv c userId connId enableNtfs cMode clientData pqInitKeys subMode srv = do
  case (cMode, pqInitKeys) of
    (SCMContact, CR.IKUsePQ) -> throwError $ CMD PROHIBITED
    _ -> pure ()
  AgentConfig {smpClientVRange, smpAgentVRange, e2eEncryptVRange} <- asks config
  (rq, qUri) <- newRcvQueue c userId connId srv smpClientVRange subMode `catchAgentError` \e -> liftIO (print e) >> throwError e
  rq' <- withStore c $ \db -> updateNewConnRcv db connId rq
  case subMode of
    SMOnlyCreate -> pure ()
    SMSubscribe -> addSubscription c rq'
  when enableNtfs $ do
    ns <- asks ntfSupervisor
    atomically $ sendNtfSubCommand ns (connId, NSCCreate)
  let crData = ConnReqUriData SSSimplex smpAgentVRange [qUri] clientData
  case cMode of
    SCMContact -> pure (connId, CRContactUri crData)
    SCMInvitation -> do
      g <- asks random
      (pk1, pk2, pKem, e2eRcvParams) <- liftIO $ CR.generateRcvE2EParams g (maxVersion e2eEncryptVRange) (CR.initialPQEncryption pqInitKeys)
      withStore' c $ \db -> createRatchetX3dhKeys db connId pk1 pk2 pKem
      pure (connId, CRInvitationUri crData $ toVersionRangeT e2eRcvParams e2eEncryptVRange)

joinConn :: AgentMonad m => AgentClient -> UserId -> ConnId -> Bool -> ConnectionRequestUri c -> ConnInfo -> CR.PQEncryption -> SubscriptionMode -> m ConnId
joinConn c userId connId enableNtfs cReq cInfo pqEnc subMode = do
  srv <- case cReq of
    CRInvitationUri ConnReqUriData {crSmpQueues = q :| _} _ ->
      getNextServer c userId [qServer q]
    _ -> getSMPServer c userId
  joinConnSrv c userId connId enableNtfs cReq cInfo pqEnc subMode srv

startJoinInvitation :: AgentMonad m => UserId -> ConnId -> Bool -> ConnectionRequestUri 'CMInvitation -> CR.PQEncryption -> m (Compatible Version, ConnData, NewSndQueue, CR.Ratchet 'C.X448, CR.SndE2ERatchetParams 'C.X448)
startJoinInvitation userId connId enableNtfs (CRInvitationUri ConnReqUriData {crAgentVRange, crSmpQueues = (qUri :| _)} e2eRcvParamsUri) pqEncryption = do
  AgentConfig {smpClientVRange, smpAgentVRange, e2eEncryptVRange} <- asks config
  case ( qUri `compatibleVersion` smpClientVRange,
         e2eRcvParamsUri `compatibleVersion` e2eEncryptVRange,
         crAgentVRange `compatibleVersion` smpAgentVRange
       ) of
    (Just qInfo, Just (Compatible e2eRcvParams@(CR.E2ERatchetParams v _ rcDHRr kem_)), Just aVersion@(Compatible connAgentVersion)) -> do
      g <- asks random
      (pk1, pk2, pKem, e2eSndParams) <- liftIO $ CR.generateSndE2EParams g v (CR.replyKEM_ pqEncryption kem_)
      (_, rcDHRs) <- atomically $ C.generateKeyPair g
      -- TODO PQ generate KEM keypair if needed - is it done?
      rcParams <- liftEitherWith cryptoError $ CR.pqX3dhSnd pk1 pk2 pKem e2eRcvParams
      let rc = CR.initSndRatchet e2eEncryptVRange rcDHRr rcDHRs rcParams
      q <- newSndQueue userId "" qInfo
      let cData = ConnData {userId, connId, connAgentVersion, enableNtfs, lastExternalSndId = 0, deleted = False, ratchetSyncState = RSOk, pqEncryption}
      pure (aVersion, cData, q, rc, e2eSndParams)
    _ -> throwError $ AGENT A_VERSION

joinConnSrv :: AgentMonad m => AgentClient -> UserId -> ConnId -> Bool -> ConnectionRequestUri c -> ConnInfo -> CR.PQEncryption -> SubscriptionMode -> SMPServerWithAuth -> m ConnId
joinConnSrv c userId connId enableNtfs inv@CRInvitationUri {} cInfo pqEnc subMode srv =
  withInvLock c (strEncode inv) "joinConnSrv" $ do
    (aVersion, cData, q, rc, e2eSndParams) <- startJoinInvitation userId connId enableNtfs inv pqEnc
    g <- asks random
    (connId', sq) <- withStore c $ \db -> runExceptT $ do
      r@(connId', _) <- ExceptT $ createSndConn db g cData q
      liftIO $ createRatchet db connId' rc
      pure r
    let cData' = (cData :: ConnData) {connId = connId'}
    tryError (confirmQueue aVersion c cData' sq srv cInfo (Just e2eSndParams) (Just pqEnc) subMode) >>= \case
      Right _ -> pure connId'
      Left e -> do
        -- possible improvement: recovery for failure on network timeout, see rfcs/2022-04-20-smp-conf-timeout-recovery.md
        void $ withStore' c $ \db -> deleteConn db Nothing connId'
        throwError e
joinConnSrv c userId connId enableNtfs (CRContactUri ConnReqUriData {crAgentVRange, crSmpQueues = (qUri :| _)}) cInfo pqEnc subMode srv = do
  aVRange <- asks $ smpAgentVRange . config
  clientVRange <- asks $ smpClientVRange . config
  case ( qUri `compatibleVersion` clientVRange,
         crAgentVRange `compatibleVersion` aVRange
       ) of
    (Just qInfo, Just vrsn) -> do
      (connId', cReq) <- newConnSrv c userId connId enableNtfs SCMInvitation Nothing (CR.joinContactInitialKeys pqEnc) subMode srv
      sendInvitation c userId qInfo vrsn cReq cInfo
      pure connId'
    _ -> throwError $ AGENT A_VERSION

joinConnSrvAsync :: AgentMonad m => AgentClient -> UserId -> ConnId -> Bool -> ConnectionRequestUri c -> ConnInfo -> CR.PQEncryption -> SubscriptionMode -> SMPServerWithAuth -> m ()
joinConnSrvAsync c userId connId enableNtfs inv@CRInvitationUri {} cInfo pqEnc subMode srv = do
  (_aVersion, cData, q, rc, e2eSndParams) <- startJoinInvitation userId connId enableNtfs inv pqEnc
  q' <- withStore c $ \db -> runExceptT $ do
    liftIO $ createRatchet db connId rc
    ExceptT $ updateNewConnSnd db connId q
  confirmQueueAsync c cData q' srv cInfo (Just e2eSndParams) pqEnc subMode
joinConnSrvAsync _c _userId _connId _enableNtfs (CRContactUri _) _cInfo _subMode _pqEnc _srv = do
  throwError $ CMD PROHIBITED

createReplyQueue :: AgentMonad m => AgentClient -> ConnData -> SndQueue -> SubscriptionMode -> SMPServerWithAuth -> m SMPQueueInfo
createReplyQueue c ConnData {userId, connId, enableNtfs} SndQueue {smpClientVersion} subMode srv = do
  (rq, qUri) <- newRcvQueue c userId connId srv (versionToRange smpClientVersion) subMode
  let qInfo = toVersionT qUri smpClientVersion
  rq' <- withStore c $ \db -> upgradeSndConnToDuplex db connId rq
  case subMode of
    SMOnlyCreate -> pure ()
    SMSubscribe -> addSubscription c rq'
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
acceptContact' :: AgentMonad m => AgentClient -> ConnId -> Bool -> InvitationId -> ConnInfo -> CR.PQEncryption -> SubscriptionMode -> m ConnId
acceptContact' c connId enableNtfs invId ownConnInfo pqEnc subMode = withConnLock c connId "acceptContact" $ do
  Invitation {contactConnId, connReq} <- withStore c (`getInvitation` invId)
  withStore c (`getConn` contactConnId) >>= \case
    SomeConn _ (ContactConnection ConnData {userId} _) -> do
      withStore' c $ \db -> acceptInvitation db invId ownConnInfo
      joinConn c userId connId enableNtfs connReq ownConnInfo pqEnc subMode `catchAgentError` \err -> do
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
    sndSubResult SndQueue {status} = case status of
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
            let cmd = if enableNtfs $ toConnData conn then NSCCreate else NSCDelete
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
      ntfMsgMeta <- (eitherToMaybe . smpDecode <$> agentCbDecrypt rcvNtfDhSecret nmsgNonce encNMsgMeta) `catchAgentError` \_ -> pure Nothing
      maxMsgs <- asks $ ntfMaxMessages . config
      (NotificationInfo {ntfConnId, ntfTs, ntfMsgMeta},) <$> getNtfMessages ntfConnId ntfMsgMeta maxMsgs
    _ -> throwError $ CMD PROHIBITED
  where
    getNtfMessages ntfConnId nMeta = getMsg
      where
        getMsg 0 = pure []
        getMsg n =
          getConnectionMessage' c ntfConnId >>= \case
            Just m
              | lastMsg m -> pure [m]
              | otherwise -> (m :) <$> getMsg (n - 1)
            Nothing -> pure []
        lastMsg SMP.SMPMsgMeta {msgId, msgTs, msgFlags} = case nMeta of
          Just SMP.NMsgMeta {msgId = msgId', msgTs = msgTs'} -> msgId == msgId' || msgTs > msgTs'
          Nothing -> SMP.notification msgFlags

-- | Send message to the connection (SEND command) in Reader monad
sendMessage' :: forall m. AgentMonad m => AgentClient -> ConnId -> CR.PQEncryption -> MsgFlags -> MsgBody -> m (AgentMsgId, CR.PQEncryption)
sendMessage' c connId pqEnc msgFlags msg = liftEither . runIdentity =<< sendMessagesB' c pqEnc (Identity (Right (connId, msgFlags, msg)))

-- | Send multiple messages to different connections (SEND command) in Reader monad
sendMessages' :: forall m. AgentMonad' m => AgentClient -> CR.PQEncryption -> [MsgReq] -> m [Either AgentErrorType (AgentMsgId, CR.PQEncryption)]
sendMessages' c pqEnc = sendMessagesB' c pqEnc . map Right

sendMessagesB' :: forall m t. (AgentMonad' m, Traversable t) => AgentClient -> CR.PQEncryption -> t (Either AgentErrorType MsgReq) -> m (t (Either AgentErrorType (AgentMsgId, CR.PQEncryption)))
sendMessagesB' c pqEnc reqs = withConnLocks c connIds "sendMessages" $ do
  reqs' <- withStoreBatch c (\db -> fmap (bindRight $ \req@(connId, _, _) -> bimap storeError (req,) <$> getConn db connId) reqs)
  let reqs'' = fmap (>>= prepareConn) reqs'
  enqueueMessagesB c (Just pqEnc) reqs''
  where
    prepareConn :: (MsgReq, SomeConn) -> Either AgentErrorType (ConnData, NonEmpty SndQueue, MsgFlags, AMessage)
    prepareConn ((_, msgFlags, msg), SomeConn _ conn) = case conn of
      DuplexConnection cData _ sqs -> prepareMsg cData sqs
      SndConnection cData sq -> prepareMsg cData [sq]
      _ -> Left $ CONN SIMPLEX
      where
        prepareMsg :: ConnData -> NonEmpty SndQueue -> Either AgentErrorType (ConnData, NonEmpty SndQueue, MsgFlags, AMessage)
        prepareMsg cData sqs
          | ratchetSyncSendProhibited cData = Left $ CMD PROHIBITED
          | otherwise = Right (cData, sqs, msgFlags, A_MSG msg)
    connIds = map (\(connId, _, _) -> connId) $ rights $ toList reqs

-- / async command processing v v v

enqueueCommand :: AgentMonad m => AgentClient -> ACorrId -> ConnId -> Maybe SMPServer -> AgentCommand -> m ()
enqueueCommand c corrId connId server aCommand = do
  withStore c $ \db -> createCommand db corrId connId server aCommand
  void $ getAsyncCmdWorker True c server

resumeSrvCmds :: forall m. AgentMonad' m => AgentClient -> Maybe SMPServer -> m ()
resumeSrvCmds = void .: getAsyncCmdWorker False

resumeConnCmds :: forall m. AgentMonad m => AgentClient -> ConnId -> m ()
resumeConnCmds c connId =
  unlessM connQueued $
    withStore' c (`getPendingCommandServers` connId)
      >>= mapM_ (resumeSrvCmds c)
  where
    connQueued = atomically $ isJust <$> TM.lookupInsert connId True (connCmdsQueued c)

getAsyncCmdWorker :: AgentMonad' m => Bool -> AgentClient -> Maybe SMPServer -> m Worker
getAsyncCmdWorker hasWork c server =
  getAgentWorker "async_cmd" hasWork c server (asyncCmdWorkers c) (runCommandProcessing c server)

runCommandProcessing :: forall m. AgentMonad m => AgentClient -> Maybe SMPServer -> Worker -> m ()
runCommandProcessing c@AgentClient {subQ} server_ Worker {doWork} = do
  ri <- asks $ messageRetryInterval . config -- different retry interval?
  forever $ do
    atomically $ endAgentOperation c AOSndNetwork
    waitForWork doWork
    atomically $ throwWhenInactive c
    atomically $ beginAgentOperation c AOSndNetwork
    withWork c doWork (`getPendingServerCommand` server_) $ processCmd (riFast ri)
  where
    processCmd :: RetryInterval -> PendingCommand -> m ()
    processCmd ri PendingCommand {cmdId, corrId, userId, connId, command} = case command of
      AClientCommand (APC _ cmd) -> case cmd of
        NEW enableNtfs (ACM cMode) pqEnc subMode -> noServer $ do
          usedSrvs <- newTVarIO ([] :: [SMPServer])
          tryCommand . withNextSrv c userId usedSrvs [] $ \srv -> do
            (_, cReq) <- newRcvConnSrv c userId connId enableNtfs cMode Nothing pqEnc subMode srv
            notify $ INV (ACR cMode cReq)
        JOIN enableNtfs (ACR _ cReq@(CRInvitationUri ConnReqUriData {crSmpQueues = q :| _} _)) pqEnc subMode connInfo -> noServer $ do
          let initUsed = [qServer q]
          usedSrvs <- newTVarIO initUsed
          tryCommand . withNextSrv c userId usedSrvs initUsed $ \srv -> do
            joinConnSrvAsync c userId connId enableNtfs cReq connInfo pqEnc subMode srv
            notify OK
        LET confId ownCInfo -> withServer' . tryCommand $ allowConnection' c connId confId ownCInfo >> notify OK
        ACK msgId rcptInfo_ -> withServer' . tryCommand $ ackMessage' c connId msgId rcptInfo_ >> notify OK
        SWCH ->
          noServer . tryCommand . withConnLock c connId "switchConnection" $
            withStore c (`getConn` connId) >>= \case
              SomeConn _ conn@(DuplexConnection _ (replaced :| _rqs) _) ->
                switchDuplexConnection c conn replaced >>= notify . SWITCH QDRcv SPStarted
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
          void $ enqueueMessage c cData sq Nothing SMP.MsgFlags {notification = True} HELLO
        -- ICDeleteConn is no longer used, but it can be present in old client databases
        ICDeleteConn -> withStore' c (`deleteCommand` cmdId)
        ICDeleteRcvQueue rId -> withServer $ \srv -> tryWithLock "ICDeleteRcvQueue" $ do
          rq <- withStore c (\db -> getDeletedRcvQueue db connId srv rId)
          deleteQueue c rq
          withStore' c (`deleteConnRcvQueue` rq)
        ICQSecure rId senderKey ->
          withServer $ \srv -> tryWithLock "ICQSecure" . withDuplexConn $ \(DuplexConnection cData rqs sqs) ->
            case find (sameQueue (srv, rId)) rqs of
              Just rq'@RcvQueue {server, sndId, status, dbReplaceQueueId = Just replaceQId} ->
                case find ((replaceQId ==) . dbQId) rqs of
                  Just rq1 -> when (status == Confirmed) $ do
                    secureQueue c rq' senderKey
                    withStore' c $ \db -> setRcvQueueStatus db rq' Secured
                    void . enqueueMessages c cData sqs Nothing SMP.noMsgFlags $ QUSE [((server, sndId), True)]
                    rq1' <- withStore' c $ \db -> setRcvSwitchStatus db rq1 $ Just RSSendingQUSE
                    let rqs' = updatedQs rq1' rqs
                        conn' = DuplexConnection cData rqs' sqs
                    notify . SWITCH QDRcv SPSecured $ connectionStats conn'
                  _ -> internalErr "ICQSecure: no switching queue found"
              _ -> internalErr "ICQSecure: queue address not found in connection"
        ICQDelete rId -> do
          withServer $ \srv -> tryWithLock "ICQDelete" . withDuplexConn $ \(DuplexConnection cData rqs sqs) -> do
            case removeQ (srv, rId) rqs of
              Nothing -> internalErr "ICQDelete: queue address not found in connection"
              Just (rq'@RcvQueue {primary}, rq'' : rqs')
                | primary -> internalErr "ICQDelete: cannot delete primary rcv queue"
                | otherwise -> do
                    checkRQSwchStatus rq' RSReceivedMessage
                    tryError (deleteQueue c rq') >>= \case
                      Right () -> finalizeSwitch
                      Left e
                        | temporaryOrHostError e -> throwError e
                        | otherwise -> finalizeSwitch >> throwError e
                where
                  finalizeSwitch = do
                    withStore' c $ \db -> deleteConnRcvQueue db rq'
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
          secure :: RcvQueue -> SMP.SndPublicAuthKey -> m ()
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

enqueueMessages :: AgentMonad m => AgentClient -> ConnData -> NonEmpty SndQueue -> Maybe CR.PQEncryption -> MsgFlags -> AMessage -> m (AgentMsgId, CR.PQEncryption)
enqueueMessages c cData sqs pqEnc_ msgFlags aMessage = do
  when (ratchetSyncSendProhibited cData) $ throwError $ INTERNAL "enqueueMessages: ratchet is not synchronized"
  enqueueMessages' c cData sqs pqEnc_ msgFlags aMessage

enqueueMessages' :: AgentMonad m => AgentClient -> ConnData -> NonEmpty SndQueue -> Maybe CR.PQEncryption -> MsgFlags -> AMessage -> m (AgentMsgId, CR.PQEncryption)
enqueueMessages' c cData sqs pqEnc_ msgFlags aMessage =
  liftEither . runIdentity =<< enqueueMessagesB c pqEnc_ (Identity (Right (cData, sqs, msgFlags, aMessage)))

enqueueMessagesB :: (AgentMonad' m, Traversable t) => AgentClient -> Maybe CR.PQEncryption -> t (Either AgentErrorType (ConnData, NonEmpty SndQueue, MsgFlags, AMessage)) -> m (t (Either AgentErrorType (AgentMsgId, CR.PQEncryption)))
enqueueMessagesB c pqEnc_ reqs = do
  reqs' <- enqueueMessageB c pqEnc_ reqs
  enqueueSavedMessageB c $ mapMaybe snd $ rights $ toList reqs'
  pure $ fst <$$> reqs'

isActiveSndQ :: SndQueue -> Bool
isActiveSndQ SndQueue {status} = status == Secured || status == Active

enqueueMessage :: forall m. AgentMonad m => AgentClient -> ConnData -> SndQueue -> Maybe CR.PQEncryption -> MsgFlags -> AMessage -> m (AgentMsgId, CR.PQEncryption)
enqueueMessage c cData sq pqEnc_ msgFlags aMessage =
  liftEither . fmap fst . runIdentity =<< enqueueMessageB c pqEnc_ (Identity (Right (cData, [sq], msgFlags, aMessage)))

-- this function is used only for sending messages in batch, it returns the list of successes to enqueue additional deliveries
enqueueMessageB :: forall m t. (AgentMonad' m, Traversable t) => AgentClient -> Maybe CR.PQEncryption -> t (Either AgentErrorType (ConnData, NonEmpty SndQueue, MsgFlags, AMessage)) -> m (t (Either AgentErrorType ((AgentMsgId, CR.PQEncryption), Maybe (ConnData, [SndQueue], AgentMsgId))))
enqueueMessageB c pqEnc_ reqs = do
  aVRange <- asks $ maxVersion . smpAgentVRange . config
  reqMids <- withStoreBatch c $ \db -> fmap (bindRight $ storeSentMsg db aVRange) reqs
  forME reqMids $ \((cData, sq :| sqs, _, _), InternalId msgId, pqSecr) -> do
    submitPendingMsg c cData sq
    let sqs' = filter isActiveSndQ sqs
    pure $ Right ((msgId, pqSecr), if null sqs' then Nothing else Just (cData, sqs', msgId))
  where
    storeSentMsg :: DB.Connection -> Version -> (ConnData, NonEmpty SndQueue, MsgFlags, AMessage) -> IO (Either AgentErrorType ((ConnData, NonEmpty SndQueue, MsgFlags, AMessage), InternalId, CR.PQEncryption))
    storeSentMsg db agentVersion req@(ConnData {connId}, sq :| _, msgFlags, aMessage) = fmap (first storeError) $ runExceptT $ do
      internalTs <- liftIO getCurrentTime
      (internalId, internalSndId, prevMsgHash) <- liftIO $ updateSndIds db connId
      let privHeader = APrivHeader (unSndId internalSndId) prevMsgHash
          agentMsg = AgentMessage privHeader aMessage
          agentMsgStr = smpEncode agentMsg
          internalHash = C.sha256Hash agentMsgStr
      (encAgentMessage, pqEncryption) <- agentRatchetEncrypt db connId agentMsgStr e2eEncUserMsgLength pqEnc_
      let msgBody = smpEncode $ AgentMsgEnvelope {agentVersion, encAgentMessage}
          msgType = agentMessageType agentMsg
          msgData = SndMsgData {internalId, internalSndId, internalTs, msgType, msgFlags, msgBody, pqEncryption, internalHash, prevMsgHash}
      liftIO $ createSndMsg db connId msgData
      liftIO $ createSndMsgDelivery db connId sq internalId
      pure (req, internalId, pqEncryption)

enqueueSavedMessage :: AgentMonad' m => AgentClient -> ConnData -> AgentMsgId -> SndQueue -> m ()
enqueueSavedMessage c cData msgId sq = enqueueSavedMessageB c $ Identity (cData, [sq], msgId)

enqueueSavedMessageB :: (AgentMonad' m, Foldable t) => AgentClient -> t (ConnData, [SndQueue], AgentMsgId) -> m ()
enqueueSavedMessageB c reqs = do
  -- saving to the database is in the start to avoid race conditions when delivery is read from queue before it is saved
  void $ withStoreBatch' c $ \db -> concatMap (storeDeliveries db) reqs
  forM_ reqs $ \(cData, sqs, _) ->
    forM sqs $ submitPendingMsg c cData
  where
    storeDeliveries :: DB.Connection -> (ConnData, [SndQueue], AgentMsgId) -> [IO ()]
    storeDeliveries db (ConnData {connId}, sqs, msgId) = do
      let mId = InternalId msgId
       in map (\sq -> createSndMsgDelivery db connId sq mId) sqs

resumeMsgDelivery :: forall m. AgentMonad' m => AgentClient -> ConnData -> SndQueue -> m ()
resumeMsgDelivery = void .:. getDeliveryWorker False

getDeliveryWorker :: AgentMonad' m => Bool -> AgentClient -> ConnData -> SndQueue -> m (Worker, TMVar ())
getDeliveryWorker hasWork c cData sq =
  getAgentWorker' fst mkLock "msg_delivery" hasWork c (qAddress sq) (smpDeliveryWorkers c) (runSmpQueueMsgDelivery c cData sq)
  where
    mkLock w = do
      retryLock <- newEmptyTMVar
      pure (w, retryLock)

submitPendingMsg :: AgentMonad' m => AgentClient -> ConnData -> SndQueue -> m ()
submitPendingMsg c cData sq = do
  atomically $ modifyTVar' (msgDeliveryOp c) $ \s -> s {opsInProgress = opsInProgress s + 1}
  void $ getDeliveryWorker True c cData sq

runSmpQueueMsgDelivery :: forall m. AgentMonad m => AgentClient -> ConnData -> SndQueue -> (Worker, TMVar ()) -> m ()
runSmpQueueMsgDelivery c@AgentClient {subQ} ConnData {connId} sq (Worker {doWork}, qLock) = do
  AgentConfig {messageRetryInterval = ri, messageTimeout, helloTimeout, quotaExceededTimeout} <- asks config
  forever $ do
    atomically $ endAgentOperation c AOSndNetwork
    waitForWork doWork
    atomically $ throwWhenInactive c
    atomically $ throwWhenNoDelivery c sq
    atomically $ beginAgentOperation c AOSndNetwork
    withWork c doWork (\db -> getPendingQueueMsg db connId sq) $
      \(rq_, PendingMsgData {msgId, msgType, msgBody, pqEncryption, msgFlags, msgRetryState, internalTs}) -> do
        atomically $ endAgentOperation c AOMsgDelivery -- this operation begins in submitPendingMsg
        let mId = unId msgId
            ri' = maybe id updateRetryInterval2 msgRetryState ri
        withRetryLock2 ri' qLock $ \riState loop -> do
          resp <- tryError $ case msgType of
            AM_CONN_INFO -> sendConfirmation c sq msgBody
            AM_CONN_INFO_REPLY -> sendConfirmation c sq msgBody
            _ -> sendAgentMessage c sq msgFlags msgBody
          case resp of
            Left e -> do
              let err = if msgType == AM_A_MSG_ then MERR mId e else ERR e
              case e of
                SMP SMP.QUOTA -> case msgType of
                  AM_CONN_INFO -> connError msgId NOT_AVAILABLE
                  AM_CONN_INFO_REPLY -> connError msgId NOT_AVAILABLE
                  _ -> do
                    expireTs <- addUTCTime (-quotaExceededTimeout) <$> liftIO getCurrentTime
                    if internalTs < expireTs then notifyDelMsgs msgId e expireTs else retrySndMsg RISlow
                SMP SMP.AUTH -> case msgType of
                  AM_CONN_INFO -> connError msgId NOT_AVAILABLE
                  AM_CONN_INFO_REPLY -> connError msgId NOT_AVAILABLE
                  AM_RATCHET_INFO -> connError msgId NOT_AVAILABLE
                  -- in duplexHandshake mode (v2) HELLO is only sent once, without retrying,
                  -- because the queue must be secured by the time the confirmation or the first HELLO is received
                  AM_HELLO_ -> case rq_ of
                    -- party initiating connection
                    Just _ -> connError msgId NOT_AVAILABLE
                    -- party joining connection
                    _ -> connError msgId NOT_ACCEPTED
                  AM_REPLY_ -> notifyDel msgId err
                  AM_A_MSG_ -> notifyDel msgId err
                  AM_A_RCVD_ -> notifyDel msgId err
                  AM_QCONT_ -> notifyDel msgId err
                  AM_QADD_ -> qError msgId "QADD: AUTH"
                  AM_QKEY_ -> qError msgId "QKEY: AUTH"
                  AM_QUSE_ -> qError msgId "QUSE: AUTH"
                  AM_QTEST_ -> qError msgId "QTEST: AUTH"
                  AM_EREADY_ -> notifyDel msgId err
                _
                  -- for other operations BROKER HOST is treated as a permanent error (e.g., when connecting to the server),
                  -- the message sending would be retried
                  | temporaryOrHostError e -> do
                      let msgTimeout = if msgType == AM_HELLO_ then helloTimeout else messageTimeout
                      expireTs <- addUTCTime (-msgTimeout) <$> liftIO getCurrentTime
                      if internalTs < expireTs then notifyDelMsgs msgId e expireTs else retrySndMsg RIFast
                  | otherwise -> notifyDel msgId err
              where
                retrySndMsg riMode = do
                  withStore' c $ \db -> updatePendingMsgRIState db connId msgId riState
                  retrySndOp c $ loop riMode
            Right () -> do
              case msgType of
                AM_CONN_INFO -> setConfirmed
                AM_CONN_INFO_REPLY -> setConfirmed
                AM_RATCHET_INFO -> pure ()
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
                      when (status == Active) $ notify $ CON pqEncryption
                    -- this branch should never be reached as receive queue is created before the confirmation,
                    _ -> logError "HELLO sent without receive queue"
                AM_A_MSG_ -> notify $ SENT mId
                AM_A_RCVD_ -> pure ()
                AM_QCONT_ -> pure ()
                AM_QADD_ -> pure ()
                AM_QKEY_ -> do
                  SomeConn _ conn <- withStore c (`getConn` connId)
                  notify . SWITCH QDSnd SPConfirmed $ connectionStats conn
                AM_QUSE_ -> pure ()
                AM_QTEST_ -> withConnLock c connId "runSmpQueueMsgDelivery AM_QTEST_" $ do
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
                          case removeQP (\sq' -> dbQId sq' == replacedId && not (sameQueue addr sq')) sqs of
                            Nothing -> internalErr msgId "sent QTEST: queue not found in connection"
                            Just (sq', sq'' : sqs') -> do
                              checkSQSwchStatus sq' SSSendingQTEST
                              -- remove the delivery from the map to stop the thread when the delivery loop is complete
                              atomically $ TM.delete (qAddress sq') $ smpDeliveryWorkers c
                              withStore' c $ \db -> do
                                when primary $ setSndQueuePrimary db connId sq
                                deletePendingMsgs db connId sq'
                                deleteConnSndQueue db connId sq'
                              let sqs'' = sq'' :| sqs'
                                  conn' = DuplexConnection cData' rqs sqs''
                              notify . SWITCH QDSnd SPCompleted $ connectionStats conn'
                            _ -> internalErr msgId "sent QTEST: there is only one queue in connection"
                        _ -> internalErr msgId "sent QTEST: queue not in connection or not replacing another queue"
                    _ -> internalErr msgId "QTEST sent not in duplex connection"
                AM_EREADY_ -> pure ()
              delMsgKeep (msgType == AM_A_MSG_) msgId
              where
                setConfirmed = do
                  withStore' c $ \db -> do
                    setSndQueueStatus db sq Confirmed
                    when (isJust rq_) $ removeConfirmations db connId
  where
    notifyDelMsgs :: InternalId -> AgentErrorType -> UTCTime -> m ()
    notifyDelMsgs msgId err expireTs = do
      notifyDel msgId $ MERR (unId msgId) err
      msgIds_ <- withStore' c $ \db -> getExpiredSndMessages db connId sq expireTs
      forM_ (L.nonEmpty msgIds_) $ \msgIds -> do
        notify $ MERRS (L.map unId msgIds) err
        withStore' c $ \db -> forM_ msgIds $ \msgId' -> deleteSndMsgDelivery db connId sq msgId' False `catchAll_` pure ()
    delMsg :: InternalId -> m ()
    delMsg = delMsgKeep False
    delMsgKeep :: Bool -> InternalId -> m ()
    delMsgKeep keepForReceipt msgId = withStore' c $ \db -> deleteSndMsgDelivery db connId sq msgId keepForReceipt
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

ackMessage' :: forall m. AgentMonad m => AgentClient -> ConnId -> AgentMsgId -> Maybe MsgReceiptInfo -> m ()
ackMessage' c connId msgId rcptInfo_ = withConnLock c connId "ackMessage" $ do
  SomeConn _ conn <- withStore c (`getConn` connId)
  case conn of
    DuplexConnection {} -> ack >> sendRcpt conn >> del
    RcvConnection {} -> ack >> del
    SndConnection {} -> throwError $ CONN SIMPLEX
    ContactConnection {} -> throwError $ CMD PROHIBITED
    NewConnection _ -> throwError $ CMD PROHIBITED
  where
    ack :: m ()
    ack = do
      -- the stored message was delivered via a specific queue, the rest failed to decrypt and were already acknowledged
      (rq, srvMsgId) <- withStoreCtx "ackMessage': setMsgUserAck" c $ \db -> setMsgUserAck db connId $ InternalId msgId
      ackQueueMessage c rq srvMsgId
    del :: m ()
    del = withStoreCtx' "ackMessage': deleteMsg" c $ \db -> deleteMsg db connId $ InternalId msgId
    sendRcpt :: Connection 'CDuplex -> m ()
    sendRcpt (DuplexConnection cData@ConnData {connAgentVersion} _ sqs) = do
      msg@RcvMsg {msgType, msgReceipt} <- withStoreCtx "ackMessage': getRcvMsg" c $ \db -> getRcvMsg db connId $ InternalId msgId
      case rcptInfo_ of
        Just rcptInfo -> do
          unless (msgType == AM_A_MSG_) $ throwError (CMD PROHIBITED)
          when (connAgentVersion >= deliveryRcptsSMPAgentVersion) $ do
            let RcvMsg {msgMeta = MsgMeta {sndMsgId}, internalHash} = msg
                rcpt = A_RCVD [AMessageReceipt {agentMsgId = sndMsgId, msgHash = internalHash, rcptInfo}]
            void $ enqueueMessages c cData sqs Nothing SMP.MsgFlags {notification = False} rcpt
        Nothing -> case (msgType, msgReceipt) of
          -- only remove sent message if receipt hash was Ok, both to debug and for future redundancy
          (AM_A_RCVD_, Just MsgReceipt {agentMsgId = sndMsgId, msgRcptStatus = MROk}) ->
            withStoreCtx' "ackMessage': deleteDeliveredSndMsg" c $ \db -> deleteDeliveredSndMsg db connId $ InternalId sndMsgId
          _ -> pure ()

switchConnection' :: AgentMonad m => AgentClient -> ConnId -> m ConnectionStats
switchConnection' c connId =
  withConnLock c connId "switchConnection" $
    withStore c (`getConn` connId) >>= \case
      SomeConn _ conn@(DuplexConnection cData rqs@(rq :| _rqs) _)
        | isJust (switchingRQ rqs) -> throwError $ CMD PROHIBITED
        | otherwise -> do
            when (ratchetSyncSendProhibited cData) $ throwError $ CMD PROHIBITED
            rq' <- withStore' c $ \db -> setRcvSwitchStatus db rq $ Just RSSwitchStarted
            switchDuplexConnection c conn rq'
      _ -> throwError $ CMD PROHIBITED

switchDuplexConnection :: AgentMonad m => AgentClient -> Connection 'CDuplex -> RcvQueue -> m ConnectionStats
switchDuplexConnection c (DuplexConnection cData@ConnData {connId, userId} rqs sqs) rq@RcvQueue {server, dbQueueId = DBQueueId dbQueueId, sndId} = do
  checkRQSwchStatus rq RSSwitchStarted
  clientVRange <- asks $ smpClientVRange . config
  -- try to get the server that is different from all queues, or at least from the primary rcv queue
  srvAuth@(ProtoServerWithAuth srv _) <- getNextServer c userId $ map qServer (L.toList rqs) <> map qServer (L.toList sqs)
  srv' <- if srv == server then getNextServer c userId [server] else pure srvAuth
  (q, qUri) <- newRcvQueue c userId connId srv' clientVRange SMSubscribe
  let rq' = (q :: NewRcvQueue) {primary = True, dbReplaceQueueId = Just dbQueueId}
  rq'' <- withStore c $ \db -> addConnRcvQueue db connId rq'
  addSubscription c rq''
  void . enqueueMessages c cData sqs Nothing SMP.noMsgFlags $ QADD [(qUri, Just (server, sndId))]
  rq1 <- withStore' c $ \db -> setRcvSwitchStatus db rq $ Just RSSendingQADD
  let rqs' = updatedQs rq1 rqs <> [rq'']
  pure . connectionStats $ DuplexConnection cData rqs' sqs

abortConnectionSwitch' :: AgentMonad m => AgentClient -> ConnId -> m ConnectionStats
abortConnectionSwitch' c connId =
  withConnLock c connId "abortConnectionSwitch" $
    withStore c (`getConn` connId) >>= \case
      SomeConn _ (DuplexConnection cData rqs sqs) -> case switchingRQ rqs of
        Just rq
          | canAbortRcvSwitch rq -> do
              when (ratchetSyncSendProhibited cData) $ throwError $ CMD PROHIBITED
              -- multiple queues to which the connections switches were possible when repeating switch was allowed
              let (delRqs, keepRqs) = L.partition ((Just (dbQId rq) ==) . dbReplaceQId) rqs
              case L.nonEmpty keepRqs of
                Just rqs' -> do
                  rq' <- withStore' c $ \db -> do
                    mapM_ (setRcvQueueDeleted db) delRqs
                    setRcvSwitchStatus db rq Nothing
                  forM_ delRqs $ \RcvQueue {server, rcvId} -> enqueueCommand c "" connId (Just server) $ AInternalCommand $ ICDeleteRcvQueue rcvId
                  let rqs'' = updatedQs rq' rqs'
                      conn' = DuplexConnection cData rqs'' sqs
                  pure $ connectionStats conn'
                _ -> throwError $ INTERNAL "won't delete all rcv queues in connection"
          | otherwise -> throwError $ CMD PROHIBITED
        _ -> throwError $ CMD PROHIBITED
      _ -> throwError $ CMD PROHIBITED

synchronizeRatchet' :: AgentMonad m => AgentClient -> ConnId -> CR.PQEncryption -> Bool -> m ConnectionStats
synchronizeRatchet' c connId pqEnc force = withConnLock c connId "synchronizeRatchet" $ do
  withStore c (`getConn` connId) >>= \case
    SomeConn _ (DuplexConnection cData rqs sqs)
      | ratchetSyncAllowed cData || force -> do
          -- check queues are not switching?
          AgentConfig {e2eEncryptVRange} <- asks config
          g <- asks random
          (pk1, pk2, pKem, e2eParams) <- liftIO $ CR.generateRcvE2EParams g (maxVersion e2eEncryptVRange) pqEnc
          enqueueRatchetKeyMsgs c cData sqs e2eParams
          withStore' c $ \db -> do
            setConnRatchetSync db connId RSStarted
            setRatchetX3dhKeys db connId pk1 pk2 pKem
          let cData' = cData {ratchetSyncState = RSStarted} :: ConnData
              conn' = DuplexConnection cData' rqs sqs
          pure $ connectionStats conn'
      | otherwise -> throwError $ CMD PROHIBITED
    _ -> throwError $ CMD PROHIBITED

ackQueueMessage :: AgentMonad m => AgentClient -> RcvQueue -> SMP.MsgId -> m ()
ackQueueMessage c rq srvMsgId =
  sendAck c rq srvMsgId `catchAgentError` \case
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
deleteConnections' = deleteConnections_ getConns False False

deleteDeletedConns :: forall m. AgentMonad m => AgentClient -> [ConnId] -> m (Map ConnId (Either AgentErrorType ()))
deleteDeletedConns = deleteConnections_ getDeletedConns True False

deleteDeletedWaitingDeliveryConns :: forall m. AgentMonad m => AgentClient -> [ConnId] -> m (Map ConnId (Either AgentErrorType ()))
deleteDeletedWaitingDeliveryConns = deleteConnections_ getConns True True

prepareDeleteConnections_ ::
  forall m.
  AgentMonad m =>
  (DB.Connection -> [ConnId] -> IO [Either StoreError SomeConn]) ->
  AgentClient ->
  Bool ->
  [ConnId] ->
  m (Map ConnId (Either AgentErrorType ()), [RcvQueue], [ConnId])
prepareDeleteConnections_ getConnections c waitDelivery connIds = do
  conns :: Map ConnId (Either StoreError SomeConn) <- M.fromList . zip connIds <$> withStore' c (`getConnections` connIds)
  let (errs, cs) = M.mapEither id conns
      errs' = M.map (Left . storeError) errs
      (delRs, rcvQs) = M.mapEither rcvQueues cs
      rqs = concat $ M.elems rcvQs
      connIds' = M.keys rcvQs
  forM_ connIds' $ disableConn c
  -- ! delRs is not used to notify about the result in any of the calling functions,
  -- ! it is only used to check results count in deleteConnections_;
  -- ! if it was used to notify about the result, it might be necessary to differentiate
  -- ! between completed deletions of connections, and deletions delayed due to wait for delivery (see deleteConn)
  deliveryTimeout <- if waitDelivery then asks (Just . connDeleteDeliveryTimeout . config) else pure Nothing
  rs' <- catMaybes . rights <$> withStoreBatch' c (\db -> map (deleteConn db deliveryTimeout) (M.keys delRs))
  forM_ rs' $ \cId -> notify ("", cId, APC SAEConn DEL_CONN)
  pure (errs' <> delRs, rqs, connIds')
  where
    rcvQueues :: SomeConn -> Either (Either AgentErrorType ()) [RcvQueue]
    rcvQueues (SomeConn _ conn) = case connRcvQueues conn of
      [] -> Left $ Right ()
      rqs -> Right rqs
    notify = atomically . writeTBQueue (subQ c)

deleteConnQueues :: forall m. AgentMonad m => AgentClient -> Bool -> Bool -> [RcvQueue] -> m (Map ConnId (Either AgentErrorType ()))
deleteConnQueues c waitDelivery ntf rqs = do
  rs <- connResults <$> (deleteQueueRecs =<< deleteQueues c rqs)
  let connIds = M.keys $ M.filter isRight rs
  deliveryTimeout <- if waitDelivery then asks (Just . connDeleteDeliveryTimeout . config) else pure Nothing
  rs' <- catMaybes . rights <$> withStoreBatch' c (\db -> map (deleteConn db deliveryTimeout) connIds)
  forM_ rs' $ \cId -> notify ("", cId, APC SAEConn DEL_CONN)
  pure rs
  where
    deleteQueueRecs :: [(RcvQueue, Either AgentErrorType ())] -> m [(RcvQueue, Either AgentErrorType ())]
    deleteQueueRecs rs = do
      maxErrs <- asks $ deleteErrorCount . config
      (rs', notifyActions) <- unzip . rights <$> withStoreBatch' c (\db -> map (deleteQueueRec db maxErrs) rs)
      mapM_ sequence_ notifyActions
      pure rs'
      where
        deleteQueueRec ::
          DB.Connection ->
          Int ->
          (RcvQueue, Either AgentErrorType ()) ->
          IO ((RcvQueue, Either AgentErrorType ()), Maybe (m ()))
        deleteQueueRec db maxErrs (rq, r) = case r of
          Right _ -> deleteConnRcvQueue db rq $> ((rq, r), Just (notifyRQ rq Nothing))
          Left e
            | temporaryOrHostError e && deleteErrors rq + 1 < maxErrs -> incRcvDeleteErrors db rq $> ((rq, r), Nothing)
            | otherwise -> deleteConnRcvQueue db rq $> ((rq, Right ()), Just (notifyRQ rq (Just e)))
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
  Bool ->
  AgentClient ->
  [ConnId] ->
  m (Map ConnId (Either AgentErrorType ()))
deleteConnections_ _ _ _ _ [] = pure M.empty
deleteConnections_ getConnections ntf waitDelivery c connIds = do
  (rs, rqs, _) <- prepareDeleteConnections_ getConnections c waitDelivery connIds
  rcvRs <- deleteConnQueues c waitDelivery ntf rqs
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
  RcvConnection cData rq ->
    (stats cData) {rcvQueuesInfo = [rcvQueueInfo rq]}
  SndConnection cData sq ->
    (stats cData) {sndQueuesInfo = [sndQueueInfo sq]}
  DuplexConnection cData rqs sqs ->
    (stats cData) {rcvQueuesInfo = map rcvQueueInfo $ L.toList rqs, sndQueuesInfo = map sndQueueInfo $ L.toList sqs}
  ContactConnection cData rq ->
    (stats cData) {rcvQueuesInfo = [rcvQueueInfo rq]}
  NewConnection cData ->
    stats cData
  where
    stats ConnData {connAgentVersion, ratchetSyncState} =
      ConnectionStats
        { connAgentVersion,
          rcvQueuesInfo = [],
          sndQueuesInfo = [],
          ratchetSyncState,
          ratchetSyncSupported = connAgentVersion >= ratchetSyncSMPAgentVersion
        }

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
          tryReplace ns `catchAgentError` \e ->
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
          asks (rcvAuthAlg . config) >>= \case
            C.AuthAlg a -> do
              g <- asks random
              tknKeys <- atomically $ C.generateAuthKeyPair a g
              dhKeys <- atomically $ C.generateKeyPair g
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

getNtfToken' :: AgentMonad m => AgentClient -> m (DeviceToken, NtfTknStatus, NotificationsMode, NtfServer)
getNtfToken' c =
  withStore' c getSavedNtfToken >>= \case
    Just NtfToken {deviceToken, ntfTknStatus, ntfMode, ntfServer} -> pure (deviceToken, ntfTknStatus, ntfMode, ntfServer)
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
    agentNtfDeleteToken c tknId tkn `catchAgentError` \case
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
getAgentMigrations' c = map upMigration <$> withStore' c (Migrations.getCurrent . DB.conn)

debugAgentLocks' :: AgentMonad' m => AgentClient -> m AgentLocks
debugAgentLocks' AgentClient {connLocks = cs, invLocks = is, deleteLock = d} = do
  connLocks <- getLocks cs
  invLocks <- getLocks is
  delLock <- atomically $ tryReadTMVar d
  pure AgentLocks {connLocks, invLocks, delLock}
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
  ttl <- asks $ storedMsgDataTTL . config
  forever $ do
    run ERR deleteConns
    run ERR $ withStore' c (`deleteRcvMsgHashesExpired` ttl)
    run ERR $ withStore' c (`deleteSndMsgsExpired` ttl)
    run ERR $ withStore' c (`deleteRatchetKeyHashesExpired` ttl)
    run RFERR deleteRcvFilesExpired
    run RFERR deleteRcvFilesDeleted
    run RFERR deleteRcvFilesTmpPaths
    run SFERR deleteSndFilesExpired
    run SFERR deleteSndFilesDeleted
    run SFERR deleteSndFilesPrefixPaths
    run SFERR deleteExpiredReplicasForDeletion
    liftIO $ threadDelay' int
  where
    run :: forall e. AEntityI e => (AgentErrorType -> ACommand 'Agent e) -> ExceptT AgentErrorType m () -> m ()
    run err a = do
      void . runExceptT $ a `catchAgentError` (notify "" . err)
      step <- asks $ cleanupStepInterval . config
      liftIO $ threadDelay step
    deleteConns =
      withLock (deleteLock c) "cleanupManager" $ do
        void $ withStore' c getDeletedConnIds >>= deleteDeletedConns c
        void $ withStore' c getDeletedWaitingDeliveryConnIds >>= deleteDeletedWaitingDeliveryConns c
        withStore' c deleteUsersWithoutConns >>= mapM_ (notify "" . DEL_USER)
    deleteRcvFilesExpired = do
      rcvFilesTTL <- asks $ rcvFilesTTL . config
      rcvExpired <- withStore' c (`getRcvFilesExpired` rcvFilesTTL)
      forM_ rcvExpired $ \(dbId, entId, p) -> flip catchAgentError (notify entId . RFERR) $ do
        removePath =<< toFSFilePath p
        withStore' c (`deleteRcvFile'` dbId)
    deleteRcvFilesDeleted = do
      rcvDeleted <- withStore' c getCleanupRcvFilesDeleted
      forM_ rcvDeleted $ \(dbId, entId, p) -> flip catchAgentError (notify entId . RFERR) $ do
        removePath =<< toFSFilePath p
        withStore' c (`deleteRcvFile'` dbId)
    deleteRcvFilesTmpPaths = do
      rcvTmpPaths <- withStore' c getCleanupRcvFilesTmpPaths
      forM_ rcvTmpPaths $ \(dbId, entId, p) -> flip catchAgentError (notify entId . RFERR) $ do
        removePath =<< toFSFilePath p
        withStore' c (`updateRcvFileNoTmpPath` dbId)
    deleteSndFilesExpired = do
      sndFilesTTL <- asks $ sndFilesTTL . config
      sndExpired <- withStore' c (`getSndFilesExpired` sndFilesTTL)
      forM_ sndExpired $ \(dbId, entId, p) -> flip catchAgentError (notify entId . SFERR) $ do
        forM_ p $ removePath <=< toFSFilePath
        withStore' c (`deleteSndFile'` dbId)
    deleteSndFilesDeleted = do
      sndDeleted <- withStore' c getCleanupSndFilesDeleted
      forM_ sndDeleted $ \(dbId, entId, p) -> flip catchAgentError (notify entId . SFERR) $ do
        forM_ p $ removePath <=< toFSFilePath
        withStore' c (`deleteSndFile'` dbId)
    deleteSndFilesPrefixPaths = do
      sndPrefixPaths <- withStore' c getCleanupSndFilesPrefixPaths
      forM_ sndPrefixPaths $ \(dbId, entId, p) -> flip catchAgentError (notify entId . SFERR) $ do
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
processSMPTransmission c@AgentClient {smpClients, subQ} (tSess@(_, srv, _), _v, sessId, rId, cmd) = do
  (rq, SomeConn _ conn) <- withStore c (\db -> getRcvConn db srv rId)
  processSMP rq conn $ toConnData conn
  where
    processSMP :: forall c. RcvQueue -> Connection c -> ConnData -> m ()
    processSMP
      rq@RcvQueue {e2ePrivKey, e2eDhSecret, status}
      conn
      cData@ConnData {userId, connId, connAgentVersion, ratchetSyncState = rss} =
        withConnLock c connId "processSMP" $ case cmd of
          SMP.MSG msg@SMP.RcvMessage {msgId = srvMsgId} ->
            handleNotifyAck $ do
              msg' <- decryptSMPMessage rq msg
              handleNotifyAck $ case msg' of
                SMP.ClientRcvMsgBody {msgTs = srvTs, msgFlags, msgBody} -> processClientMsg srvTs msgFlags msgBody
                SMP.ClientRcvMsgQuota {} -> queueDrained >> ack
              whenM (atomically $ hasGetLock c rq) $
                notify (MSGNTF $ SMP.rcvMessageMeta srvMsgId msg')
            where
              queueDrained = case conn of
                DuplexConnection _ _ sqs -> void $ enqueueMessages c cData sqs Nothing SMP.noMsgFlags $ QCONT (sndAddress rq)
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
                      (SMP.PHConfirmation senderKey, AgentConfirmation {e2eEncryption_, encConnInfo, agentVersion}) ->
                        smpConfirmation srvMsgId conn senderKey e2ePubKey e2eEncryption_ encConnInfo phVer agentVersion >> ack
                      (SMP.PHEmpty, AgentInvitation {connReq, connInfo}) ->
                        smpInvitation srvMsgId conn connReq connInfo >> ack
                      _ -> prohibited >> ack
                  (Just e2eDh, Nothing) -> do
                    decryptClientMessage e2eDh clientMsg >>= \case
                      (SMP.PHEmpty, AgentRatchetKey {agentVersion, e2eEncryption}) -> do
                        conn' <- updateConnVersion conn cData agentVersion
                        qDuplex conn' "AgentRatchetKey" $ newRatchetKey e2eEncryption
                        ack
                      (SMP.PHEmpty, AgentMsgEnvelope {agentVersion, encAgentMessage}) -> do
                        conn' <- updateConnVersion conn cData agentVersion
                        -- primary queue is set as Active in helloMsg, below is to set additional queues Active
                        let RcvQueue {primary, dbReplaceQueueId} = rq
                        unless (status == Active) . withStore' c $ \db -> setRcvQueueStatus db rq Active
                        case (conn', dbReplaceQueueId) of
                          (DuplexConnection _ rqs _, Just replacedId) -> do
                            when primary . withStore' c $ \db -> setRcvQueuePrimary db connId rq
                            case find ((replacedId ==) . dbQId) rqs of
                              Just rq'@RcvQueue {server, rcvId} -> do
                                checkRQSwchStatus rq' RSSendingQUSE
                                void $ withStore' c $ \db -> setRcvSwitchStatus db rq' $ Just RSReceivedMessage
                                enqueueCommand c "" connId (Just server) $ AInternalCommand $ ICQDelete rcvId
                              _ -> notify . ERR . AGENT $ A_QUEUE "replaced RcvQueue not found in connection"
                          _ -> pure ()
                        let encryptedMsgHash = C.sha256Hash encAgentMessage
                        g <- asks random
                        tryError (agentClientMsg g encryptedMsgHash) >>= \case
                          Right (Just (msgId, msgMeta, aMessage, rcPrev)) -> do
                            conn'' <- resetRatchetSync
                            case aMessage of
                              HELLO -> helloMsg srvMsgId msgMeta conn'' >> ackDel msgId
                              -- note that there is no ACK sent for A_MSG, it is sent with agent's user ACK command
                              A_MSG body -> do
                                logServer "<--" c srv rId $ "MSG <MSG>:" <> logSecret srvMsgId
                                notify $ MSG msgMeta msgFlags body
                              A_RCVD rcpts -> qDuplex conn'' "RCVD" $ messagesRcvd rcpts msgMeta
                              QCONT addr -> qDuplexAckDel conn'' "QCONT" $ continueSending srvMsgId addr
                              QADD qs -> qDuplexAckDel conn'' "QADD" $ qAddMsg srvMsgId qs
                              QKEY qs -> qDuplexAckDel conn'' "QKEY" $ qKeyMsg srvMsgId qs
                              QUSE qs -> qDuplexAckDel conn'' "QUSE" $ qUseMsg srvMsgId qs
                              -- no action needed for QTEST
                              -- any message in the new queue will mark it active and trigger deletion of the old queue
                              QTEST _ -> logServer "<--" c srv rId ("MSG <QTEST>:" <> logSecret srvMsgId) >> ackDel msgId
                              EREADY _ -> qDuplexAckDel conn'' "EREADY" $ ereadyMsg rcPrev
                            where
                              qDuplexAckDel :: Connection c -> String -> (Connection 'CDuplex -> m ()) -> m ()
                              qDuplexAckDel conn'' name a = qDuplex conn'' name a >> ackDel msgId
                              resetRatchetSync :: m (Connection c)
                              resetRatchetSync
                                | rss `notElem` ([RSOk, RSStarted] :: [RatchetSyncState]) = do
                                    let cData'' = (toConnData conn') {ratchetSyncState = RSOk} :: ConnData
                                        conn'' = updateConnection cData'' conn'
                                    notify . RSYNC RSOk Nothing $ connectionStats conn''
                                    withStore' c $ \db -> setConnRatchetSync db connId RSOk
                                    pure conn''
                                | otherwise = pure conn'
                          Right _ -> prohibited >> ack
                          Left e@(AGENT A_DUPLICATE) -> do
                            withStoreCtx' "processSMP: getLastMsg" c (\db -> getLastMsg db connId srvMsgId) >>= \case
                              Just RcvMsg {internalId, msgMeta, msgBody = agentMsgBody, userAck}
                                | userAck -> ackDel internalId
                                | otherwise -> do
                                    liftEither (parse smpP (AGENT A_MESSAGE) agentMsgBody) >>= \case
                                      AgentMessage _ (A_MSG body) -> do
                                        logServer "<--" c srv rId $ "MSG <MSG>:" <> logSecret srvMsgId
                                        notify $ MSG msgMeta msgFlags body
                                      _ -> pure ()
                              _ -> checkDuplicateHash e encryptedMsgHash >> ack
                          Left (AGENT (A_CRYPTO e)) -> do
                            exists <- withStore' c $ \db -> checkRcvMsgHashExists db connId encryptedMsgHash
                            unless exists notifySync
                            ack
                            where
                              notifySync :: m ()
                              notifySync = qDuplex conn' "AGENT A_CRYPTO error" $ \connDuplex -> do
                                let rss' = cryptoErrToSyncState e
                                when (rss `elem` ([RSOk, RSAllowed, RSRequired] :: [RatchetSyncState])) $ do
                                  let cData'' = (toConnData conn') {ratchetSyncState = rss'} :: ConnData
                                      conn'' = updateConnection cData'' connDuplex
                                  notify . RSYNC rss' (Just e) $ connectionStats conn''
                                  withStore' c $ \db -> setConnRatchetSync db connId rss'
                          Left e -> checkDuplicateHash e encryptedMsgHash >> ack
                        where
                          checkDuplicateHash :: AgentErrorType -> ByteString -> m ()
                          checkDuplicateHash e encryptedMsgHash =
                            unlessM (withStore' c $ \db -> checkRcvMsgHashExists db connId encryptedMsgHash) $
                              throwError e
                          agentClientMsg :: TVar ChaChaDRG -> ByteString -> m (Maybe (InternalId, MsgMeta, AMessage, CR.RatchetX448))
                          agentClientMsg g encryptedMsgHash = withStore c $ \db -> runExceptT $ do
                            rc <- ExceptT $ getRatchet db connId -- ratchet state pre-decryption - required for processing EREADY
                            (agentMsgBody, pqEncryption) <- agentRatchetDecrypt' g db connId rc encAgentMessage
                            liftEither (parse smpP (SEAgentError $ AGENT A_MESSAGE) agentMsgBody) >>= \case
                              agentMsg@(AgentMessage APrivHeader {sndMsgId, prevMsgHash} aMessage) -> do
                                let msgType = agentMessageType agentMsg
                                    internalHash = C.sha256Hash agentMsgBody
                                internalTs <- liftIO getCurrentTime
                                (internalId, internalRcvId, prevExtSndId, prevRcvMsgHash) <- liftIO $ updateRcvIds db connId
                                let integrity = checkMsgIntegrity prevExtSndId sndMsgId prevRcvMsgHash prevMsgHash
                                    recipient = (unId internalId, internalTs)
                                    broker = (srvMsgId, systemToUTCTime srvTs)
                                    msgMeta = MsgMeta {integrity, recipient, broker, sndMsgId, pqEncryption}
                                    rcvMsg = RcvMsgData {msgMeta, msgType, msgFlags, msgBody = agentMsgBody, internalRcvId, internalHash, externalPrevSndHash = prevMsgHash, encryptedMsgHash}
                                liftIO $ createRcvMsg db connId rq rcvMsg
                                pure $ Just (internalId, msgMeta, aMessage, rc)
                              _ -> pure Nothing
                      _ -> prohibited >> ack
                  _ -> prohibited >> ack
              updateConnVersion :: Connection c -> ConnData -> Version -> m (Connection c)
              updateConnVersion conn' cData' msgAgentVersion = do
                aVRange <- asks $ smpAgentVRange . config
                let msgAVRange = fromMaybe (versionToRange msgAgentVersion) $ safeVersionRange (minVersion aVRange) msgAgentVersion
                case msgAVRange `compatibleVersion` aVRange of
                  Just (Compatible av)
                    | av > connAgentVersion -> do
                        withStore' c $ \db -> setConnAgentVersion db connId av
                        let cData'' = cData' {connAgentVersion = av} :: ConnData
                        pure $ updateConnection cData'' conn'
                    | otherwise -> pure conn'
                  Nothing -> pure conn'
              ack :: m ()
              ack = enqueueCmd $ ICAck rId srvMsgId
              ackDel :: InternalId -> m ()
              ackDel = enqueueCmd . ICAckDel rId srvMsgId
              handleNotifyAck :: m () -> m ()
              handleNotifyAck m = m `catchAgentError` \e -> notify (ERR e) >> ack
          SMP.END ->
            atomically (TM.lookup tSess smpClients $>>= (tryReadTMVar . sessionVar) >>= processEND)
              >>= logServer "<--" c srv rId
            where
              processEND = \case
                Just (Right clnt)
                  | sessId == sessionId (thParams clnt) -> do
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

          smpConfirmation :: SMP.MsgId -> Connection c -> C.APublicAuthKey -> C.PublicKeyX25519 -> Maybe (CR.SndE2ERatchetParams 'C.X448) -> ByteString -> Version -> Version -> m ()
          smpConfirmation srvMsgId conn' senderKey e2ePubKey e2eEncryption encConnInfo smpClientVersion agentVersion = do
            logServer "<--" c srv rId $ "MSG <CONF>:" <> logSecret srvMsgId
            AgentConfig {smpClientVRange, smpAgentVRange, e2eEncryptVRange} <- asks config
            unless
              (agentVersion `isCompatible` smpAgentVRange && smpClientVersion `isCompatible` smpClientVRange)
              (throwError $ AGENT A_VERSION)
            case status of
              New -> case (conn', e2eEncryption) of
                -- party initiating connection
                (RcvConnection ConnData {pqEncryption} _, Just (CR.AE2ERatchetParams _ e2eSndParams@(CR.E2ERatchetParams e2eVersion _ _ _))) -> do
                  unless (e2eVersion `isCompatible` e2eEncryptVRange) (throwError $ AGENT A_VERSION)
                  (pk1, rcDHRs, pKem) <- withStore c (`getRatchetX3dhKeys` connId)
                  rcParams <- liftError cryptoError $ CR.pqX3dhRcv pk1 rcDHRs pKem e2eSndParams
                  let rc = CR.initRcvRatchet e2eEncryptVRange rcDHRs rcParams pqEncryption
                  g <- asks random
                  (agentMsgBody_, rc', skipped) <- liftError cryptoError $ CR.rcDecrypt g rc M.empty encConnInfo
                  case (agentMsgBody_, skipped) of
                    (Right agentMsgBody, CR.SMDNoChange) ->
                      parseMessage agentMsgBody >>= \case
                        AgentConnInfoReply smpQueues connInfo ->
                          processConf connInfo SMPConfirmation {senderKey, e2ePubKey, connInfo, smpReplyQueues = L.toList smpQueues, smpClientVersion}
                        _ -> prohibited -- including AgentConnInfo, that is prohibited here in v2
                      where
                        processConf connInfo senderConf = do
                          let newConfirmation = NewConfirmation {connId, senderConf, ratchetState = rc'}
                          confId <- withStore c $ \db -> do
                            setConnectionVersion db connId agentVersion
                            createConfirmation db g newConfirmation
                          let srvs = map qServer $ smpReplyQueues senderConf
                          notify $ CONF confId srvs connInfo
                    _ -> prohibited
                -- party accepting connection
                (DuplexConnection _ (RcvQueue {smpClientVersion = v'} :| _) _, Nothing) -> do
                  g <- asks random
                  withStore c (\db -> runExceptT $ agentRatchetDecrypt g db connId encConnInfo) >>= parseMessage . fst >>= \case
                    AgentConnInfo connInfo -> do
                      notify $ INFO connInfo
                      let dhSecret = C.dh' e2ePubKey e2ePrivKey
                      withStore' c $ \db -> setRcvQueueConfirmedE2E db rq dhSecret $ min v' smpClientVersion
                      enqueueCmd $ ICDuplexSecure rId senderKey
                    _ -> prohibited
                _ -> prohibited
              _ -> prohibited

          helloMsg :: SMP.MsgId -> MsgMeta -> Connection c -> m ()
          helloMsg srvMsgId MsgMeta {pqEncryption} conn' = do
            logServer "<--" c srv rId $ "MSG <HELLO>:" <> logSecret srvMsgId
            case status of
              Active -> prohibited
              _ ->
                case conn' of
                  DuplexConnection _ _ (sq@SndQueue {status = sndStatus} :| _)
                    -- `sndStatus == Active` when HELLO was previously sent, and this is the reply HELLO
                    -- this branch is executed by the accepting party in duplexHandshake mode (v2)
                    -- (was executed by initiating party in v1 that is no longer supported)
                    --
                    -- TODO PQ encryption mode
                    | sndStatus == Active -> notify $ CON pqEncryption
                    | otherwise -> enqueueDuplexHello sq
                  _ -> pure ()
            where
              enqueueDuplexHello :: SndQueue -> m ()
              enqueueDuplexHello sq = do
                let cData' = toConnData conn'
                void $ enqueueMessage c cData' sq Nothing SMP.MsgFlags {notification = True} HELLO

          continueSending :: SMP.MsgId -> (SMPServer, SMP.SenderId) -> Connection 'CDuplex -> m ()
          continueSending srvMsgId addr (DuplexConnection _ _ sqs) =
            case findQ addr sqs of
              Just sq -> do
                logServer "<--" c srv rId $ "MSG <QCONT>:" <> logSecret srvMsgId
                atomically $
                  TM.lookup (qAddress sq) (smpDeliveryWorkers c)
                    >>= mapM_ (\(_, retryLock) -> tryPutTMVar retryLock ())
              Nothing -> qError "QCONT: queue address not found"

          messagesRcvd :: NonEmpty AMessageReceipt -> MsgMeta -> Connection 'CDuplex -> m ()
          messagesRcvd rcpts msgMeta@MsgMeta {broker = (srvMsgId, _)} _ = do
            logServer "<--" c srv rId $ "MSG <RCPT>:" <> logSecret srvMsgId
            rs <- forM rcpts $ \rcpt -> clientReceipt rcpt `catchAgentError` \e -> notify (ERR e) $> Nothing
            case L.nonEmpty . catMaybes $ L.toList rs of
              Just rs' -> notify $ RCVD msgMeta rs' -- client must ACK once processed
              Nothing -> enqueueCmd $ ICAck rId srvMsgId
            where
              clientReceipt :: AMessageReceipt -> m (Maybe MsgReceipt)
              clientReceipt AMessageReceipt {agentMsgId, msgHash} = do
                let sndMsgId = InternalSndId agentMsgId
                SndMsg {internalId = InternalId msgId, msgType, internalHash, msgReceipt} <- withStoreCtx "messagesRcvd: getSndMsgViaRcpt" c $ \db -> getSndMsgViaRcpt db connId sndMsgId
                if msgType /= AM_A_MSG_
                  then notify (ERR $ AGENT A_PROHIBITED) $> Nothing -- unexpected message type for receipt
                  else case msgReceipt of
                    Just MsgReceipt {msgRcptStatus = MROk} -> pure Nothing -- already notified with MROk status
                    _ -> do
                      let msgRcptStatus = if msgHash == internalHash then MROk else MRBadMsgHash
                          rcpt = MsgReceipt {agentMsgId = msgId, msgRcptStatus}
                      withStore' c $ \db -> updateSndMsgRcpt db connId sndMsgId rcpt
                      pure $ Just rcpt

          -- processed by queue sender
          qAddMsg :: SMP.MsgId -> NonEmpty (SMPQueueUri, Maybe SndQAddr) -> Connection 'CDuplex -> m ()
          qAddMsg _ ((_, Nothing) :| _) _ = qError "adding queue without switching is not supported"
          qAddMsg srvMsgId ((qUri, Just addr) :| _) (DuplexConnection cData' rqs sqs) = do
            when (ratchetSyncSendProhibited cData') $ throwError $ AGENT (A_QUEUE "ratchet is not synchronized")
            clientVRange <- asks $ smpClientVRange . config
            case qUri `compatibleVersion` clientVRange of
              Just qInfo@(Compatible sqInfo@SMPQueueInfo {queueAddress}) ->
                case (findQ (qAddress sqInfo) sqs, findQ addr sqs) of
                  (Just _, _) -> qError "QADD: queue address is already used in connection"
                  (_, Just sq@SndQueue {dbQueueId = DBQueueId dbQueueId}) -> do
                    let (delSqs, keepSqs) = L.partition ((Just dbQueueId ==) . dbReplaceQId) sqs
                    case L.nonEmpty keepSqs of
                      Just sqs' -> do
                        -- move inside case?
                        withStore' c $ \db -> mapM_ (deleteConnSndQueue db connId) delSqs
                        sq_@SndQueue {sndPublicKey, e2ePubKey} <- newSndQueue userId connId qInfo
                        let sq'' = (sq_ :: NewSndQueue) {primary = True, dbReplaceQueueId = Just dbQueueId}
                        sq2 <- withStore c $ \db -> addConnSndQueue db connId sq''
                        case (sndPublicKey, e2ePubKey) of
                          (Just sndPubKey, Just dhPublicKey) -> do
                            logServer "<--" c srv rId $ "MSG <QADD>:" <> logSecret srvMsgId <> " " <> logSecret (senderId queueAddress)
                            let sqInfo' = (sqInfo :: SMPQueueInfo) {queueAddress = queueAddress {dhPublicKey}}
                            void . enqueueMessages c cData' sqs Nothing SMP.noMsgFlags $ QKEY [(sqInfo', sndPubKey)]
                            sq1 <- withStore' c $ \db -> setSndSwitchStatus db sq $ Just SSSendingQKEY
                            let sqs'' = updatedQs sq1 sqs' <> [sq2]
                                conn' = DuplexConnection cData' rqs sqs''
                            notify . SWITCH QDSnd SPStarted $ connectionStats conn'
                          _ -> qError "absent sender keys"
                      _ -> qError "QADD: won't delete all snd queues in connection"
                  _ -> qError "QADD: replaced queue address is not found in connection"
              _ -> throwError $ AGENT A_VERSION

          -- processed by queue recipient
          qKeyMsg :: SMP.MsgId -> NonEmpty (SMPQueueInfo, SndPublicAuthKey) -> Connection 'CDuplex -> m ()
          qKeyMsg srvMsgId ((qInfo, senderKey) :| _) conn'@(DuplexConnection cData' rqs _) = do
            when (ratchetSyncSendProhibited cData') $ throwError $ AGENT (A_QUEUE "ratchet is not synchronized")
            clientVRange <- asks $ smpClientVRange . config
            unless (qInfo `isCompatible` clientVRange) . throwError $ AGENT A_VERSION
            case findRQ (smpServer, senderId) rqs of
              Just rq'@RcvQueue {rcvId, e2ePrivKey = dhPrivKey, smpClientVersion = cVer, status = status'}
                | status' == New || status' == Confirmed -> do
                    checkRQSwchStatus rq RSSendingQADD
                    logServer "<--" c srv rId $ "MSG <QKEY>:" <> logSecret srvMsgId <> " " <> logSecret senderId
                    let dhSecret = C.dh' dhPublicKey dhPrivKey
                    withStore' c $ \db -> setRcvQueueConfirmedE2E db rq' dhSecret $ min cVer cVer'
                    enqueueCommand c "" connId (Just smpServer) $ AInternalCommand $ ICQSecure rcvId senderKey
                    notify . SWITCH QDRcv SPConfirmed $ connectionStats conn'
                | otherwise -> qError "QKEY: queue already secured"
              _ -> qError "QKEY: queue address not found in connection"
            where
              SMPQueueInfo cVer' SMPQueueAddress {smpServer, senderId, dhPublicKey} = qInfo

          -- processed by queue sender
          -- mark queue as Secured and to start sending messages to it
          qUseMsg :: SMP.MsgId -> NonEmpty ((SMPServer, SMP.SenderId), Bool) -> Connection 'CDuplex -> m ()
          -- NOTE: does not yet support the change of the primary status during the rotation
          qUseMsg srvMsgId ((addr, _primary) :| _) (DuplexConnection cData' rqs sqs) = do
            when (ratchetSyncSendProhibited cData') $ throwError $ AGENT (A_QUEUE "ratchet is not synchronized")
            case findQ addr sqs of
              Just sq'@SndQueue {dbReplaceQueueId = Just replaceQId} -> do
                case find ((replaceQId ==) . dbQId) sqs of
                  Just sq1 -> do
                    checkSQSwchStatus sq1 SSSendingQKEY
                    logServer "<--" c srv rId $ "MSG <QUSE>:" <> logSecret srvMsgId <> " " <> logSecret (snd addr)
                    withStore' c $ \db -> setSndQueueStatus db sq' Secured
                    let sq'' = (sq' :: SndQueue) {status = Secured}
                    -- sending QTEST to the new queue only, the old one will be removed if sent successfully
                    void $ enqueueMessages c cData' [sq''] Nothing SMP.noMsgFlags $ QTEST [addr]
                    sq1' <- withStore' c $ \db -> setSndSwitchStatus db sq1 $ Just SSSendingQTEST
                    let sqs' = updatedQs sq1' sqs
                        conn' = DuplexConnection cData' rqs sqs'
                    notify . SWITCH QDSnd SPSecured $ connectionStats conn'
                  _ -> qError "QUSE: switching SndQueue not found in connection"
              _ -> qError "QUSE: switched queue address not found in connection"

          qError :: String -> m ()
          qError = throwError . AGENT . A_QUEUE

          ereadyMsg :: CR.RatchetX448 -> Connection 'CDuplex -> m ()
          ereadyMsg rcPrev (DuplexConnection cData'@ConnData {lastExternalSndId} _ sqs) = do
            let CR.Ratchet {rcSnd} = rcPrev
            -- if ratchet was initialized as receiving, it means EREADY wasn't sent on key negotiation
            when (isNothing rcSnd) . void $
              enqueueMessages' c cData' sqs Nothing SMP.MsgFlags {notification = True} (EREADY lastExternalSndId)

          smpInvitation :: SMP.MsgId -> Connection c -> ConnectionRequestUri 'CMInvitation -> ConnInfo -> m ()
          smpInvitation srvMsgId conn' connReq@(CRInvitationUri crData _) cInfo = do
            logServer "<--" c srv rId $ "MSG <KEY>:" <> logSecret srvMsgId
            case conn' of
              ContactConnection {} -> do
                g <- asks random
                let newInv = NewInvitation {contactConnId = connId, connReq, recipientConnInfo = cInfo}
                invId <- withStore c $ \db -> createInvitation db g newInv
                let srvs = L.map qServer $ crSmpQueues crData
                notify $ REQ invId srvs cInfo
              _ -> prohibited

          qDuplex :: Connection c -> String -> (Connection 'CDuplex -> m ()) -> m ()
          qDuplex conn' name action = case conn' of
            DuplexConnection {} -> action conn'
            _ -> qError $ name <> ": message must be sent to duplex connection"

          newRatchetKey :: CR.RcvE2ERatchetParams 'C.X448 -> Connection 'CDuplex -> m ()
          newRatchetKey e2eOtherPartyParams@(CR.E2ERatchetParams e2eVersion k1Rcv k2Rcv kem_) conn'@(DuplexConnection cData'@ConnData {lastExternalSndId} _ sqs) =
            unlessM ratchetExists $ do
              AgentConfig {e2eEncryptVRange} <- asks config
              unless (e2eVersion `isCompatible` e2eEncryptVRange) (throwError $ AGENT A_VERSION)
              keys <- getSendRatchetKeys
              initRatchet e2eEncryptVRange keys
              notifyAgreed
            where
              rkHashRcv = rkHash k1Rcv k2Rcv
              rkHash k1 k2 = C.sha256Hash $ C.pubKeyBytes k1 <> C.pubKeyBytes k2
              ratchetExists :: m Bool
              ratchetExists = withStore' c $ \db -> do
                exists <- checkRatchetKeyHashExists db connId rkHashRcv
                unless exists $ addProcessedRatchetKeyHash db connId rkHashRcv
                pure exists
              getSendRatchetKeys :: m (C.PrivateKeyX448, C.PrivateKeyX448, Maybe CR.RcvPrivRKEMParams)
              getSendRatchetKeys = case rss of
                RSOk -> sendReplyKey -- receiving client
                RSAllowed -> sendReplyKey
                RSRequired -> sendReplyKey
                RSStarted -> withStore c (`getRatchetX3dhKeys` connId) -- initiating client
                RSAgreed -> do
                  withStore' c $ \db -> setConnRatchetSync db connId RSRequired
                  notifyRatchetSyncError
                  -- can communicate for other client to reset to RSRequired
                  -- - need to add new AgentMsgEnvelope, AgentMessage, AgentMessageType
                  -- - need to deduplicate on receiving side
                  throwError $ AGENT (A_CRYPTO RATCHET_SYNC)
                where
                  sendReplyKey = do
                    g <- asks random
                    -- TODO PQ the decision to use KEM should depend on connection
                    (pk1, pk2, pKem, e2eParams) <- liftIO $ CR.generateRcvE2EParams g e2eVersion CR.PQEncOn
                    enqueueRatchetKeyMsgs c cData' sqs e2eParams
                    pure (pk1, pk2, pKem)
                  notifyRatchetSyncError = do
                    let cData'' = cData' {ratchetSyncState = RSRequired} :: ConnData
                        conn'' = updateConnection cData'' conn'
                    notify $ RSYNC RSRequired (Just RATCHET_SYNC) (connectionStats conn'')
              notifyAgreed :: m ()
              notifyAgreed = do
                let cData'' = cData' {ratchetSyncState = RSAgreed} :: ConnData
                    conn'' = updateConnection cData'' conn'
                notify . RSYNC RSAgreed Nothing $ connectionStats conn''
              recreateRatchet :: CR.Ratchet 'C.X448 -> m ()
              recreateRatchet rc = withStore' c $ \db -> do
                setConnRatchetSync db connId RSAgreed
                deleteRatchet db connId
                createRatchet db connId rc
              -- compare public keys `k1` in AgentRatchetKey messages sent by self and other party
              -- to determine ratchet initilization ordering
              initRatchet :: VersionRange -> (C.PrivateKeyX448, C.PrivateKeyX448, Maybe CR.RcvPrivRKEMParams) -> m ()
              initRatchet e2eEncryptVRange (pk1, pk2, pKem)
                | rkHash (C.publicKey pk1) (C.publicKey pk2) <= rkHashRcv = do
                    rcParams <- liftError cryptoError $ CR.pqX3dhRcv pk1 pk2 pKem e2eOtherPartyParams
                    -- TODO PQ the decision to use KEM should either depend on the global setting or on whether it was enabled in connection before
                    recreateRatchet $ CR.initRcvRatchet e2eEncryptVRange pk2 rcParams $ CR.PQEncryption (isJust kem_)
                | otherwise = do
                    (_, rcDHRs) <- atomically . C.generateKeyPair =<< asks random
                    rcParams <- liftEitherWith cryptoError $ CR.pqX3dhSnd pk1 pk2 (CR.APRKP CR.SRKSProposed <$> pKem) e2eOtherPartyParams
                    recreateRatchet $ CR.initSndRatchet e2eEncryptVRange k2Rcv rcDHRs rcParams
                    void . enqueueMessages' c cData' sqs Nothing SMP.MsgFlags {notification = True} $ EREADY lastExternalSndId

          checkMsgIntegrity :: PrevExternalSndId -> ExternalSndId -> PrevRcvMsgHash -> ByteString -> MsgIntegrity
          checkMsgIntegrity prevExtSndId extSndId internalPrevMsgHash receivedPrevMsgHash
            | extSndId == prevExtSndId + 1 && internalPrevMsgHash == receivedPrevMsgHash = MsgOk
            | extSndId < prevExtSndId = MsgError $ MsgBadId extSndId
            | extSndId == prevExtSndId = MsgError MsgDuplicate -- ? deduplicate
            | extSndId > prevExtSndId + 1 = MsgError $ MsgSkipped (prevExtSndId + 1) (extSndId - 1)
            | internalPrevMsgHash /= receivedPrevMsgHash = MsgError MsgBadHash
            | otherwise = MsgError MsgDuplicate -- this case is not possible

checkRQSwchStatus :: AgentMonad m => RcvQueue -> RcvSwitchStatus -> m ()
checkRQSwchStatus rq@RcvQueue {rcvSwchStatus} expected =
  unless (rcvSwchStatus == Just expected) $ switchStatusError rq expected rcvSwchStatus

checkSQSwchStatus :: AgentMonad m => SndQueue -> SndSwitchStatus -> m ()
checkSQSwchStatus sq@SndQueue {sndSwchStatus} expected =
  unless (sndSwchStatus == Just expected) $ switchStatusError sq expected sndSwchStatus

switchStatusError :: (SMPQueueRec q, AgentMonad m, Show a) => q -> a -> Maybe a -> m ()
switchStatusError q expected actual =
  throwError . INTERNAL $
    ("unexpected switch status, queueId=" <> show (queueId q))
      <> (", expected=" <> show expected)
      <> (", actual=" <> show actual)

connectReplyQueues :: AgentMonad m => AgentClient -> ConnData -> ConnInfo -> NonEmpty SMPQueueInfo -> m ()
connectReplyQueues c cData@ConnData {userId, connId} ownConnInfo (qInfo :| _) = do
  clientVRange <- asks $ smpClientVRange . config
  case qInfo `proveCompatible` clientVRange of
    Nothing -> throwError $ AGENT A_VERSION
    Just qInfo' -> do
      sq <- newSndQueue userId connId qInfo'
      sq' <- withStore c $ \db -> upgradeRcvConnToDuplex db connId sq
      enqueueConfirmation c cData sq' ownConnInfo Nothing Nothing

confirmQueueAsync :: forall m. AgentMonad m => AgentClient -> ConnData -> SndQueue -> SMPServerWithAuth -> ConnInfo -> Maybe (CR.SndE2ERatchetParams 'C.X448) -> CR.PQEncryption -> SubscriptionMode -> m ()
confirmQueueAsync c cData sq srv connInfo e2eEncryption_ pqEnc subMode = do
  storeConfirmation c cData sq e2eEncryption_ (Just pqEnc) =<< mkAgentConfirmation c cData sq srv connInfo subMode
  submitPendingMsg c cData sq

confirmQueue :: forall m. AgentMonad m => Compatible Version -> AgentClient -> ConnData -> SndQueue -> SMPServerWithAuth -> ConnInfo -> Maybe (CR.SndE2ERatchetParams 'C.X448) -> Maybe CR.PQEncryption -> SubscriptionMode -> m ()
confirmQueue (Compatible agentVersion) c cData@ConnData {connId} sq srv connInfo e2eEncryption_ pqEnc_ subMode = do
  msg <- mkConfirmation =<< mkAgentConfirmation c cData sq srv connInfo subMode
  sendConfirmation c sq msg
  withStore' c $ \db -> setSndQueueStatus db sq Confirmed
  where
    mkConfirmation :: AgentMessage -> m MsgBody
    mkConfirmation aMessage = withStore c $ \db -> runExceptT $ do
      void . liftIO $ updateSndIds db connId
      (encConnInfo, _) <- agentRatchetEncrypt db connId (smpEncode aMessage) e2eEncConnInfoLength pqEnc_
      pure . smpEncode $ AgentConfirmation {agentVersion, e2eEncryption_, encConnInfo}

mkAgentConfirmation :: AgentMonad m => AgentClient -> ConnData -> SndQueue -> SMPServerWithAuth -> ConnInfo -> SubscriptionMode -> m AgentMessage
mkAgentConfirmation c cData sq srv connInfo subMode = do
  qInfo <- createReplyQueue c cData sq subMode srv
  pure $ AgentConnInfoReply (qInfo :| []) connInfo

enqueueConfirmation :: AgentMonad m => AgentClient -> ConnData -> SndQueue -> ConnInfo -> Maybe (CR.SndE2ERatchetParams 'C.X448) -> Maybe CR.PQEncryption -> m ()
enqueueConfirmation c cData sq connInfo e2eEncryption_ pqEnc_ = do
  storeConfirmation c cData sq e2eEncryption_ pqEnc_ $ AgentConnInfo connInfo
  submitPendingMsg c cData sq

storeConfirmation :: AgentMonad m => AgentClient -> ConnData -> SndQueue -> Maybe (CR.SndE2ERatchetParams 'C.X448) -> Maybe CR.PQEncryption -> AgentMessage -> m ()
storeConfirmation c ConnData {connId, connAgentVersion} sq e2eEncryption_ pqEnc_ agentMsg = withStore c $ \db -> runExceptT $ do
  internalTs <- liftIO getCurrentTime
  (internalId, internalSndId, prevMsgHash) <- liftIO $ updateSndIds db connId
  let agentMsgStr = smpEncode agentMsg
      internalHash = C.sha256Hash agentMsgStr
  (encConnInfo, pqEncryption) <- agentRatchetEncrypt db connId agentMsgStr e2eEncConnInfoLength pqEnc_
  let msgBody = smpEncode $ AgentConfirmation {agentVersion = connAgentVersion, e2eEncryption_, encConnInfo}
      msgType = agentMessageType agentMsg
      msgData = SndMsgData {internalId, internalSndId, internalTs, msgType, msgBody, pqEncryption, msgFlags = SMP.MsgFlags {notification = True}, internalHash, prevMsgHash}
  liftIO $ createSndMsg db connId msgData
  liftIO $ createSndMsgDelivery db connId sq internalId

enqueueRatchetKeyMsgs :: forall m. AgentMonad m => AgentClient -> ConnData -> NonEmpty SndQueue -> CR.RcvE2ERatchetParams 'C.X448 -> m ()
enqueueRatchetKeyMsgs c cData (sq :| sqs) e2eEncryption = do
  msgId <- enqueueRatchetKey c cData sq e2eEncryption
  mapM_ (enqueueSavedMessage c cData msgId) $ filter isActiveSndQ sqs

enqueueRatchetKey :: forall m. AgentMonad m => AgentClient -> ConnData -> SndQueue -> CR.RcvE2ERatchetParams 'C.X448 -> m AgentMsgId
enqueueRatchetKey c cData@ConnData {connId} sq e2eEncryption = do
  aVRange <- asks $ smpAgentVRange . config
  msgId <- storeRatchetKey $ maxVersion aVRange
  submitPendingMsg c cData sq
  pure $ unId msgId
  where
    storeRatchetKey :: Version -> m InternalId
    storeRatchetKey agentVersion = withStore c $ \db -> runExceptT $ do
      internalTs <- liftIO getCurrentTime
      (internalId, internalSndId, prevMsgHash) <- liftIO $ updateSndIds db connId
      let agentMsg = AgentRatchetInfo ""
          agentMsgStr = smpEncode agentMsg
          internalHash = C.sha256Hash agentMsgStr
      let msgBody = smpEncode $ AgentRatchetKey {agentVersion, e2eEncryption, info = agentMsgStr}
          msgType = agentMessageType agentMsg
          -- TODO PQ set pqEncryption based on connection mode
          msgData = SndMsgData {internalId, internalSndId, internalTs, msgType, msgBody, pqEncryption = CR.PQEncOff, msgFlags = SMP.MsgFlags {notification = True}, internalHash, prevMsgHash}
      liftIO $ createSndMsg db connId msgData
      liftIO $ createSndMsgDelivery db connId sq internalId
      pure internalId

-- encoded AgentMessage -> encoded EncAgentMessage
agentRatchetEncrypt :: DB.Connection -> ConnId -> ByteString -> Int -> Maybe CR.PQEncryption -> ExceptT StoreError IO (ByteString, CR.PQEncryption)
agentRatchetEncrypt db connId msg paddedLen pqEnc_ = do
  rc <- ExceptT $ getRatchet db connId
  (encMsg, rc') <- liftE (SEAgentError . cryptoError) $ CR.rcEncrypt rc paddedLen msg pqEnc_
  liftIO $ updateRatchet db connId rc' CR.SMDNoChange
  pure (encMsg, CR.rcSndKEM rc')

-- encoded EncAgentMessage -> encoded AgentMessage
agentRatchetDecrypt :: TVar ChaChaDRG -> DB.Connection -> ConnId -> ByteString -> ExceptT StoreError IO (ByteString, CR.PQEncryption)
agentRatchetDecrypt g db connId encAgentMsg = do
  rc <- ExceptT $ getRatchet db connId
  agentRatchetDecrypt' g db connId rc encAgentMsg

agentRatchetDecrypt' :: TVar ChaChaDRG -> DB.Connection -> ConnId -> CR.RatchetX448 -> ByteString -> ExceptT StoreError IO (ByteString, CR.PQEncryption)
agentRatchetDecrypt' g db connId rc encAgentMsg = do
  skipped <- liftIO $ getSkippedMsgKeys db connId
  (agentMsgBody_, rc', skippedDiff) <- liftE (SEAgentError . cryptoError) $ CR.rcDecrypt g rc skipped encAgentMsg
  liftIO $ updateRatchet db connId rc' skippedDiff
  liftEither $ bimap (SEAgentError . cryptoError) (,CR.rcRcvKEM rc') agentMsgBody_

newSndQueue :: (MonadUnliftIO m, MonadReader Env m) => UserId -> ConnId -> Compatible SMPQueueInfo -> m NewSndQueue
newSndQueue userId connId (Compatible (SMPQueueInfo smpClientVersion SMPQueueAddress {smpServer, senderId, dhPublicKey = rcvE2ePubDhKey})) = do
  C.AuthAlg a <- asks $ sndAuthAlg . config
  g <- asks random
  (sndPublicKey, sndPrivateKey) <- atomically $ C.generateAuthKeyPair a g
  (e2ePubKey, e2ePrivKey) <- atomically $ C.generateKeyPair g
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
        dbQueueId = DBNewQueue,
        primary = True,
        dbReplaceQueueId = Nothing,
        sndSwchStatus = Nothing,
        smpClientVersion
      }
