{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

module Simplex.FileTransfer.Client.Agent where

import Control.Logger.Simple (logInfo)
import Control.Monad
import Control.Monad.Except
import Data.Bifunctor (first)
import qualified Data.ByteString.Char8 as B
import Data.Text (Text)
import Data.Text.Encoding (decodeUtf8)
import Simplex.FileTransfer.Client
import Simplex.Messaging.Agent.RetryInterval
import Simplex.Messaging.Client (NetworkConfig (..), ProtocolClientError (..), temporaryClientError)
import Simplex.Messaging.Client.Agent ()
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Protocol (ProtocolServer (..), XFTPServer)
import Simplex.Messaging.TMap (TMap)
import qualified Simplex.Messaging.TMap as TM
import Simplex.Messaging.Util (catchAll_)
import UnliftIO

type XFTPClientVar = TMVar (Either XFTPClientAgentError XFTPClient)

data XFTPClientAgent = XFTPClientAgent
  { xftpClients :: TMap XFTPServer XFTPClientVar,
    config :: XFTPClientAgentConfig
  }

data XFTPClientAgentConfig = XFTPClientAgentConfig
  { xftpConfig :: XFTPClientConfig,
    reconnectInterval :: RetryInterval
  }

defaultXFTPClientAgentConfig :: XFTPClientAgentConfig
defaultXFTPClientAgentConfig =
  XFTPClientAgentConfig
    { xftpConfig = defaultXFTPClientConfig,
      reconnectInterval =
        RetryInterval
          { initialInterval = 5_000000,
            increaseAfter = 10_000000,
            maxInterval = 60_000000
          }
    }

data XFTPClientAgentError = XFTPClientAgentError XFTPServer XFTPClientError
  deriving (Show, Exception)

newXFTPAgent :: XFTPClientAgentConfig -> STM XFTPClientAgent
newXFTPAgent config = do
  xftpClients <- TM.empty
  pure XFTPClientAgent {xftpClients, config}

type ME a = ExceptT XFTPClientAgentError IO a

getXFTPServerClient :: XFTPClientAgent -> XFTPServer -> ME XFTPClient
getXFTPServerClient XFTPClientAgent {xftpClients, config} srv = do
  atomically getClientVar >>= either newXFTPClient waitForXFTPClient
  where
    connectClient :: ME XFTPClient
    connectClient =
      ExceptT $
        first (XFTPClientAgentError srv)
          <$> getXFTPClient (1, srv, Nothing) (xftpConfig config) clientDisconnected

    clientDisconnected :: XFTPClient -> IO ()
    clientDisconnected _ = do
      atomically $ TM.delete srv xftpClients
      logInfo $ "disconnected from " <> showServer srv

    getClientVar :: STM (Either XFTPClientVar XFTPClientVar)
    getClientVar = maybe (Left <$> newClientVar) (pure . Right) =<< TM.lookup srv xftpClients
      where
        newClientVar :: STM XFTPClientVar
        newClientVar = do
          var <- newEmptyTMVar
          TM.insert srv var xftpClients
          pure var

    waitForXFTPClient :: XFTPClientVar -> ME XFTPClient
    waitForXFTPClient clientVar = do
      let XFTPClientConfig {xftpNetworkConfig = NetworkConfig {tcpConnectTimeout}} = xftpConfig config
      client_ <- tcpConnectTimeout `timeout` atomically (readTMVar clientVar)
      liftEither $ case client_ of
        Just (Right c) -> Right c
        Just (Left e) -> Left e
        Nothing -> Left $ XFTPClientAgentError srv PCEResponseTimeout

    newXFTPClient :: XFTPClientVar -> ME XFTPClient
    newXFTPClient clientVar = tryConnectClient tryConnectAsync
      where
        tryConnectClient :: ME () -> ME XFTPClient
        tryConnectClient retryAction =
          tryError connectClient >>= \r -> case r of
            Right client -> do
              logInfo $ "connected to " <> showServer srv
              atomically $ putTMVar clientVar r
              pure client
            Left e@(XFTPClientAgentError _ e') -> do
              if temporaryClientError e'
                then retryAction
                else atomically $ do
                  putTMVar clientVar r
                  TM.delete srv xftpClients
              throwError e
        tryConnectAsync :: ME ()
        tryConnectAsync = void . async $ do
          withRetryInterval (reconnectInterval config) $ \_ loop -> void $ tryConnectClient loop

showServer :: XFTPServer -> Text
showServer ProtocolServer {host, port} =
  decodeUtf8 $ strEncode host <> B.pack (if null port then "" else ':' : port)

closeXFTPServerClient :: XFTPClientAgent -> XFTPServer -> IO ()
closeXFTPServerClient XFTPClientAgent {xftpClients, config} srv =
  atomically (TM.lookupDelete srv xftpClients) >>= mapM_ closeClient
  where
    closeClient cVar = do
      let NetworkConfig {tcpConnectTimeout} = xftpNetworkConfig $ xftpConfig config
      tcpConnectTimeout `timeout` atomically (readTMVar cVar) >>= \case
        Just (Right client) -> closeXFTPClient client `catchAll_` pure ()
        _ -> pure ()
