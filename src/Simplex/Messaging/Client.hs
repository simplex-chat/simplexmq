{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE NumericUnderscores #-}
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
    SMPClient,
    getSMPClient,
    closeSMPClient,

    -- * SMP protocol command functions
    createSMPQueue,
    subscribeSMPQueue,
    subscribeSMPQueueNotifications,
    secureSMPQueue,
    enableSMPQueueNotifications,
    sendSMPMessage,
    ackSMPMessage,
    suspendSMPQueue,
    deleteSMPQueue,
    sendSMPCommand,

    -- * Supporting types and client configuration
    SMPClientError (..),
    SMPClientConfig (..),
    smpDefaultConfig,
    SMPServerTransmission,
  )
where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async
import Control.Concurrent.STM
import Control.Exception
import Control.Monad
import Control.Monad.Trans.Class
import Control.Monad.Trans.Except
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import Data.Maybe (fromMaybe)
import Network.Socket (ServiceName)
import Numeric.Natural
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Protocol
import Simplex.Messaging.Transport (ATransport (..), THandle (..), TLS, TProxy, Transport (..), TransportError, clientHandshake, runTransportClient)
import Simplex.Messaging.Transport.WebSockets (WS)
import Simplex.Messaging.Util (bshow, liftError, raceAny_)
import System.Timeout (timeout)

-- | 'SMPClient' is a handle used to send commands to a specific SMP server.
--
-- The only exported selector is blockSize that is negotiated
-- with the server during the TCP transport handshake.
--
-- Use 'getSMPClient' to connect to an SMP server and create a client handle.
data SMPClient = SMPClient
  { action :: Async (),
    connected :: TVar Bool,
    sessionId :: ByteString,
    smpServer :: SMPServer,
    tcpTimeout :: Int,
    clientCorrId :: TVar Natural,
    sentCommands :: TVar (Map CorrId Request),
    sndQ :: TBQueue SentRawTransmission,
    rcvQ :: TBQueue (SignedTransmission BrokerMsg),
    msgQ :: TBQueue SMPServerTransmission
  }

-- | Type synonym for transmission from some SPM server queue.
type SMPServerTransmission = (SMPServer, RecipientId, BrokerMsg)

-- | SMP client configuration.
data SMPClientConfig = SMPClientConfig
  { -- | size of TBQueue to use for server commands and responses
    qSize :: Natural,
    -- | default SMP server port if port is not specified in SMPServer
    defaultTransport :: (ServiceName, ATransport),
    -- | timeout of TCP commands (microseconds)
    tcpTimeout :: Int,
    -- | period for SMP ping commands (microseconds)
    smpPing :: Int
  }

-- | Default SMP client configuration.
smpDefaultConfig :: SMPClientConfig
smpDefaultConfig =
  SMPClientConfig
    { qSize = 16,
      defaultTransport = ("5223", transport @TLS),
      tcpTimeout = 4_000_000,
      smpPing = 30_000_000
    }

data Request = Request
  { queueId :: QueueId,
    responseVar :: TMVar Response
  }

type Response = Either SMPClientError BrokerMsg

