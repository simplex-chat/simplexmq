{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}

module Simplex.RemoteControl.Discovery where

import Control.Applicative ((<|>))
import Control.Logger.Simple
import Control.Monad
import Data.ByteString (ByteString)
import Data.Default (def)
import Data.List (delete, find)
import Data.Maybe (mapMaybe)
import Data.String (IsString)
import qualified Data.Text as T
import Data.Word (Word16)
import Network.Info (IPv4 (..), NetworkInterface (..), getNetworkInterfaces)
import qualified Network.Socket as N
import qualified Network.TLS as TLS
import qualified Network.UDP as UDP
import Simplex.Messaging.Transport (supportedParameters)
import qualified Simplex.Messaging.Transport as Transport
import Simplex.Messaging.Transport.Client (TransportHost (..))
import Simplex.Messaging.Transport.Server (defaultTransportServerConfig, runTransportServerSocket, startTCPServer)
import Simplex.Messaging.Util (ifM, tshow)
import Simplex.RemoteControl.Discovery.Multicast (setMembership)
import Simplex.RemoteControl.Types
import UnliftIO

-- | mDNS multicast group
pattern MULTICAST_ADDR_V4 :: (IsString a, Eq a) => a
pattern MULTICAST_ADDR_V4 = "224.0.0.251"

pattern ANY_ADDR_V4 :: (IsString a, Eq a) => a
pattern ANY_ADDR_V4 = "0.0.0.0"

pattern DISCOVERY_PORT :: (IsString a, Eq a) => a
pattern DISCOVERY_PORT = "5227"

getLocalAddress :: Maybe RCCtrlAddress -> IO [RCCtrlAddress]
getLocalAddress preferred_ =
  maybe id preferAddress preferred_ . mkLastLocalHost . mapMaybe toCtrlAddr <$> getNetworkInterfaces
  where
    toCtrlAddr NetworkInterface {name, ipv4 = IPv4 ha} = case N.hostAddressToTuple ha of
      (0, 0, 0, 0) -> Nothing -- "no" address
      (255, 255, 255, 255) -> Nothing -- broadcast
      (169, 254, _, _) -> Nothing -- link-local
      ok -> Just RCCtrlAddress {address = THIPv4 ok, interface = T.pack name}

mkLastLocalHost :: [RCCtrlAddress] -> [RCCtrlAddress]
mkLastLocalHost addrs = case find localHost addrs of
  Nothing -> addrs
  Just lh -> delete lh addrs <> [lh]
  where
    localHost RCCtrlAddress {address = a} = a == THIPv4 (127, 0, 0, 1)

preferAddress :: RCCtrlAddress -> [RCCtrlAddress] -> [RCCtrlAddress]
preferAddress RCCtrlAddress {address, interface} addrs =
  case find matchAddr addrs <|> find matchIface addrs of
    Nothing -> addrs
    Just p -> p : delete p addrs
  where
    matchAddr RCCtrlAddress {address = a} = a == address
    matchIface RCCtrlAddress {interface = i} = i == interface

startTLSServer :: MonadUnliftIO m => Maybe Word16 -> TMVar (Maybe N.PortNumber) -> TLS.Credentials -> TLS.ServerHooks -> (Transport.TLS -> IO ()) -> m (Async ())
startTLSServer port_ startedOnPort credentials hooks server = async . liftIO $ do
  started <- newEmptyTMVarIO
  bracketOnError (startTCPServer started $ maybe "0" show port_) (\_e -> setPort Nothing) $ \socket ->
    ifM
      (atomically $ readTMVar started)
      (runServer started socket)
      (setPort Nothing)
  where
    runServer started socket = do
      port <- N.socketPort socket
      logInfo $ "System-assigned port: " <> tshow port
      setPort $ Just port
      runTransportServerSocket started (pure socket) "RCP TLS" serverParams defaultTransportServerConfig server
    setPort = void . atomically . tryPutTMVar startedOnPort
    serverParams =
      def
        { TLS.serverWantClientCert = True,
          TLS.serverShared = def {TLS.sharedCredentials = credentials},
          TLS.serverHooks = hooks,
          TLS.serverSupported = supportedParameters
        }

withSender :: MonadUnliftIO m => (UDP.UDPSocket -> m a) -> m a
withSender = bracket (liftIO $ UDP.clientSocket MULTICAST_ADDR_V4 DISCOVERY_PORT False) (liftIO . UDP.close)

withListener :: MonadUnliftIO m => TMVar Int -> (UDP.ListenSocket -> m a) -> m a
withListener subscribers = bracket (openListener subscribers) (closeListener subscribers)

openListener :: MonadIO m => TMVar Int -> m UDP.ListenSocket
openListener subscribers = liftIO $ do
  sock <- UDP.serverSocket (MULTICAST_ADDR_V4, read DISCOVERY_PORT)
  logDebug $ "Discovery listener socket: " <> tshow sock
  let raw = UDP.listenSocket sock
  -- N.setSocketOption raw N.Broadcast 1
  joinMulticast subscribers raw (listenerHostAddr4 sock)
  pure sock

closeListener :: MonadIO m => TMVar Int -> UDP.ListenSocket -> m ()
closeListener subscribers sock =
  liftIO $
    partMulticast subscribers (UDP.listenSocket sock) (listenerHostAddr4 sock) `finally` UDP.stop sock

joinMulticast :: TMVar Int -> N.Socket -> N.HostAddress -> IO ()
joinMulticast subscribers sock group = do
  now <- atomically $ takeTMVar subscribers
  when (now == 0) $ do
    setMembership sock group True >>= \case
      Left e -> atomically (putTMVar subscribers now) >> logError ("setMembership failed " <> tshow e)
      Right () -> atomically $ putTMVar subscribers (now + 1)

partMulticast :: TMVar Int -> N.Socket -> N.HostAddress -> IO ()
partMulticast subscribers sock group = do
  now <- atomically $ takeTMVar subscribers
  when (now == 1) $
    setMembership sock group False >>= \case
      Left e -> atomically (putTMVar subscribers now) >> logError ("setMembership failed " <> tshow e)
      Right () -> atomically $ putTMVar subscribers (now - 1)

listenerHostAddr4 :: UDP.ListenSocket -> N.HostAddress
listenerHostAddr4 sock = case UDP.mySockAddr sock of
  N.SockAddrInet _port host -> host
  _ -> error "MULTICAST_ADDR_V4 is V4"

recvAnnounce :: MonadIO m => UDP.ListenSocket -> m (N.SockAddr, ByteString)
recvAnnounce sock = liftIO $ do
  (invite, UDP.ClientSockAddr source _cmsg) <- UDP.recvFrom sock
  pure (source, invite)
