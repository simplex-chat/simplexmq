{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}

module Simplex.Messaging.Transport where

import Control.Monad.IO.Class
import Control.Monad.IO.Unlift
import Control.Monad.Reader
import Data.ByteString.Base64
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Network.Socket
import Simplex.Messaging.Server.Transmission
import System.IO
import Text.Read
import UnliftIO.Concurrent
import qualified UnliftIO.Exception as E
import qualified UnliftIO.IO as IO

startTCPServer :: MonadIO m => ServiceName -> m Socket
startTCPServer port = liftIO . withSocketsDo $ resolve >>= open
  where
    resolve = do
      let hints = defaultHints {addrFlags = [AI_PASSIVE], addrSocketType = Stream}
      head <$> getAddrInfo (Just hints) Nothing (Just port)
    open addr = do
      sock <- socket (addrFamily addr) (addrSocketType addr) (addrProtocol addr)
      setSocketOption sock ReuseAddr 1
      withFdSocket sock setCloseOnExecIfNeeded
      bind sock $ addrAddress addr
      listen sock 1024
      return sock

runTCPServer :: MonadUnliftIO m => ServiceName -> (Handle -> m ()) -> m ()
runTCPServer port server =
  E.bracket (startTCPServer port) (liftIO . close) $ \sock -> forever $ do
    h <- acceptTCPConn sock
    forkFinally (server h) (const $ IO.hClose h)

acceptTCPConn :: MonadIO m => Socket -> m Handle
acceptTCPConn sock = liftIO $ do
  (conn, _) <- accept sock
  -- putStrLn $ "Accepted connection from " ++ show peer
  getSocketHandle conn

startTCPClient :: MonadIO m => HostName -> ServiceName -> m Handle
startTCPClient host port = liftIO . withSocketsDo $ resolve >>= open
  where
    resolve = do
      let hints = defaultHints {addrSocketType = Stream}
      head <$> getAddrInfo (Just hints) (Just host) (Just port)
    open addr = do
      sock <- socket (addrFamily addr) (addrSocketType addr) (addrProtocol addr)
      connect sock $ addrAddress addr
      getSocketHandle sock

runTCPClient :: MonadUnliftIO m => HostName -> ServiceName -> (Handle -> m a) -> m a
runTCPClient host port = E.bracket (startTCPClient host port) IO.hClose

getSocketHandle :: MonadIO m => Socket -> m Handle
getSocketHandle conn = liftIO $ do
  h <- socketToHandle conn ReadWriteMode
  hSetBinaryMode h True
  hSetNewlineMode h NewlineMode {inputNL = CRLF, outputNL = CRLF}
  hSetBuffering h LineBuffering
  return h

putLn :: MonadIO m => Handle -> ByteString -> m ()
putLn h = liftIO . hPutStrLn h . B.unpack

getLn :: MonadIO m => Handle -> m ByteString
getLn h = B.pack <$> liftIO (hGetLine h)

getBytes :: MonadIO m => Handle -> Int -> m ByteString
getBytes h = liftIO . B.hGet h

tPutRaw :: MonadIO m => Handle -> RawTransmission -> m ()
tPutRaw h (signature, corrId, queueId, command) = do
  putLn h signature
  putLn h corrId
  putLn h queueId
  putLn h command

tGetRaw :: MonadIO m => Handle -> m RawTransmission
tGetRaw h = do
  signature <- getLn h
  corrId <- getLn h
  queueId <- getLn h
  command <- getLn h
  return (signature, corrId, queueId, command)

tPut :: MonadIO m => Handle -> Transmission -> m ()
tPut h (signature, (corrId, queueId, command)) = tPutRaw h (encode signature, corrId, encode queueId, serializeCommand command)

fromClient :: Cmd -> Either ErrorType Cmd
fromClient = \case
  Cmd SBroker _ -> Left PROHIBITED
  cmd -> Right cmd

fromServer :: Cmd -> Either ErrorType Cmd
fromServer = \case
  cmd@(Cmd SBroker _) -> Right cmd
  _ -> Left PROHIBITED

-- | get client and server transmissions
-- `fromParty` is used to limit allowed senders - `fromClient` or `fromServer` should be used
tGet :: forall m. MonadIO m => (Cmd -> Either ErrorType Cmd) -> Handle -> m TransmissionOrError
tGet fromParty h = do
  (signature, corrId, queueId, command) <- tGetRaw h
  let decodedTransmission = liftM2 (,corrId,,command) (decode signature) (decode queueId)
  either (const $ tError corrId) tParseLoadBody decodedTransmission
  where
    tError :: ByteString -> m TransmissionOrError
    tError corrId = return (B.empty, (corrId, B.empty, Left $ SYNTAX errBadTransmission))

    tParseLoadBody :: RawTransmission -> m TransmissionOrError
    tParseLoadBody t@(signature, corrId, queueId, command) = do
      let cmd = parseCommand command >>= fromParty >>= tCredentials t
      fullCmd <- either (return . Left) cmdWithMsgBody cmd
      return (signature, (corrId, queueId, fullCmd))

    tCredentials :: RawTransmission -> Cmd -> Either ErrorType Cmd
    tCredentials (signature, _, queueId, _) cmd = case cmd of
      -- IDS response should not have queue ID
      Cmd SBroker (IDS _ _) -> Right cmd
      -- ERROR response does not always have queue ID
      Cmd SBroker (ERR _) -> Right cmd
      -- other responses must have queue ID
      Cmd SBroker _
        | B.null queueId -> Left $ SYNTAX errNoConnectionId
        | otherwise -> Right cmd
      -- CREATE must NOT have signature or queue ID
      Cmd SRecipient (NEW _)
        | B.null signature && B.null queueId -> Right cmd
        | otherwise -> Left $ SYNTAX errHasCredentials
      -- SEND must have queue ID, signature is not always required
      Cmd SSender (SEND _)
        | B.null queueId -> Left $ SYNTAX errNoConnectionId
        | otherwise -> Right cmd
      -- other client commands must have both signature and queue ID
      Cmd SRecipient _
        | B.null signature || B.null queueId -> Left $ SYNTAX errNoCredentials
        | otherwise -> Right cmd

    cmdWithMsgBody :: Cmd -> m (Either ErrorType Cmd)
    cmdWithMsgBody = \case
      Cmd SSender (SEND body) ->
        Cmd SSender . SEND <$$> getMsgBody body
      Cmd SBroker (MSG msgId ts body) ->
        Cmd SBroker . MSG msgId ts <$$> getMsgBody body
      cmd -> return $ Right cmd

    getMsgBody :: MsgBody -> m (Either ErrorType MsgBody)
    getMsgBody msgBody =
      case B.unpack msgBody of
        ':' : body -> return . Right $ B.pack body
        str -> case readMaybe str :: Maybe Int of
          Just size -> do
            body <- getBytes h size
            s <- getLn h
            return if B.null s then Right body else Left SIZE
          Nothing -> return . Left $ SYNTAX errMessageBody

infixl 4 <$$>

(<$$>) :: (Functor f, Functor g) => (a -> b) -> f (g a) -> f (g b)
(<$$>) = fmap . fmap