-- | Connects to 'SMPServer' using passed client configuration
-- and queue for messages and notifications.
--
-- A single queue can be used for multiple 'SMPClient' instances,
-- as 'SMPServerTransmission' includes server information.
getSMPClient :: SMPServer -> SMPClientConfig -> TBQueue SMPServerTransmission -> IO () -> IO (Either SMPClientError SMPClient)
getSMPClient smpServer cfg@SMPClientConfig {qSize, tcpTimeout, smpPing} msgQ disconnected =
  atomically mkSMPClient >>= runClient useTransport
  where
    mkSMPClient :: STM SMPClient
    mkSMPClient = do
      connected <- newTVar False
      clientCorrId <- newTVar 0
      sentCommands <- newTVar M.empty
      sndQ <- newTBQueue qSize
      rcvQ <- newTBQueue qSize
      return
        SMPClient
          { action = undefined,
            sessionId = undefined,
            connected,
            smpServer,
            tcpTimeout,
            clientCorrId,
            sentCommands,
            sndQ,
            rcvQ,
            msgQ
          }

    runClient :: (ServiceName, ATransport) -> SMPClient -> IO (Either SMPClientError SMPClient)
    runClient (port', ATransport t) c = do
      thVar <- newEmptyTMVarIO
      action <-
        async $
          runTransportClient (host smpServer) port' (keyHash smpServer) (client t c thVar)
            `finally` atomically (putTMVar thVar $ Left SMPNetworkError)
      th_ <- tcpTimeout `timeout` atomically (takeTMVar thVar)
      pure $ case th_ of
        Just (Right THandle {sessionId}) -> Right c {action, sessionId}
        Just (Left e) -> Left e
        Nothing -> Left SMPNetworkError

    useTransport :: (ServiceName, ATransport)
    useTransport = case port smpServer of
      Nothing -> defaultTransport cfg
      Just "443" -> ("443", transport @WS)
      Just p -> (p, transport @TLS)

    client :: forall c. Transport c => TProxy c -> SMPClient -> TMVar (Either SMPClientError (THandle c)) -> c -> IO ()
    client _ c thVar h =
      runExceptT (clientHandshake h $ keyHash smpServer) >>= \case
        Left e -> atomically . putTMVar thVar . Left $ SMPTransportError e
        Right th@THandle {sessionId} -> do
          atomically $ do
            writeTVar (connected c) True
            putTMVar thVar $ Right th
          let c' = c {sessionId} :: SMPClient
          raceAny_ [send c' th, process c', receive c' th, ping c']
            `finally` disconnected

    send :: Transport c => SMPClient -> THandle c -> IO ()
    send SMPClient {sndQ} h = forever $ atomically (readTBQueue sndQ) >>= tPut h

    receive :: Transport c => SMPClient -> THandle c -> IO ()
    receive SMPClient {rcvQ} h = forever $ tGet h >>= atomically . writeTBQueue rcvQ

    ping :: SMPClient -> IO ()
    ping c = forever $ do
      threadDelay smpPing
      runExceptT $ sendSMPCommand c Nothing "" PING

    process :: SMPClient -> IO ()
    process SMPClient {rcvQ, sentCommands} = forever $ do
      (_, _, (corrId, qId, respOrErr)) <- atomically $ readTBQueue rcvQ
      if B.null $ bs corrId
        then sendMsg qId respOrErr
        else do
          cs <- readTVarIO sentCommands
          case M.lookup corrId cs of
            Nothing -> sendMsg qId respOrErr
            Just Request {queueId, responseVar} -> atomically $ do
              modifyTVar sentCommands $ M.delete corrId
              putTMVar responseVar $
                if queueId == qId
                  then case respOrErr of
                    Left e -> Left $ SMPResponseError e
                    Right (ERR e) -> Left $ SMPServerError e
                    Right r -> Right r
                  else Left SMPUnexpectedResponse

    sendMsg :: QueueId -> Either ErrorType BrokerMsg -> IO ()
    sendMsg qId = \case
      Right cmd -> atomically $ writeTBQueue msgQ (smpServer, qId, cmd)
      -- TODO send everything else to errQ and log in agent
      _ -> return ()

-- | Disconnects SMP client from the server and terminates client threads.
closeSMPClient :: SMPClient -> IO ()
closeSMPClient = uninterruptibleCancel . action

-- | SMP client error type.
data SMPClientError
  = -- | Correctly parsed SMP server ERR response.
    -- This error is forwarded to the agent client as `ERR SMP err`.
    SMPServerError ErrorType
  | -- | Invalid server response that failed to parse.
    -- Forwarded to the agent client as `ERR BROKER RESPONSE`.
    SMPResponseError ErrorType
  | -- | Different response from what is expected to a certain SMP command,
    -- e.g. server should respond `IDS` or `ERR` to `NEW` command,
    -- other responses would result in this error.
    -- Forwarded to the agent client as `ERR BROKER UNEXPECTED`.
    SMPUnexpectedResponse
  | -- | Used for TCP connection and command response timeouts.
    -- Forwarded to the agent client as `ERR BROKER TIMEOUT`.
    SMPResponseTimeout
  | -- | Failure to establish TCP connection.
    -- Forwarded to the agent client as `ERR BROKER NETWORK`.
    SMPNetworkError
  | -- | TCP transport handshake or some other transport error.
    -- Forwarded to the agent client as `ERR BROKER TRANSPORT e`.
    SMPTransportError TransportError
  | -- | Error when cryptographically "signing" the command.
    SMPSignatureError C.CryptoError
  deriving (Eq, Show, Exception)

-- | Create a new SMP queue.
--
-- https://github.com/simplex-chat/simplexmq/blob/master/protocol/simplex-messaging.md#create-queue-command
createSMPQueue ::
  SMPClient ->
  RcvPrivateSignKey ->
  RcvPublicVerifyKey ->
  RcvPublicDhKey ->
  ExceptT SMPClientError IO QueueIdsKeys
createSMPQueue c rpKey rKey dhKey =
  sendSMPCommand c (Just rpKey) "" (NEW rKey dhKey) >>= \case
    IDS qik -> pure qik
    _ -> throwE SMPUnexpectedResponse

-- | Subscribe to the SMP queue.
--
-- https://github.com/simplex-chat/simplexmq/blob/master/protocol/simplex-messaging.md#subscribe-to-queue
subscribeSMPQueue :: SMPClient -> RcvPrivateSignKey -> RecipientId -> ExceptT SMPClientError IO ()
subscribeSMPQueue c@SMPClient {smpServer, msgQ} rpKey rId =
  sendSMPCommand c (Just rpKey) rId SUB >>= \case
    OK -> return ()
    cmd@MSG {} ->
      lift . atomically $ writeTBQueue msgQ (smpServer, rId, cmd)
    _ -> throwE SMPUnexpectedResponse

-- | Subscribe to the SMP queue notifications.
--
-- https://github.com/simplex-chat/simplexmq/blob/master/protocol/simplex-messaging.md#subscribe-to-queue-notifications
subscribeSMPQueueNotifications :: SMPClient -> NtfPrivateSignKey -> NotifierId -> ExceptT SMPClientError IO ()
subscribeSMPQueueNotifications = okSMPCommand NSUB

-- | Secure the SMP queue by adding a sender public key.
--
-- https://github.com/simplex-chat/simplexmq/blob/master/protocol/simplex-messaging.md#secure-queue-command
secureSMPQueue :: SMPClient -> RcvPrivateSignKey -> RecipientId -> SndPublicVerifyKey -> ExceptT SMPClientError IO ()
secureSMPQueue c rpKey rId senderKey = okSMPCommand (KEY senderKey) c rpKey rId

-- | Enable notifications for the queue for push notifications server.
--
-- https://github.com/simplex-chat/simplexmq/blob/master/protocol/simplex-messaging.md#enable-notifications-command
enableSMPQueueNotifications :: SMPClient -> RcvPrivateSignKey -> RecipientId -> NtfPublicVerifyKey -> ExceptT SMPClientError IO NotifierId
enableSMPQueueNotifications c rpKey rId notifierKey =
  sendSMPCommand c (Just rpKey) rId (NKEY notifierKey) >>= \case
    NID nId -> pure nId
    _ -> throwE SMPUnexpectedResponse

-- | Send SMP message.
--
-- https://github.com/simplex-chat/simplexmq/blob/master/protocol/simplex-messaging.md#send-message
sendSMPMessage :: SMPClient -> Maybe SndPrivateSignKey -> SenderId -> MsgBody -> ExceptT SMPClientError IO ()
sendSMPMessage c spKey sId msg =
  sendSMPCommand c spKey sId (SEND msg) >>= \case
    OK -> pure ()
    _ -> throwE SMPUnexpectedResponse

-- | Acknowledge message delivery (server deletes the message).
--
-- https://github.com/simplex-chat/simplexmq/blob/master/protocol/simplex-messaging.md#acknowledge-message-delivery
ackSMPMessage :: SMPClient -> RcvPrivateSignKey -> QueueId -> ExceptT SMPClientError IO ()
ackSMPMessage c@SMPClient {smpServer, msgQ} rpKey rId =
  sendSMPCommand c (Just rpKey) rId ACK >>= \case
    OK -> return ()
    cmd@MSG {} ->
      lift . atomically $ writeTBQueue msgQ (smpServer, rId, cmd)
    _ -> throwE SMPUnexpectedResponse

-- | Irreversibly suspend SMP queue.
-- The existing messages from the queue will still be delivered.
--
-- https://github.com/simplex-chat/simplexmq/blob/master/protocol/simplex-messaging.md#suspend-queue
suspendSMPQueue :: SMPClient -> RcvPrivateSignKey -> QueueId -> ExceptT SMPClientError IO ()
suspendSMPQueue = okSMPCommand OFF

-- | Irreversibly delete SMP queue and all messages in it.
--
-- https://github.com/simplex-chat/simplexmq/blob/master/protocol/simplex-messaging.md#delete-queue
deleteSMPQueue :: SMPClient -> RcvPrivateSignKey -> QueueId -> ExceptT SMPClientError IO ()
deleteSMPQueue = okSMPCommand DEL

okSMPCommand :: PartyI p => Command p -> SMPClient -> C.APrivateSignKey -> QueueId -> ExceptT SMPClientError IO ()
okSMPCommand cmd c pKey qId =
  sendSMPCommand c (Just pKey) qId cmd >>= \case
    OK -> return ()
    _ -> throwE SMPUnexpectedResponse

-- | Send SMP command
-- TODO sign all requests (SEND of SMP confirmation would be signed with the same key that is passed to the recipient)
sendSMPCommand :: PartyI p => SMPClient -> Maybe C.APrivateSignKey -> QueueId -> Command p -> ExceptT SMPClientError IO BrokerMsg
sendSMPCommand SMPClient {sndQ, sentCommands, clientCorrId, sessionId, tcpTimeout} pKey qId cmd = do
  corrId <- lift_ getNextCorrId
  t <- signTransmission $ encodeTransmission sessionId (corrId, qId, cmd)
  ExceptT $ sendRecv corrId t
  where
    lift_ :: STM a -> ExceptT SMPClientError IO a
    lift_ action = ExceptT $ Right <$> atomically action

    getNextCorrId :: STM CorrId
    getNextCorrId = do
      i <- stateTVar clientCorrId $ \i -> (i, i + 1)
      pure . CorrId $ bshow i

    signTransmission :: ByteString -> ExceptT SMPClientError IO SentRawTransmission
    signTransmission t = case pKey of
      Nothing -> return (Nothing, t)
      Just pk -> do
        sig <- liftError SMPSignatureError $ C.sign pk t
        return (Just sig, t)

    -- two separate "atomically" needed to avoid blocking
    sendRecv :: CorrId -> SentRawTransmission -> IO Response
    sendRecv corrId t = atomically (send corrId t) >>= withTimeout . atomically . takeTMVar
      where
        withTimeout a = fromMaybe (Left SMPResponseTimeout) <$> timeout tcpTimeout a

    send :: CorrId -> SentRawTransmission -> STM (TMVar Response)
    send corrId t = do
      r <- newEmptyTMVar
      modifyTVar sentCommands . M.insert corrId $ Request qId r
      writeTBQueue sndQ t
      return r
