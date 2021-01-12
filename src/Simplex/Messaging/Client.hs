{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Simplex.Messaging.Client
  ( SMPClient,
    getSMPClient,
    createSMPQueue,
    sendSMPMessage,
    sendSMPCommand,
    SMPClientError (..),
  )
where

import Control.Concurrent.Async
import Control.Concurrent.STM
import Control.Exception
import Control.Monad
import qualified Data.ByteString.Char8 as B
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import Data.Maybe
import Numeric.Natural
import Simplex.Messaging.Agent.Transmission (SMPServer (..))
import Simplex.Messaging.Server.Transmission
import Simplex.Messaging.Transport
import Simplex.Messaging.Util
import System.IO

data SMPClient = SMPClient
  { action :: Async (),
    clientCorrId :: TVar Natural,
    sentCommands :: TVar (Map CorrId Request),
    sndQ :: TBQueue Transmission,
    rcvQ :: TBQueue TransmissionOrError
  }

data Request = Request
  { queueId :: QueueId,
    responseVar :: TMVar (Either SMPClientError Cmd)
  }

getSMPClient :: SMPServer -> Natural -> IO SMPClient
getSMPClient SMPServer {host, port} qSize = do
  c <-
    atomically $
      SMPClient undefined <$> newTVar 0 <*> newTVar M.empty <*> newTBQueue qSize <*> newTBQueue qSize
  action <- async $ runTCPClient host (fromMaybe "5223" port) (client c)
  return c {action}
  where
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
    process SMPClient {rcvQ, sentCommands} = atomically $ do
      (_, (corrId, qId, respOrErr)) <- readTBQueue rcvQ
      cs <- readTVar sentCommands
      case M.lookup corrId cs of
        Nothing -> return () -- TODO send to message channel or error channel
        Just Request {queueId, responseVar} -> do
          modifyTVar sentCommands $ M.delete corrId
          putTMVar responseVar $
            if queueId == qId
              then case respOrErr of
                Right resp -> Right resp
                Left e -> Left $ SMPResponseError e
              else Left SMPQueueIdError

-- TODO process responses

data SMPClientError
  = SMPServerError ErrorType
  | SMPResponseError ErrorType
  | SMPQueueIdError
  | SMPUnexpectedResponse
  | SMPResponseTimeout
  | SMPClientError
  deriving (Eq, Show, Exception)

createSMPQueue :: SMPClient -> RecipientKey -> IO (RecipientId, SenderId)
createSMPQueue c rKey = do
  sendSMPCommand c "" "" (Cmd SRecipient $ NEW rKey) >>= \case
    Cmd _ (IDS rId sId) -> return (rId, sId)
    Cmd _ (ERR e) -> throwIO $ SMPServerError e
    _ -> throwIO SMPUnexpectedResponse

sendSMPMessage :: SMPClient -> SenderKey -> QueueId -> MsgBody -> IO ()
sendSMPMessage c sKey qId msg = do
  sendSMPCommand c sKey qId (Cmd SSender $ SEND msg) >>= \case
    Cmd _ OK -> return ()
    Cmd _ (ERR e) -> throwIO $ SMPServerError e
    _ -> throwIO SMPUnexpectedResponse

sendSMPCommand :: SMPClient -> PrivateKey -> QueueId -> Cmd -> IO Cmd
sendSMPCommand c@SMPClient {sentCommands, clientCorrId} pKey qId cmd = do
  corrId <- atomically getNextCorrId
  t <- signTransmission (corrId, qId, cmd)
  atomically (sendReceive corrId t) >>= either throwIO return
  where
    getNextCorrId :: STM CorrId
    getNextCorrId = do
      i <- (+ 1) <$> readTVar clientCorrId
      writeTVar clientCorrId i
      return . CorrId . B.pack $ show i

    -- TODO this is a stub - to replace with cryptographic signature
    signTransmission :: Signed -> IO Transmission
    signTransmission signed = return (pKey, signed)

    sendReceive :: CorrId -> Transmission -> STM (Either SMPClientError Cmd)
    sendReceive corrId t = do
      r <- newEmptyTMVar
      modifyTVar sentCommands . M.insert corrId $ Request qId r
      writeTBQueue (sndQ c) t
      takeTMVar r
