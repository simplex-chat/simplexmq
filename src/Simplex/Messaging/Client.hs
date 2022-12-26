{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DisambiguateRecordFields #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

-- |
-- Module      : Simplex.Messaging.Client
-- Copyright   : (c) simplex.chat
-- License     : AGPL-3
--
-- Maintainer  : chat@simplex.chat
-- Stability   : experimental
-- Portability : non-portable
--
-- This module provides a functional client API for SMP protocol.
--
-- See https://github.com/simplex-chat/simplexmq/blob/master/protocol/simplex-messaging.md
module Simplex.Messaging.Client
  ( -- * Connect (disconnect) client to (from) SMP server
    ProtocolClient (thVersion, sessionId, sessionTs),
    SMPClient,
    getProtocolClient,
    closeProtocolClient,
    clientServer,
    transportHost',

    -- * SMP protocol command functions
    createSMPQueue,
    subscribeSMPQueue,
    subscribeSMPQueues,
    getSMPMessage,
    subscribeSMPQueueNotifications,
    secureSMPQueue,
    enableSMPQueueNotifications,
    disableSMPQueueNotifications,
    enableSMPQueuesNtfs,
    disableSMPQueuesNtfs,
    sendSMPMessage,
    ackSMPMessage,
    suspendSMPQueue,
    deleteSMPQueue,
    sendProtocolCommand,

    -- * Supporting types and client configuration
    ProtocolClientError (..),
    ProtocolClientConfig (..),
    NetworkConfig (..),
    defaultClientConfig,
    defaultNetworkConfig,
    transportClientConfig,
    chooseTransportHost,
    ServerTransmission,
  )
where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async
import Control.Concurrent.STM
import Control.Exception
import Control.Monad
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Trans.Except
import Data.Aeson (FromJSON (..), ToJSON (..))
import qualified Data.Aeson as J
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.Either (rights)
import Data.Functor (($>))
import Data.List (find)
import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as L
import Data.Maybe (fromMaybe)
import Data.Time.Clock (UTCTime, getCurrentTime)
import GHC.Generics (Generic)
import Network.Socket (ServiceName)
import Numeric.Natural
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Parsers (dropPrefix, enumJSON)
import Simplex.Messaging.Protocol as SMP
import Simplex.Messaging.TMap (TMap)
import qualified Simplex.Messaging.TMap as TM
import Simplex.Messaging.Transport
import Simplex.Messaging.Transport.Client (SocksProxy, TransportClientConfig (..), TransportHost (..), runTransportClient)
import Simplex.Messaging.Transport.KeepAlive
import Simplex.Messaging.Transport.WebSockets (WS)
import Simplex.Messaging.Util (bshow, liftError, raceAny_)
import Simplex.Messaging.Version
import System.Timeout (timeout)

-- | 'SMPClient' is a handle used to send commands to a specific SMP server.
--
-- Use 'getSMPClient' to connect to an SMP server and create a client handle.
data ProtocolClient msg = ProtocolClient
  { action :: Maybe (Async ()),
    sessionId :: SessionId,
    sessionTs :: UTCTime,
    thVersion :: Version,
    client_ :: PClient msg
  }

data PClient msg = PClient
  { connected :: TVar Bool,
    protocolServer :: ProtoServer msg,
    transportHost :: TransportHost,
    tcpTimeout :: Int,
    clientCorrId :: TVar Natural,
    sentCommands :: TMap CorrId (Request msg),
    sndQ :: TBQueue (NonEmpty SentRawTransmission),
    rcvQ :: TBQueue (NonEmpty (SignedTransmission msg)),
    msgQ :: Maybe (TBQueue (ServerTransmission msg))
  }

type SMPClient = ProtocolClient SMP.BrokerMsg

-- | Type for client command data
type ClientCommand msg = (Maybe C.APrivateSignKey, QueueId, ProtoCommand msg)

-- | Type synonym for transmission from some SPM server queue.
type ServerTransmission msg = (ProtoServer msg, Version, SessionId, QueueId, msg)

data HostMode
  = -- | prefer (or require) onion hosts when connecting via SOCKS proxy
    HMOnionViaSocks
  | -- | prefer (or require) onion hosts
    HMOnion
  | -- | prefer (or require) public hosts
    HMPublic
  deriving (Eq, Show, Generic)

instance FromJSON HostMode where
  parseJSON = J.genericParseJSON . enumJSON $ dropPrefix "HM"

instance ToJSON HostMode where
  toJSON = J.genericToJSON . enumJSON $ dropPrefix "HM"
  toEncoding = J.genericToEncoding . enumJSON $ dropPrefix "HM"

-- | network configuration for the client
data NetworkConfig = NetworkConfig
  { -- | use SOCKS5 proxy
    socksProxy :: Maybe SocksProxy,
    -- | determines critera which host is chosen from the list
    hostMode :: HostMode,
    -- | if above criteria is not met, if the below setting is True return error, otherwise use the first host
    requiredHostMode :: Bool,
    -- | timeout for the initial client TCP/TLS connection (microseconds)
    tcpConnectTimeout :: Int,
    -- | timeout of protocol commands (microseconds)
    tcpTimeout :: Int,
    -- | TCP keep-alive options, Nothing to skip enabling keep-alive
    tcpKeepAlive :: Maybe KeepAliveOpts,
    -- | period for SMP ping commands (microseconds)
    smpPingInterval :: Int,
    logTLSErrors :: Bool
  }
  deriving (Eq, Show, Generic, FromJSON)

instance ToJSON NetworkConfig where
  toJSON = J.genericToJSON J.defaultOptions {J.omitNothingFields = True}
  toEncoding = J.genericToEncoding J.defaultOptions {J.omitNothingFields = True}

defaultNetworkConfig :: NetworkConfig
defaultNetworkConfig =
  NetworkConfig
    { socksProxy = Nothing,
      hostMode = HMOnionViaSocks,
      requiredHostMode = False,
      tcpConnectTimeout = 7_500_000,
      tcpTimeout = 5_000_000,
      tcpKeepAlive = Just defaultKeepAliveOpts,
      smpPingInterval = 600_000_000, -- 10min
      logTLSErrors = False
    }

transportClientConfig :: NetworkConfig -> TransportClientConfig
transportClientConfig NetworkConfig {socksProxy, tcpKeepAlive, logTLSErrors} =
  TransportClientConfig {socksProxy, tcpKeepAlive, logTLSErrors}

-- | protocol client configuration.
data ProtocolClientConfig = ProtocolClientConfig
  { -- | size of TBQueue to use for server commands and responses
    qSize :: Natural,
    -- | default server port if port is not specified in ProtocolServer
    defaultTransport :: (ServiceName, ATransport),
    -- | network configuration
    networkConfig :: NetworkConfig,
    -- | SMP client-server protocol version range
    smpServerVRange :: VersionRange
  }

-- | Default protocol client configuration.
defaultClientConfig :: ProtocolClientConfig
defaultClientConfig =
  ProtocolClientConfig
    { qSize = 64,
      defaultTransport = ("443", transport @TLS),
      networkConfig = defaultNetworkConfig,
      smpServerVRange = supportedSMPServerVRange
    }

data Request msg = Request
  { queueId :: QueueId,
    responseVar :: TMVar (Response msg)
  }

type Response msg = Either ProtocolClientError msg

chooseTransportHost :: NetworkConfig -> NonEmpty TransportHost -> Either ProtocolClientError TransportHost
chooseTransportHost NetworkConfig {socksProxy, hostMode, requiredHostMode} hosts =
  firstOrError $ case hostMode of
    HMOnionViaSocks -> maybe publicHost (const onionHost) socksProxy
    HMOnion -> onionHost
    HMPublic -> publicHost
  where
    firstOrError
      | requiredHostMode = maybe (Left PCEIncompatibleHost) Right
      | otherwise = Right . fromMaybe (L.head hosts)
    isOnionHost = \case THOnionHost _ -> True; _ -> False
    onionHost = find isOnionHost hosts
    publicHost = find (not . isOnionHost) hosts

clientServer :: ProtocolTypeI (ProtoType msg) => ProtocolClient msg -> String
clientServer = B.unpack . strEncode . protocolServer . client_

transportHost' :: ProtocolClient msg -> TransportHost
transportHost' = transportHost . client_

-- | Connects to 'ProtocolServer' using passed client configuration
-- and queue for messages and notifications.
--
-- A single queue can be used for multiple 'SMPClient' instances,
-- as 'SMPServerTransmission' includes server information.
getProtocolClient :: forall msg. Protocol msg => ProtoServer msg -> ProtocolClientConfig -> Maybe (TBQueue (ServerTransmission msg)) -> (ProtocolClient msg -> IO ()) -> IO (Either ProtocolClientError (ProtocolClient msg))
getProtocolClient protocolServer cfg@ProtocolClientConfig {qSize, networkConfig, smpServerVRange} msgQ disconnected = do
  case chooseTransportHost networkConfig (host protocolServer) of
    Right useHost ->
      (atomically (mkProtocolClient useHost) >>= runClient useTransport useHost)
        `catch` \(e :: IOException) -> pure . Left $ PCEIOError e
    Left e -> pure $ Left e
  where
    NetworkConfig {tcpConnectTimeout, tcpTimeout, smpPingInterval} = networkConfig
    mkProtocolClient :: TransportHost -> STM (PClient msg)
    mkProtocolClient transportHost = do
      connected <- newTVar False
      clientCorrId <- newTVar 0
      sentCommands <- TM.empty
      sndQ <- newTBQueue qSize
      rcvQ <- newTBQueue qSize
      return
        PClient
          { connected,
            protocolServer,
            transportHost,
            tcpTimeout,
            clientCorrId,
            sentCommands,
            sndQ,
            rcvQ,
            msgQ
          }

    runClient :: (ServiceName, ATransport) -> TransportHost -> PClient msg -> IO (Either ProtocolClientError (ProtocolClient msg))
    runClient (port', ATransport t) useHost c = do
      cVar <- newEmptyTMVarIO
      let tcConfig = transportClientConfig networkConfig
      action <-
        async $
          runTransportClient tcConfig useHost port' (Just $ keyHash protocolServer) (client t c cVar)
            `finally` atomically (putTMVar cVar $ Left PCENetworkError)
      c_ <- tcpConnectTimeout `timeout` atomically (takeTMVar cVar)
      pure $ case c_ of
        Just (Right c') -> Right c' {action = Just action}
        Just (Left e) -> Left e
        Nothing -> Left PCENetworkError

    useTransport :: (ServiceName, ATransport)
    useTransport = case port protocolServer of
      "" -> defaultTransport cfg
      "80" -> ("80", transport @WS)
      p -> (p, transport @TLS)

    client :: forall c. Transport c => TProxy c -> PClient msg -> TMVar (Either ProtocolClientError (ProtocolClient msg)) -> c -> IO ()
    client _ c cVar h =
      runExceptT (protocolClientHandshake @msg h (keyHash protocolServer) smpServerVRange) >>= \case
        Left e -> atomically . putTMVar cVar . Left $ PCETransportError e
        Right th@THandle {sessionId, thVersion} -> do
          sessionTs <- getCurrentTime
          let c' = ProtocolClient {action = Nothing, client_ = c, sessionId, thVersion, sessionTs}
          atomically $ do
            writeTVar (connected c) True
            putTMVar cVar $ Right c'
          raceAny_ ([send c' th, process c', receive c' th] <> [ping c' | smpPingInterval > 0])
            `finally` disconnected c'

    send :: Transport c => ProtocolClient msg -> THandle c -> IO ()
    send ProtocolClient {client_ = PClient {sndQ}} h = forever $ atomically (readTBQueue sndQ) >>= tPut h

    receive :: Transport c => ProtocolClient msg -> THandle c -> IO ()
    receive ProtocolClient {client_ = PClient {rcvQ}} h = forever $ tGet h >>= atomically . writeTBQueue rcvQ

    ping :: ProtocolClient msg -> IO ()
    ping c = forever $ do
      threadDelay smpPingInterval
      runExceptT $ sendProtocolCommand c Nothing "" protocolPing

    process :: ProtocolClient msg -> IO ()
    process c = forever $ atomically (readTBQueue $ rcvQ $ client_ c) >>= mapM_ (processMsg c)

    processMsg :: ProtocolClient msg -> SignedTransmission msg -> IO ()
    processMsg c@ProtocolClient {client_ = PClient {sentCommands}} (_, _, (corrId, qId, respOrErr)) =
      if B.null $ bs corrId
        then sendMsg respOrErr
        else do
          atomically (TM.lookup corrId sentCommands) >>= \case
            Nothing -> sendMsg respOrErr
            Just Request {queueId, responseVar} -> atomically $ do
              TM.delete corrId sentCommands
              putTMVar responseVar $
                if queueId == qId
                  then case respOrErr of
                    Left e -> Left $ PCEResponseError e
                    Right r -> case protocolError r of
                      Just e -> Left $ PCEProtocolError e
                      _ -> Right r
                  else Left . PCEUnexpectedResponse $ bshow respOrErr
      where
        sendMsg :: Either ErrorType msg -> IO ()
        sendMsg = \case
          Right msg -> atomically $ mapM_ (`writeTBQueue` serverTransmission c qId msg) msgQ
          Left e -> putStrLn $ "SMP client error: " <> show e

-- | Disconnects client from the server and terminates client threads.
closeProtocolClient :: ProtocolClient msg -> IO ()
closeProtocolClient = mapM_ uninterruptibleCancel . action

-- | SMP client error type.
data ProtocolClientError
  = -- | Correctly parsed SMP server ERR response.
    -- This error is forwarded to the agent client as `ERR SMP err`.
    PCEProtocolError ErrorType
  | -- | Invalid server response that failed to parse.
    -- Forwarded to the agent client as `ERR BROKER RESPONSE`.
    PCEResponseError ErrorType
  | -- | Different response from what is expected to a certain SMP command,
    -- e.g. server should respond `IDS` or `ERR` to `NEW` command,
    -- other responses would result in this error.
    -- Forwarded to the agent client as `ERR BROKER UNEXPECTED`.
    PCEUnexpectedResponse ByteString
  | -- | Used for TCP connection and command response timeouts.
    -- Forwarded to the agent client as `ERR BROKER TIMEOUT`.
    PCEResponseTimeout
  | -- | Failure to establish TCP connection.
    -- Forwarded to the agent client as `ERR BROKER NETWORK`.
    PCENetworkError
  | -- | No host compatible with network configuration
    PCEIncompatibleHost
  | -- | TCP transport handshake or some other transport error.
    -- Forwarded to the agent client as `ERR BROKER TRANSPORT e`.
    PCETransportError TransportError
  | -- | Error when cryptographically "signing" the command.
    PCESignatureError C.CryptoError
  | -- | IO Error
    PCEIOError IOException
  deriving (Eq, Show, Exception)

-- | Create a new SMP queue.
--
-- https://github.com/simplex-chat/simplexmq/blob/master/protocol/simplex-messaging.md#create-queue-command
createSMPQueue ::
  SMPClient ->
  RcvPrivateSignKey ->
  RcvPublicVerifyKey ->
  RcvPublicDhKey ->
  Maybe BasicAuth ->
  ExceptT ProtocolClientError IO QueueIdsKeys
createSMPQueue c rpKey rKey dhKey auth =
  sendSMPCommand c (Just rpKey) "" (NEW rKey dhKey auth) >>= \case
    IDS qik -> pure qik
    r -> throwE . PCEUnexpectedResponse $ bshow r

-- | Subscribe to the SMP queue.
--
-- https://github.com/simplex-chat/simplexmq/blob/master/protocol/simplex-messaging.md#subscribe-to-queue
subscribeSMPQueue :: SMPClient -> RcvPrivateSignKey -> RecipientId -> ExceptT ProtocolClientError IO ()
subscribeSMPQueue c rpKey rId =
  sendSMPCommand c (Just rpKey) rId SUB >>= \case
    OK -> return ()
    cmd@MSG {} -> liftIO $ writeSMPMessage c rId cmd
    r -> throwE . PCEUnexpectedResponse $ bshow r

-- | Subscribe to multiple SMP queues batching commands if supported.
subscribeSMPQueues :: SMPClient -> NonEmpty (RcvPrivateSignKey, RecipientId) -> IO (NonEmpty (Either ProtocolClientError ()))
subscribeSMPQueues c qs = sendProtocolCommands c cs >>= mapM response . L.zip qs
  where
    cs = L.map (\(rpKey, rId) -> (Just rpKey, rId, Cmd SRecipient SUB)) qs
    response ((_, rId), r) = case r of
      Right OK -> pure $ Right ()
      Right cmd@MSG {} -> writeSMPMessage c rId cmd $> Right ()
      Right r' -> pure . Left . PCEUnexpectedResponse $ bshow r'
      Left e -> pure $ Left e

writeSMPMessage :: SMPClient -> RecipientId -> BrokerMsg -> IO ()
writeSMPMessage c rId msg = atomically $ mapM_ (`writeTBQueue` serverTransmission c rId msg) (msgQ $ client_ c)

serverTransmission :: ProtocolClient msg -> RecipientId -> msg -> ServerTransmission msg
serverTransmission ProtocolClient {thVersion, sessionId, client_ = PClient {protocolServer}} entityId message =
  (protocolServer, thVersion, sessionId, entityId, message)

-- | Get message from SMP queue. The server returns ERR PROHIBITED if a client uses SUB and GET via the same transport connection for the same queue
--
-- https://github.covm/simplex-chat/simplexmq/blob/master/protocol/simplex-messaging.md#receive-a-message-from-the-queue
getSMPMessage :: SMPClient -> RcvPrivateSignKey -> RecipientId -> ExceptT ProtocolClientError IO (Maybe RcvMessage)
getSMPMessage c rpKey rId =
  sendSMPCommand c (Just rpKey) rId GET >>= \case
    OK -> pure Nothing
    cmd@(MSG msg) -> liftIO (writeSMPMessage c rId cmd) $> Just msg
    r -> throwE . PCEUnexpectedResponse $ bshow r

-- | Subscribe to the SMP queue notifications.
--
-- https://github.com/simplex-chat/simplexmq/blob/master/protocol/simplex-messaging.md#subscribe-to-queue-notifications
subscribeSMPQueueNotifications :: SMPClient -> NtfPrivateSignKey -> NotifierId -> ExceptT ProtocolClientError IO ()
subscribeSMPQueueNotifications = okSMPCommand NSUB

-- | Secure the SMP queue by adding a sender public key.
--
-- https://github.com/simplex-chat/simplexmq/blob/master/protocol/simplex-messaging.md#secure-queue-command
secureSMPQueue :: SMPClient -> RcvPrivateSignKey -> RecipientId -> SndPublicVerifyKey -> ExceptT ProtocolClientError IO ()
secureSMPQueue c rpKey rId senderKey = okSMPCommand (KEY senderKey) c rpKey rId

-- | Enable notifications for the queue for push notifications server.
--
-- https://github.com/simplex-chat/simplexmq/blob/master/protocol/simplex-messaging.md#enable-notifications-command
enableSMPQueueNotifications :: SMPClient -> RcvPrivateSignKey -> RecipientId -> NtfPublicVerifyKey -> RcvNtfPublicDhKey -> ExceptT ProtocolClientError IO (NotifierId, RcvNtfPublicDhKey)
enableSMPQueueNotifications c rpKey rId notifierKey rcvNtfPublicDhKey =
  sendSMPCommand c (Just rpKey) rId (NKEY notifierKey rcvNtfPublicDhKey) >>= \case
    NID nId rcvNtfSrvPublicDhKey -> pure (nId, rcvNtfSrvPublicDhKey)
    r -> throwE . PCEUnexpectedResponse $ bshow r

-- | Enable notifications for the multiple queues for push notifications server.
enableSMPQueuesNtfs :: SMPClient -> NonEmpty (RcvPrivateSignKey, RecipientId, NtfPublicVerifyKey, RcvNtfPublicDhKey) -> IO (NonEmpty (Either ProtocolClientError (NotifierId, RcvNtfPublicDhKey)))
enableSMPQueuesNtfs c qs = L.map response <$> sendProtocolCommands c cs
  where
    cs = L.map (\(rpKey, rId, notifierKey, rcvNtfPublicDhKey) -> (Just rpKey, rId, Cmd SRecipient $ NKEY notifierKey rcvNtfPublicDhKey)) qs
    response = \case
      Right (NID nId rcvNtfSrvPublicDhKey) -> Right (nId, rcvNtfSrvPublicDhKey)
      Right r -> Left . PCEUnexpectedResponse $ bshow r
      Left e -> Left e

-- | Disable notifications for the queue for push notifications server.
--
-- https://github.com/simplex-chat/simplexmq/blob/master/protocol/simplex-messaging.md#disable-notifications-command
disableSMPQueueNotifications :: SMPClient -> RcvPrivateSignKey -> RecipientId -> ExceptT ProtocolClientError IO ()
disableSMPQueueNotifications = okSMPCommand NDEL

-- | Disable notifications for multiple queues for push notifications server.
disableSMPQueuesNtfs :: SMPClient -> NonEmpty (RcvPrivateSignKey, RecipientId) -> IO (NonEmpty (Either ProtocolClientError ()))
disableSMPQueuesNtfs c qs = L.map response <$> sendProtocolCommands c cs
  where
    cs = L.map (\(rpKey, rId) -> (Just rpKey, rId, Cmd SRecipient NDEL)) qs
    response = \case
      Right OK -> Right ()
      Right r -> Left . PCEUnexpectedResponse $ bshow r
      Left e -> Left e

-- | Send SMP message.
--
-- https://github.com/simplex-chat/simplexmq/blob/master/protocol/simplex-messaging.md#send-message
sendSMPMessage :: SMPClient -> Maybe SndPrivateSignKey -> SenderId -> MsgFlags -> MsgBody -> ExceptT ProtocolClientError IO ()
sendSMPMessage c spKey sId flags msg =
  sendSMPCommand c spKey sId (SEND flags msg) >>= \case
    OK -> pure ()
    r -> throwE . PCEUnexpectedResponse $ bshow r

-- | Acknowledge message delivery (server deletes the message).
--
-- https://github.com/simplex-chat/simplexmq/blob/master/protocol/simplex-messaging.md#acknowledge-message-delivery
ackSMPMessage :: SMPClient -> RcvPrivateSignKey -> QueueId -> MsgId -> ExceptT ProtocolClientError IO ()
ackSMPMessage c rpKey rId msgId =
  sendSMPCommand c (Just rpKey) rId (ACK msgId) >>= \case
    OK -> return ()
    cmd@MSG {} -> liftIO $ writeSMPMessage c rId cmd
    r -> throwE . PCEUnexpectedResponse $ bshow r

-- | Irreversibly suspend SMP queue.
-- The existing messages from the queue will still be delivered.
--
-- https://github.com/simplex-chat/simplexmq/blob/master/protocol/simplex-messaging.md#suspend-queue
suspendSMPQueue :: SMPClient -> RcvPrivateSignKey -> QueueId -> ExceptT ProtocolClientError IO ()
suspendSMPQueue = okSMPCommand OFF

-- | Irreversibly delete SMP queue and all messages in it.
--
-- https://github.com/simplex-chat/simplexmq/blob/master/protocol/simplex-messaging.md#delete-queue
deleteSMPQueue :: SMPClient -> RcvPrivateSignKey -> QueueId -> ExceptT ProtocolClientError IO ()
deleteSMPQueue = okSMPCommand DEL

okSMPCommand :: PartyI p => Command p -> SMPClient -> C.APrivateSignKey -> QueueId -> ExceptT ProtocolClientError IO ()
okSMPCommand cmd c pKey qId =
  sendSMPCommand c (Just pKey) qId cmd >>= \case
    OK -> return ()
    r -> throwE . PCEUnexpectedResponse $ bshow r

-- | Send SMP command
sendSMPCommand :: PartyI p => SMPClient -> Maybe C.APrivateSignKey -> QueueId -> Command p -> ExceptT ProtocolClientError IO BrokerMsg
sendSMPCommand c pKey qId cmd = sendProtocolCommand c pKey qId (Cmd sParty cmd)

-- | Send multiple commands with batching and collect responses
sendProtocolCommands :: forall msg. ProtocolEncoding (ProtoCommand msg) => ProtocolClient msg -> NonEmpty (ClientCommand msg) -> IO (NonEmpty (Either ProtocolClientError msg))
sendProtocolCommands c@ProtocolClient {client_ = PClient {sndQ, tcpTimeout}} cs = do
  ts <- mapM (runExceptT . mkTransmission c) cs
  mapM_ (atomically . writeTBQueue sndQ . L.map fst) . L.nonEmpty . rights $ L.toList ts
  forConcurrently ts $ \case
    Right (_, r) -> withTimeout . atomically $ takeTMVar r
    Left e -> pure $ Left e
  where
    withTimeout a = fromMaybe (Left PCEResponseTimeout) <$> timeout tcpTimeout a

-- | Send Protocol command
sendProtocolCommand :: forall msg. ProtocolEncoding (ProtoCommand msg) => ProtocolClient msg -> Maybe C.APrivateSignKey -> QueueId -> ProtoCommand msg -> ExceptT ProtocolClientError IO msg
sendProtocolCommand c@ProtocolClient {client_ = PClient {sndQ, tcpTimeout}} pKey qId cmd = do
  (t, r) <- mkTransmission c (pKey, qId, cmd)
  ExceptT $ sendRecv t r
  where
    -- two separate "atomically" needed to avoid blocking
    sendRecv :: SentRawTransmission -> TMVar (Response msg) -> IO (Response msg)
    sendRecv t r = atomically (writeTBQueue sndQ [t]) >> withTimeout (atomically $ takeTMVar r)
      where
        withTimeout a = fromMaybe (Left PCEResponseTimeout) <$> timeout tcpTimeout a

mkTransmission :: forall msg. ProtocolEncoding (ProtoCommand msg) => ProtocolClient msg -> ClientCommand msg -> ExceptT ProtocolClientError IO (SentRawTransmission, TMVar (Response msg))
mkTransmission ProtocolClient {sessionId, thVersion, client_ = PClient {clientCorrId, sentCommands}} (pKey, qId, cmd) = do
  corrId <- liftIO $ atomically getNextCorrId
  t <- signTransmission $ encodeTransmission thVersion sessionId (corrId, qId, cmd)
  r <- liftIO . atomically $ mkRequest corrId
  pure (t, r)
  where
    getNextCorrId :: STM CorrId
    getNextCorrId = do
      i <- stateTVar clientCorrId $ \i -> (i, i + 1)
      pure . CorrId $ bshow i
    signTransmission :: ByteString -> ExceptT ProtocolClientError IO SentRawTransmission
    signTransmission t = case pKey of
      Nothing -> pure (Nothing, t)
      Just pk -> do
        sig <- liftError PCESignatureError $ C.sign pk t
        return (Just sig, t)
    mkRequest :: CorrId -> STM (TMVar (Response msg))
    mkRequest corrId = do
      r <- newEmptyTMVar
      TM.insert corrId (Request qId r) sentCommands
      pure r
