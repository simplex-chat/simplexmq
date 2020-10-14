{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Transport where

import Control.Monad.IO.Class
import Control.Monad.Reader
import qualified Data.ByteString.Char8 as B
import Env.STM
import Network.Socket
import System.IO
import Text.Read
import Transmission

startTCPServer :: (MonadReader Env m, MonadIO m) => m Socket
startTCPServer = do
  port <- asks tcpPort
  liftIO . withSocketsDo $ do
    let hints = defaultHints {addrFlags = [AI_PASSIVE], addrSocketType = Stream}
    addr <- head <$> getAddrInfo (Just hints) Nothing (Just port)
    sock <- socket (addrFamily addr) (addrSocketType addr) (addrProtocol addr)
    setSocketOption sock ReuseAddr 1
    withFdSocket sock setCloseOnExecIfNeeded
    bind sock $ addrAddress addr
    listen sock 1024
    return sock

acceptTCPConn :: MonadIO m => Socket -> m Handle
acceptTCPConn sock = liftIO $ do
  (conn, _) <- accept sock
  -- putStrLn $ "Accepted connection from " ++ show peer
  getSocketHandle conn

getSocketHandle :: MonadIO m => Socket -> m Handle
getSocketHandle conn = liftIO $ do
  h <- socketToHandle conn ReadWriteMode
  hSetBinaryMode h True
  hSetNewlineMode h universalNewlineMode
  hSetBuffering h LineBuffering
  return h

putLn :: MonadIO m => Handle -> String -> m ()
putLn h = liftIO . hPutStrLn h

getLn :: MonadIO m => Handle -> m String
getLn = liftIO . hGetLine

getBytes :: MonadIO m => Handle -> Int -> m B.ByteString
getBytes h = liftIO . B.hGet h

tGetRaw :: MonadIO m => Handle -> m RawTransmission
tGetRaw h = do
  signature <- getLn h
  connId <- getLn h
  command <- getLn h
  return (signature, connId, command)

tPutRaw :: MonadIO m => Handle -> RawTransmission -> m ()
tPutRaw h (signature, connId, command) = do
  putLn h signature
  putLn h connId
  putLn h command

fromClient :: Cmd -> Either ErrorType Cmd
fromClient = \case
  Cmd SBroker _ -> Left $ SYNTAX errNotAllowed
  cmd -> Right cmd

fromServer :: Cmd -> Either ErrorType Cmd
fromServer = \case
  cmd@(Cmd SBroker _) -> Right cmd
  _ -> Left $ SYNTAX errNotAllowed

-- | get client and server transmissions
-- `fromParty` is used to limit allowed senders - `fromClient` or `fromServer` should be used
tGet :: forall m. MonadIO m => (Cmd -> Either ErrorType Cmd) -> Handle -> m Transmission'
tGet fromParty h = do
  t@(signature, connId, command) <- tGetRaw h
  let cmd = (parseCommand >=> fromParty) command >>= tCredentials t
  fullCmd <- either (return . Left) cmdWithMsgBody cmd
  return $ mkTransmission signature connId fullCmd
  where
    tCredentials :: RawTransmission -> Cmd -> Either ErrorType Cmd
    tCredentials (signature, connId, _) cmd = case cmd of
      -- ERROR response does not always have connection ID
      Cmd SBroker (ERROR _) -> Right cmd
      -- other responses must have connection ID
      Cmd SBroker _ ->
        if null connId
          then Left $ SYNTAX errNoConnectionId
          else Right cmd
      -- CREATE must NOT have signature or connection ID
      Cmd SRecipient (CREATE _) ->
        if null signature && null connId
          then Right cmd
          else Left $ SYNTAX errHasCredentials
      -- SEND must have connection ID, signature is not always required
      Cmd SSender (SEND _) ->
        if null connId
          then Left $ SYNTAX errNoConnectionId
          else Right cmd
      -- other client commands must have both signature and connectio ID
      _ ->
        if null signature || null connId
          then Left $ SYNTAX errNoCredentials
          else Right cmd

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
            return if null s then Right body else Left $ SYNTAX errMessageBodySize
          Nothing -> return . Left $ SYNTAX errMessageBody
