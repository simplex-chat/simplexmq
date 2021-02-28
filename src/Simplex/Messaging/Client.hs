{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Simplex.Messaging.Client
  ( SMPClient,
    getSMPClient,
    closeSMPClient,
    createSMPQueue,
    subscribeSMPQueue,
    secureSMPQueue,
    sendSMPMessage,
    ackSMPMessage,
    sendSMPCommand,
    suspendSMPQueue,
    deleteSMPQueue,
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
import qualified Crypto.PubKey.RSA.Types as RSA
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import Data.Maybe
import GHC.IO.Exception (IOErrorType (..))
import Network.Socket (ServiceName)
import Numeric.Natural
import Simplex.Messaging.Agent.Transmission (SMPServer (..))
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Protocol
import Simplex.Messaging.Transport
import Simplex.Messaging.Types
import Simplex.Messaging.Util (liftEitherError, raceAny_)
import System.IO
import System.IO.Error
import System.Timeout

data SMPClient = SMPClient
  { action :: Async (),
    connected :: TVar Bool,
    smpServer :: SMPServer,
    clientCorrId :: TVar Natural,
    sentCommands :: TVar (Map CorrId Request),
    sndQ :: TBQueue SignedRawTransmission,
    rcvQ :: TBQueue SignedTransmissionOrError,
    msgQ :: TBQueue SMPServerTransmission
  }

type SMPServerTransmission = (SMPServer, RecipientId, Command 'Broker)

data SMPClientConfig = SMPClientConfig
  { qSize :: Natural,
    defaultPort :: ServiceName,
    tcpTimeout :: Int,
    smpPing :: Int,
    blockSize :: Int,
    smpCommandSize :: Int
  }

smpDefaultConfig :: SMPClientConfig
smpDefaultConfig =
  SMPClientConfig
    { qSize = 16,
      defaultPort = "5223",
      tcpTimeout = 2_000_000,
      smpPing = 30_000_000,
      blockSize = 8_192, -- 16_384,
      smpCommandSize = 256
    }

data Request = Request
  { queueId :: QueueId,
    responseVar :: TMVar (Either SMPClientError Cmd)
  }

getSMPClient :: SMPServer -> SMPClientConfig -> TBQueue SMPServerTransmission -> IO () -> IO SMPClient
getSMPClient
  smpServer@SMPServer {host, port}
  SMPClientConfig {qSize, defaultPort, tcpTimeout, smpPing}
  msgQ
  disconnected = do
    c <- atomically mkSMPClient
    started <- newEmptyTMVarIO
    action <-
      async $
        runTCPClient host (fromMaybe defaultPort port) (client c started)
          `finally` atomically (putTMVar started False)
    tcpTimeout `timeout` atomically (takeTMVar started) >>= \case
      Just True -> return c {action}
      _ -> throwIO err
    where
      err :: IOException
      err = mkIOError TimeExpired "connection timeout" Nothing Nothing

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
              connected,
              smpServer,
              clientCorrId,
              sentCommands,
              sndQ,
              rcvQ,
              msgQ
            }

      client :: SMPClient -> TMVar Bool -> Handle -> IO ()
      client c started h = do
        _ <- getLn h -- "Welcome to SMP"
        atomically $ do
          modifyTVar (connected c) (const True)
          putTMVar started True
        raceAny_ [send c h, process c, receive c h, ping c]
          `finally` disconnected

      send :: SMPClient -> Handle -> IO ()
      send SMPClient {sndQ} h = forever $ atomically (readTBQueue sndQ) >>= tPut h

      receive :: SMPClient -> Handle -> IO ()
      receive SMPClient {rcvQ} h = forever $ tGet fromServer h >>= atomically . writeTBQueue rcvQ

      ping :: SMPClient -> IO ()
      ping c = forever $ do
        threadDelay smpPing
        runExceptT $ sendSMPCommand c Nothing "" (Cmd SSender PING)

      process :: SMPClient -> IO ()
      process SMPClient {rcvQ, sentCommands} = forever $ do
        (_, (corrId, qId, respOrErr)) <- atomically $ readTBQueue rcvQ
        cs <- readTVarIO sentCommands
        case M.lookup corrId cs of
          Nothing -> do
            case respOrErr of
              Right (Cmd SBroker cmd) -> atomically $ writeTBQueue msgQ (smpServer, qId, cmd)
              -- TODO send everything else to errQ and log in agent
              _ -> return ()
          Just Request {queueId, responseVar} -> atomically $ do
            modifyTVar sentCommands $ M.delete corrId
            putTMVar responseVar $
              if queueId == qId
                then case respOrErr of
                  Left e -> Left $ SMPResponseError e
                  Right (Cmd _ (ERR e)) -> Left $ SMPServerError e
                  Right r -> Right r
                else Left SMPQueueIdError

closeSMPClient :: SMPClient -> IO ()
closeSMPClient = uninterruptibleCancel . action

data SMPClientError
  = SMPServerError ErrorType
  | SMPResponseError ErrorType
  | SMPQueueIdError
  | SMPUnexpectedResponse
  | SMPResponseTimeout
  | SMPCryptoError RSA.Error
  | SMPClientError
  deriving (Eq, Show, Exception)

createSMPQueue ::
  SMPClient ->
  RecipientPrivateKey ->
  RecipientPublicKey ->
  ExceptT SMPClientError IO (RecipientId, SenderId)
createSMPQueue c rpKey rKey =
  -- TODO add signing this request too - requires changes in the server
  sendSMPCommand c (Just rpKey) "" (Cmd SRecipient $ NEW rKey) >>= \case
    Cmd _ (IDS rId sId) -> return (rId, sId)
    _ -> throwE SMPUnexpectedResponse

subscribeSMPQueue :: SMPClient -> RecipientPrivateKey -> RecipientId -> ExceptT SMPClientError IO ()
subscribeSMPQueue c@SMPClient {smpServer, msgQ} rpKey rId =
  sendSMPCommand c (Just rpKey) rId (Cmd SRecipient SUB) >>= \case
    Cmd _ OK -> return ()
    Cmd _ cmd@MSG {} ->
      lift . atomically $ writeTBQueue msgQ (smpServer, rId, cmd)
    _ -> throwE SMPUnexpectedResponse

secureSMPQueue :: SMPClient -> RecipientPrivateKey -> RecipientId -> SenderPublicKey -> ExceptT SMPClientError IO ()
secureSMPQueue c rpKey rId senderKey = okSMPCommand (Cmd SRecipient $ KEY senderKey) c rpKey rId

sendSMPMessage :: SMPClient -> Maybe SenderPrivateKey -> SenderId -> MsgBody -> ExceptT SMPClientError IO ()
sendSMPMessage c spKey sId msg =
  sendSMPCommand c spKey sId (Cmd SSender $ SEND msg) >>= \case
    Cmd _ OK -> return ()
    _ -> throwE SMPUnexpectedResponse

ackSMPMessage :: SMPClient -> RecipientPrivateKey -> QueueId -> ExceptT SMPClientError IO ()
ackSMPMessage c@SMPClient {smpServer, msgQ} rpKey rId =
  sendSMPCommand c (Just rpKey) rId (Cmd SRecipient ACK) >>= \case
    Cmd _ OK -> return ()
    Cmd _ cmd@MSG {} ->
      lift . atomically $ writeTBQueue msgQ (smpServer, rId, cmd)
    _ -> throwE SMPUnexpectedResponse

suspendSMPQueue :: SMPClient -> RecipientPrivateKey -> QueueId -> ExceptT SMPClientError IO ()
suspendSMPQueue = okSMPCommand $ Cmd SRecipient OFF

deleteSMPQueue :: SMPClient -> RecipientPrivateKey -> QueueId -> ExceptT SMPClientError IO ()
deleteSMPQueue = okSMPCommand $ Cmd SRecipient DEL

okSMPCommand :: Cmd -> SMPClient -> C.PrivateKey -> QueueId -> ExceptT SMPClientError IO ()
okSMPCommand cmd c pKey qId =
  sendSMPCommand c (Just pKey) qId cmd >>= \case
    Cmd _ OK -> return ()
    _ -> throwE SMPUnexpectedResponse

sendSMPCommand :: SMPClient -> Maybe C.PrivateKey -> QueueId -> Cmd -> ExceptT SMPClientError IO Cmd
sendSMPCommand SMPClient {sndQ, sentCommands, clientCorrId} pKey qId cmd = do
  corrId <- lift_ getNextCorrId
  t <- signTransmission $ serializeTransmission (corrId, qId, cmd)
  ExceptT $ sendRecv corrId t
  where
    lift_ :: STM a -> ExceptT SMPClientError IO a
    lift_ action = ExceptT $ Right <$> atomically action

    getNextCorrId :: STM CorrId
    getNextCorrId = do
      i <- (+ 1) <$> readTVar clientCorrId
      writeTVar clientCorrId i
      return . CorrId . B.pack $ show i

    signTransmission :: ByteString -> ExceptT SMPClientError IO SignedRawTransmission
    signTransmission t = case pKey of
      Nothing -> return ("", t)
      Just pk -> do
        sig <- liftEitherError SMPCryptoError $ C.sign pk t
        return (sig, t)

    -- two separate "atomically" needed to avoid blocking
    sendRecv :: CorrId -> SignedRawTransmission -> IO (Either SMPClientError Cmd)
    sendRecv corrId t = atomically (send corrId t) >>= atomically . takeTMVar

    send :: CorrId -> SignedRawTransmission -> STM (TMVar (Either SMPClientError Cmd))
    send corrId t = do
      r <- newEmptyTMVar
      modifyTVar sentCommands . M.insert corrId $ Request qId r
      writeTBQueue sndQ t
      return r
