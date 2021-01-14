{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Simplex.Messaging.Client
  ( SMPClient,
    messageQ,
    endSubQ,
    getSMPClient,
    createSMPQueue,
    sendSMPMessage,
    ackSMPMessage,
    sendSMPCommand,
    SMPClientError (..),
    SMPClientConfig (..),
    smpDefaultConfig,
  )
where

import Control.Concurrent.Async
import Control.Concurrent.STM
import Control.Exception
import Control.Monad
import Control.Monad.Trans.Class
import Control.Monad.Trans.Except
import qualified Data.ByteString.Char8 as B
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import Data.Maybe
import Network.Socket (ServiceName)
import Numeric.Natural
import Simplex.Messaging.Agent.Transmission (SMPServer (..))
import Simplex.Messaging.Server.MsgStore (Message (..)) -- move to Simplex.Messaging.Core
import Simplex.Messaging.Server.Transmission
import Simplex.Messaging.Transport
import Simplex.Messaging.Util
import System.IO

data SMPClient = SMPClient
  { action :: Async (),
    clientCorrId :: TVar Natural,
    sentCommands :: TVar (Map CorrId Request),
    sndQ :: TBQueue Transmission,
    rcvQ :: TBQueue TransmissionOrError,
    messageQ :: TBQueue (RecipientId, Message),
    endSubQ :: TBQueue RecipientId
  }

data SMPClientConfig = SMPClientConfig
  { qSize :: Natural,
    defaultPort :: ServiceName
  }

smpDefaultConfig :: SMPClientConfig
smpDefaultConfig = SMPClientConfig 16 "5223"

data Request = Request
  { queueId :: QueueId,
    responseVar :: TMVar (Either SMPClientError Cmd)
  }

getSMPClient :: SMPServer -> SMPClientConfig -> IO SMPClient
getSMPClient SMPServer {host, port} SMPClientConfig {qSize, defaultPort} = do
  c <- atomically mkSMPClient
  action <- async $ runTCPClient host (fromMaybe defaultPort port) (client c)
  return c {action}
  where
    mkSMPClient :: STM SMPClient
    mkSMPClient = do
      clientCorrId <- newTVar 0
      sentCommands <- newTVar M.empty
      sndQ <- newTBQueue qSize
      rcvQ <- newTBQueue qSize
      messageQ <- newTBQueue qSize
      endSubQ <- newTBQueue qSize
      return SMPClient {action = undefined, clientCorrId, sentCommands, sndQ, rcvQ, endSubQ, messageQ}

    client :: SMPClient -> Handle -> IO ()
    client c h = do
      _line <- getLn h -- "Welcome to SMP"
      -- TODO test connection failure
      raceAny_ [send c h, process c, receive c h]

    send :: SMPClient -> Handle -> IO ()
    send SMPClient {sndQ} h = forever $ atomically (readTBQueue sndQ) >>= tPut h

    receive :: SMPClient -> Handle -> IO ()
    receive SMPClient {rcvQ} h = forever $ tGet fromServer h >>= atomically . writeTBQueue rcvQ

    process :: SMPClient -> IO ()
    process SMPClient {rcvQ, messageQ, endSubQ, sentCommands} = forever . atomically $ do
      (_, (corrId, qId, respOrErr)) <- readTBQueue rcvQ
      cs <- readTVar sentCommands
      case M.lookup corrId cs of
        Nothing ->
          case respOrErr of
            Right (Cmd _ (MSG msgId ts msgBody)) ->
              writeTBQueue messageQ (qId, Message {msgId, ts, msgBody})
            Right (Cmd _ END) -> writeTBQueue endSubQ qId
            -- TODO maybe have one more queue to write unexpected responses
            _ -> return ()
        Just Request {queueId, responseVar} -> do
          modifyTVar sentCommands $ M.delete corrId
          putTMVar responseVar $
            if queueId == qId
              then case respOrErr of
                Left e -> Left $ SMPResponseError e
                Right (Cmd _ (ERR e)) -> Left $ SMPServerError e
                Right r -> Right r
              else Left SMPQueueIdError

data SMPClientError
  = SMPServerError ErrorType
  | SMPResponseError ErrorType
  | SMPQueueIdError
  | SMPUnexpectedResponse
  | SMPResponseTimeout
  | SMPClientError
  deriving (Eq, Show, Exception)

createSMPQueue :: SMPClient -> RecipientKey -> ExceptT SMPClientError IO (RecipientId, SenderId)
createSMPQueue c rKey =
  sendSMPCommand c "" "" (Cmd SRecipient $ NEW rKey) >>= \case
    Cmd _ (IDS rId sId) -> return (rId, sId)
    _ -> throwE SMPUnexpectedResponse

sendSMPMessage :: SMPClient -> SenderKey -> QueueId -> MsgBody -> ExceptT SMPClientError IO ()
sendSMPMessage c sKey qId msg =
  sendSMPCommand c sKey qId (Cmd SSender $ SEND msg) >>= \case
    Cmd _ OK -> return ()
    _ -> throwE SMPUnexpectedResponse

ackSMPMessage :: SMPClient -> RecipientKey -> QueueId -> ExceptT SMPClientError IO ()
ackSMPMessage c@SMPClient {messageQ} rKey qId =
  sendSMPCommand c rKey qId (Cmd SRecipient ACK) >>= \case
    Cmd _ OK -> return ()
    Cmd _ (MSG msgId ts msgBody) ->
      lift . atomically $ writeTBQueue messageQ (qId, Message {msgId, ts, msgBody})
    _ -> throwE SMPUnexpectedResponse

sendSMPCommand :: SMPClient -> PrivateKey -> QueueId -> Cmd -> ExceptT SMPClientError IO Cmd
sendSMPCommand SMPClient {sndQ, sentCommands, clientCorrId} pKey qId cmd = ExceptT $ do
  corrId <- atomically getNextCorrId
  t <- signTransmission (corrId, qId, cmd)
  atomically (send corrId t) >>= atomically . takeTMVar
  where
    getNextCorrId :: STM CorrId
    getNextCorrId = do
      i <- (+ 1) <$> readTVar clientCorrId
      writeTVar clientCorrId i
      return . CorrId . B.pack $ show i

    -- TODO this is a stub - to replace with cryptographic signature
    signTransmission :: Signed -> IO Transmission
    signTransmission signed = return (pKey, signed)

    send :: CorrId -> Transmission -> STM (TMVar (Either SMPClientError Cmd))
    send corrId t = do
      r <- newEmptyTMVar
      modifyTVar sentCommands . M.insert corrId $ Request qId r
      writeTBQueue sndQ t
      return r
