{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}

module Transport where

import Control.Monad.IO.Class
import Control.Monad.IO.Unlift
import Control.Monad.Reader
import Data.ByteString.Base64
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Network.Socket
import System.IO
import Text.Read
import Transmission
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
  hSetNewlineMode h universalNewlineMode
  hSetBuffering h LineBuffering
  return h

putLn :: MonadIO m => Handle -> ByteString -> m ()
putLn h = liftIO . hPutStrLn h . B.unpack

getLn :: MonadIO m => Handle -> m ByteString
getLn h = B.pack <$> liftIO (hGetLine h)

getBytes :: MonadIO m => Handle -> Int -> m ByteString
getBytes h = liftIO . B.hGet h

tPutRaw :: MonadIO m => Handle -> RawTransmission -> m ()
tPutRaw h (signature, connId, command) = do
  putLn h (encode signature)
  putLn h (encode connId)
  putLn h command

tGetRaw :: MonadIO m => Handle -> m (Either String RawTransmission)
tGetRaw h = do
  signature <- decode <$> getLn h
  connId <- decode <$> getLn h
  command <- getLn h
  return $ liftM2 (,,command) signature connId

tPut :: MonadIO m => Handle -> Transmission -> m ()
tPut h (signature, (connId, command)) = tPutRaw h (signature, connId, serializeCommand command)

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
tGet fromParty h = tGetRaw h >>= either (const tError) tParseLoadBody
  where
    tError :: m TransmissionOrError
    tError = return (B.empty, (B.empty, Left $ SYNTAX errBadTransmission))

    tParseLoadBody :: RawTransmission -> m TransmissionOrError
    tParseLoadBody t@(signature, connId, command) = do
      let cmd = parseCommand command >>= fromParty >>= tCredentials t
      fullCmd <- either (return . Left) cmdWithMsgBody cmd
      return (signature, (connId, fullCmd))

    tCredentials :: RawTransmission -> Cmd -> Either ErrorType Cmd
    tCredentials (signature, connId, _) cmd = case cmd of
      -- IDS response should not have connection ID
      Cmd SBroker (IDS _ _) -> Right cmd
      -- ERROR response does not always have connection ID
      Cmd SBroker (ERR _) -> Right cmd
      -- other responses must have connection ID
      Cmd SBroker _
        | B.null connId -> Left $ SYNTAX errNoConnectionId
        | otherwise -> Right cmd
      -- CREATE must NOT have signature or connection ID
      Cmd SRecipient (CONN _)
        | B.null signature && B.null connId -> Right cmd
        | otherwise -> Left $ SYNTAX errHasCredentials
      -- SEND must have connection ID, signature is not always required
      Cmd SSender (SEND _)
        | B.null connId -> Left $ SYNTAX errNoConnectionId
        | otherwise -> Right cmd
      -- other client commands must have both signature and connection ID
      Cmd SRecipient _
        | B.null signature || B.null connId -> Left $ SYNTAX errNoCredentials
        | otherwise -> Right cmd

    cmdWithMsgBody :: Cmd -> m (Either ErrorType Cmd)
    cmdWithMsgBody = \case
      Cmd SSender (SEND body) ->
        Cmd SSender . SEND <$$> getMsgBody body
      Cmd SBroker (MSG msgId ts body) ->
        Cmd SBroker . MSG msgId ts <$$> getMsgBody body
      cmd -> return $ Right cmd

    infixl 4 <$$>
    (<$$>) :: (Functor f, Functor g) => (a -> b) -> f (g a) -> f (g b)
    (<$$>) = fmap . fmap

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
