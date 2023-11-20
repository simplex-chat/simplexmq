{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}

-- XXX: remove non-discovery functions
module Simplex.RemoteControl.Discovery where

import Control.Logger.Simple
import Control.Monad
import Crypto.Random (getRandomBytes)
import Data.ByteString (ByteString)
import Data.Default (def)
import Data.Maybe (listToMaybe, mapMaybe)
import Data.String (IsString)
import Network.Info (IPv4 (..), NetworkInterface (..), getNetworkInterfaces)
import qualified Network.Socket as N
import qualified Network.TLS as TLS
import qualified Network.UDP as UDP
import Simplex.Messaging.Encoding (Encoding (..))
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

getLocalAddress :: MonadIO m => m (Maybe TransportHost)
getLocalAddress = listToMaybe . mapMaybe usable <$> liftIO getNetworkInterfaces
  where
    usable NetworkInterface {ipv4 = IPv4 ha} = case N.hostAddressToTuple ha of
      (0, 0, 0, 0) -> Nothing -- "no" address
      (255, 255, 255, 255) -> Nothing -- broadcast
      (127, _, _, _) -> Nothing -- localhost
      (169, 254, _, _) -> Nothing -- link-local
      ok -> Just $ THIPv4 ok

getLocalAddressMulticast :: MonadIO m => TMVar Int -> m (Maybe TransportHost)
getLocalAddressMulticast subscribers = liftIO $ do
  probe <- mkIpProbe
  let bytes = smpEncode probe
  withListener subscribers $ \receiver ->
    withSender $ \sender -> do
      UDP.send sender bytes
      let expect = do
            UDP.recvFrom receiver >>= \case
              (p, _) | p /= bytes -> expect
              (_, UDP.ClientSockAddr (N.SockAddrInet _port host) _cmsg) -> pure $ THIPv4 (N.hostAddressToTuple host)
              (_, UDP.ClientSockAddr _badAddr _) -> error "receiving from IPv4 socket"
      timeout 1000000 expect

mkIpProbe :: MonadIO m => m IpProbe
mkIpProbe = do
  randomNonce <- liftIO $ getRandomBytes 32
  pure IpProbe {versionRange = ipProbeVersionRange, randomNonce}

-- | Send replay-proof announce datagrams
-- runAnnouncer :: (C.PrivateKeyEd25519, Announce) -> IO ()
-- runAnnouncer (announceKey, initialAnnounce) = withSender $ loop initialAnnounce
--   where
--     loop announce sock = do
--       UDP.send sock $ smpEncode (signAnnounce announceKey announce)
--       threadDelay 1000000
--       loop announce {announceCounter = announceCounter announce + 1} sock

-- XXX: move to RemoteControl.Client
startTLSServer :: MonadUnliftIO m => TMVar (Maybe N.PortNumber) -> TLS.Credentials -> TLS.ServerHooks -> (Transport.TLS -> IO ()) -> m (Async ())
startTLSServer startedOnPort credentials hooks server = async . liftIO $ do
  started <- newEmptyTMVarIO
  bracketOnError (startTCPServer started "0") (\_e -> setPort Nothing) $ \socket ->
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
