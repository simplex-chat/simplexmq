{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiWayIf #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Simplex.Messaging.Transport.Server
  ( TransportServerConfig (..),
    ServerCredentials (..),
    AddHTTP,
    mkTransportServerConfig,
    runTransportServerState,
    runTransportServerState_,
    SocketState,
    SocketStats (..),
    newSocketState,
    getSocketStats,
    runTransportServer,
    runTransportServerSocket,
    runLocalTCPServer,
    startTCPServer,
    loadServerCredential,
    loadFingerprint,
    loadFileFingerprint,
    smpServerHandshake,
  )
where

import Control.Applicative ((<|>))
import Control.Logger.Simple
import Control.Monad
import qualified Crypto.Store.X509 as SX
import qualified Data.ByteString as B
import Data.Default (def)
import Data.IntMap.Strict (IntMap)
import qualified Data.IntMap.Strict as IM
import Data.List (find)
import Data.Maybe (fromJust, fromMaybe, maybeToList)
import qualified Data.X509 as X
import Data.X509.Validation (Fingerprint (..))
import qualified Data.X509.Validation as XV
import Foreign.C.Error
import GHC.IO.Exception (ioe_errno)
import Network.Socket
import qualified Network.TLS as T
import Simplex.Messaging.Transport
import Simplex.Messaging.Transport.Shared
import Simplex.Messaging.Util (catchAll_, labelMyThread, tshow)
import System.Exit (exitFailure)
import System.IO.Error (tryIOError)
import System.Mem.Weak (Weak, deRefWeak)
import UnliftIO (timeout)
import UnliftIO.Concurrent
import qualified UnliftIO.Exception as E
import UnliftIO.STM

data TransportServerConfig = TransportServerConfig
  { logTLSErrors :: Bool,
    serverALPN :: Maybe [ALPN],
    askClientCert :: Bool,
    tlsSetupTimeout :: Int,
    transportTimeout :: Int
  }
  deriving (Eq, Show)

data ServerCredentials = ServerCredentials
  { caCertificateFile :: Maybe FilePath, -- CA certificate private key is not needed for initialization
    privateKeyFile :: FilePath,
    certificateFile :: FilePath
  }
  deriving (Show)

type AddHTTP = Bool

mkTransportServerConfig :: Bool -> Maybe [ALPN] -> Bool -> TransportServerConfig
mkTransportServerConfig logTLSErrors serverALPN askClientCert =
  TransportServerConfig
    { logTLSErrors,
      serverALPN,
      askClientCert,
      tlsSetupTimeout = 60000000,
      transportTimeout = 40000000
    }

serverTransportConfig :: TransportServerConfig -> TransportConfig
serverTransportConfig TransportServerConfig {logTLSErrors} =
  -- TransportConfig {logTLSErrors, transportTimeout = Just transportTimeout}
  TransportConfig {logTLSErrors, transportTimeout = Nothing}

-- | Run transport server (plain TCP or WebSockets) on passed TCP port and signal when server started and stopped via passed TMVar.
--
-- All accepted connections are passed to the passed function.
runTransportServer :: Transport c => TMVar Bool -> ServiceName -> T.Supported -> T.Credential -> TransportServerConfig -> (c 'TServer -> IO ()) -> IO ()
runTransportServer started port srvSupported srvCreds cfg server = do
  ss <- newSocketState
  runTransportServerState ss started port srvSupported srvCreds cfg server

runTransportServerState :: Transport c => SocketState -> TMVar Bool -> ServiceName -> T.Supported -> T.Credential -> TransportServerConfig -> (c 'TServer -> IO ()) -> IO ()
runTransportServerState ss started port srvSupported srvCreds cfg server = runTransportServerState_ ss started port srvSupported (const srvCreds) cfg (const server)

runTransportServerState_ :: forall c. Transport c => SocketState -> TMVar Bool -> ServiceName -> T.Supported -> (Maybe HostName -> T.Credential) -> TransportServerConfig -> (Socket -> c 'TServer -> IO ()) -> IO ()
runTransportServerState_ ss started port = runTransportServerSocketState ss started (startTCPServer started Nothing port) (transportName (TProxy :: TProxy c 'TServer))

-- | Run a transport server with provided connection setup and handler.
runTransportServerSocket :: Transport c => TMVar Bool -> IO Socket -> String -> T.ServerParams -> TransportServerConfig -> (c 'TServer -> IO ()) -> IO ()
runTransportServerSocket started getSocket threadLabel srvParams cfg server = do
  ss <- newSocketState
  runTransportServerSocketState_ ss started getSocket threadLabel (tlsSetupTimeout cfg) setupTLS (const server)
  where
    tCfg = serverTransportConfig cfg
    setupTLS conn = do
      tls <- connectTLS Nothing tCfg srvParams conn
      getTransportConnection tCfg True (X.CertificateChain []) tls

runTransportServerSocketState :: Transport c => SocketState -> TMVar Bool -> IO Socket -> String -> T.Supported -> (Maybe HostName -> T.Credential) -> TransportServerConfig -> (Socket -> c 'TServer -> IO ()) -> IO ()
runTransportServerSocketState ss started getSocket threadLabel srvSupported srvCreds cfg server =
  runTransportServerSocketState_ ss started getSocket threadLabel (tlsSetupTimeout cfg) setupTLS server
  where
    tCfg = serverTransportConfig cfg
    srvParams = supportedTLSServerParams srvSupported srvCreds $ serverALPN cfg
    setupTLS conn
      | askClientCert cfg = do
          clientCert <- newEmptyTMVarIO
          tls <- connectTLS Nothing tCfg (paramsAskClientCert clientCert srvParams) conn
          chain <- takePeerCertChain clientCert `E.onException` closeTLS tls
          getTransportConnection tCfg True chain tls
      | otherwise = do
          tls <- connectTLS Nothing tCfg srvParams conn
          getTransportConnection tCfg True (X.CertificateChain []) tls

-- | Run a transport server with provided connection setup and handler.
runTransportServerSocketState_ :: Transport c => SocketState -> TMVar Bool -> IO Socket -> String -> Int -> (Socket -> IO (c 'TServer)) -> (Socket -> c 'TServer -> IO ()) -> IO ()
runTransportServerSocketState_ ss started getSocket threadLabel tlsSetupTimeout setupTLS server = do
  labelMyThread $ "transport server for " <> threadLabel
  runTCPServerSocket ss started getSocket $ \conn -> do
    labelMyThread $ threadLabel <> "/setup"
    E.bracket
      (timeout tlsSetupTimeout (setupTLS conn) >>= maybe (fail "tls setup timeout") pure)
      closeConnection
      (server conn)

-- | Run TCP server without TLS
runLocalTCPServer :: TMVar Bool -> ServiceName -> (Socket -> IO ()) -> IO ()
runLocalTCPServer started port server = do
  ss <- newSocketState
  runTCPServerSocket ss started (startTCPServer started (Just "127.0.0.1") port) server

-- | Wrap socket provider in a TCP server bracket.
runTCPServerSocket :: SocketState -> TMVar Bool -> IO Socket -> (Socket -> IO ()) -> IO ()
runTCPServerSocket (accepted, gracefullyClosed, clients) started getSocket server =
  E.bracket getSocket (closeServer started clients) $ \sock ->
    forever . E.bracketOnError (safeAccept sock) (close . fst) $ \(conn, _peer) -> do
      cId <- atomically $ stateTVar accepted $ \cId -> let cId' = cId + 1 in cId' `seq` (cId', cId')
      let closeConn _ = do
            atomically $ modifyTVar' clients $ IM.delete cId
            gracefulClose conn 5000 `catchAll_` pure () -- catchAll_ is needed here in case the connection was closed earlier
            atomically $ modifyTVar' gracefullyClosed (+ 1)
      tId <- mkWeakThreadId =<< server conn `forkFinally` closeConn
      atomically $ modifyTVar' clients $ IM.insert cId tId

-- | Recover from errors in `accept` whenever it is safe.
-- Some errors are safe to ignore, while blindly restaring `accept` may trigger a busy loop.
--
-- man accept says:
-- @
-- For  reliable  operation the application should detect the network errors defined for the protocol after accept() and treat them like EAGAIN by retrying.
-- In  the  case  of  TCP/IP, these are ENETDOWN, EPROTO, ENOPROTOOPT, EHOSTDOWN, ENONET, EHOSTUNREACH, EOPNOTSUPP, and ENETUNREACH.
-- @
safeAccept :: Socket -> IO (Socket, SockAddr)
safeAccept sock =
  tryIOError (accept sock) >>= \case
    Right r -> pure r
    Left e
      | retryAccept -> logWarn err >> safeAccept sock
      | otherwise -> logError err >> E.throwIO e
      where
        retryAccept = maybe False ((`elem` again) . Errno) errno
        again = [eCONNABORTED, eAGAIN, eNETDOWN, ePROTO, eNOPROTOOPT, eHOSTDOWN, eNONET, eHOSTUNREACH, eOPNOTSUPP, eNETUNREACH]
        err = "socket accept error: " <> tshow e <> maybe "" ((", errno=" <>) . tshow) errno
        errno = ioe_errno e

type SocketState = (TVar Int, TVar Int, TVar (IntMap (Weak ThreadId)))

data SocketStats = SocketStats
  { socketsAccepted :: Int,
    socketsClosed :: Int,
    socketsActive :: Int,
    socketsLeaked :: Int
  }

newSocketState :: IO SocketState
newSocketState = (,,) <$> newTVarIO 0 <*> newTVarIO 0 <*> newTVarIO mempty

getSocketStats :: SocketState -> IO SocketStats
getSocketStats (accepted, closed, active) = do
  socketsAccepted <- readTVarIO accepted
  socketsClosed <- readTVarIO closed
  socketsActive <- IM.size <$> readTVarIO active
  let socketsLeaked = socketsAccepted - socketsClosed - socketsActive
  pure SocketStats {socketsAccepted, socketsClosed, socketsActive, socketsLeaked}

closeServer :: TMVar Bool -> TVar (IntMap (Weak ThreadId)) -> Socket -> IO ()
closeServer started clients sock = do
  close sock
  readTVarIO clients >>= mapM_ (deRefWeak >=> mapM_ killThread)
  void . atomically $ tryPutTMVar started False

startTCPServer :: TMVar Bool -> Maybe HostName -> ServiceName -> IO Socket
startTCPServer started host port = withSocketsDo $ resolve >>= open >>= setStarted
  where
    resolve =
      let hints = defaultHints {addrFlags = [AI_PASSIVE], addrSocketType = Stream}
       in select <$> getAddrInfo (Just hints) host (Just port)
    select as = fromJust $ family AF_INET6 <|> family AF_INET
      where
        family f = find ((== f) . addrFamily) as
    open addr = do
      sock <- socket (addrFamily addr) (addrSocketType addr) (addrProtocol addr)
      setSocketOption sock ReuseAddr 1
      withFdSocket sock setCloseOnExecIfNeeded
      logNote $ "binding to " <> tshow (addrAddress addr)
      bind sock $ addrAddress addr
      listen sock 1024
      pure sock
    setStarted sock = atomically (tryPutTMVar started True) >> pure sock

loadServerCredential :: ServerCredentials -> IO T.Credential
loadServerCredential ServerCredentials {caCertificateFile, certificateFile, privateKeyFile} =
  T.credentialLoadX509Chain certificateFile (maybeToList caCertificateFile) privateKeyFile >>= \case
    Right credential -> pure credential
    Left _ -> putStrLn "invalid credential" >> exitFailure

supportedTLSServerParams :: T.Supported -> (Maybe HostName -> T.Credential) -> Maybe [ALPN] -> T.ServerParams
supportedTLSServerParams serverSupported creds alpn_ =
  def
    { T.serverWantClientCert = False,
      T.serverHooks =
        def
          { T.onServerNameIndication = \host_ -> pure $ T.Credentials [creds host_],
            T.onALPNClientSuggest = (\alpn -> pure . fromMaybe "" . find (`elem` alpn)) <$> alpn_
          },
      T.serverSupported = serverSupported
    }

paramsAskClientCert :: TMVar (Maybe X.CertificateChain) -> T.ServerParams -> T.ServerParams
paramsAskClientCert clientCert params =
  params
    { T.serverWantClientCert = True,
      T.serverHooks =
        (T.serverHooks params)
          { T.onClientCertificate = \cc -> validateClientCertificate cc >>= \case
              Just reason -> T.CertificateUsageReject reason <$ atomically (writeTMVar clientCert Nothing)
              Nothing -> T.CertificateUsageAccept <$ atomically (writeTMVar clientCert $ Just cc)
          }
    }

validateClientCertificate :: X.CertificateChain -> IO (Maybe T.CertificateRejectReason)
validateClientCertificate cc = case chainIdCaCerts cc of
  CCEmpty -> pure Nothing -- client certificates are only used for services
  CCSelf cert -> validate cert
  CCValid {caCert} -> validate caCert
  CCLong -> pure $ Just $ T.CertificateRejectOther "chain too long"
  where
    validate caCert = usage <$> x509validate caCert ("", B.empty) cc
    usage [] = Nothing
    usage r =
      Just $
        if
          | XV.Expired `elem` r || XV.InFuture `elem` r -> T.CertificateRejectExpired
          | XV.UnknownCA `elem` r -> T.CertificateRejectUnknownCA
          | otherwise -> T.CertificateRejectOther (show r)

loadFingerprint :: ServerCredentials -> IO Fingerprint
loadFingerprint ServerCredentials {caCertificateFile} = case caCertificateFile of
  Just certificateFile -> loadFileFingerprint certificateFile
  Nothing -> error "CA file must be used in protocol credentials"

loadFileFingerprint :: FilePath -> IO Fingerprint
loadFileFingerprint certificateFile = do
  (cert : _) <- SX.readSignedObject certificateFile
  pure $ XV.getFingerprint (cert :: X.SignedExact X.Certificate) X.HashSHA256
