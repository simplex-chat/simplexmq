{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Simplex.Messaging.Transport.Server
  ( TransportServerConfig (..),
    ServerCredentials (..),
    defaultTransportServerConfig,
    runTransportServerState,
    SocketState,
    newSocketState,
    runTransportServer,
    runTransportServerSocket,
    runLocalTCPServer,
    runTCPServerSocket,
    startTCPServer,
    loadServerCredential,
    supportedTLSServerParams,
    supportedTLSServerParams_,
    loadFingerprint,
    loadFileFingerprint,
    smpServerHandshake,
  )
where

import Control.Applicative ((<|>))
import Control.Logger.Simple
import Control.Monad
import qualified Crypto.Store.X509 as SX
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
    tlsSetupTimeout :: Int,
    transportTimeout :: Int,
    alpn :: Maybe [ALPN]
  }
  deriving (Eq, Show)

data ServerCredentials = ServerCredentials
  { caCertificateFile :: Maybe FilePath, -- CA certificate private key is not needed for initialization
    privateKeyFile :: FilePath,
    certificateFile :: FilePath
  }
  deriving (Show)

defaultTransportServerConfig :: TransportServerConfig
defaultTransportServerConfig =
  TransportServerConfig
    { logTLSErrors = True,
      tlsSetupTimeout = 60000000,
      transportTimeout = 40000000,
      alpn = Nothing
    }

serverTransportConfig :: TransportServerConfig -> TransportConfig
serverTransportConfig TransportServerConfig {logTLSErrors} =
  -- TransportConfig {logTLSErrors, transportTimeout = Just transportTimeout}
  TransportConfig {logTLSErrors, transportTimeout = Nothing}

-- | Run transport server (plain TCP or WebSockets) on passed TCP port and signal when server started and stopped via passed TMVar.
--
-- All accepted connections are passed to the passed function.
runTransportServer :: forall c. Transport c => TMVar Bool -> ServiceName -> T.Credential -> T.ServerParams -> TransportServerConfig -> (c -> IO ()) -> IO ()
runTransportServer started port creds params cfg server = do
  ss <- newSocketState
  runTransportServerState ss started port creds params cfg server

runTransportServerState :: forall c . Transport c => SocketState -> TMVar Bool -> ServiceName -> T.Credential -> T.ServerParams -> TransportServerConfig -> (c -> IO ()) -> IO ()
runTransportServerState ss started port = runTransportServerSocketState ss started (startTCPServer started Nothing port) (transportName (TProxy :: TProxy c))

-- | Run a transport server with provided connection setup and handler.
runTransportServerSocket :: Transport a => TMVar Bool -> IO Socket -> String -> T.Credential -> T.ServerParams -> TransportServerConfig -> (a -> IO ()) -> IO ()
runTransportServerSocket started getSocket threadLabel serverCreds serverParams cfg server = do
  ss <- newSocketState
  runTransportServerSocketState ss started getSocket threadLabel serverCreds serverParams cfg server

-- | Run a transport server with provided connection setup and handler.
runTransportServerSocketState :: Transport a => SocketState -> TMVar Bool -> IO Socket -> String -> (X.CertificateChain, X.PrivKey) -> T.ServerParams -> TransportServerConfig -> (a -> IO ()) -> IO ()
runTransportServerSocketState ss started getSocket threadLabel serverCreds serverParams cfg server = do
  labelMyThread $ "transport server for " <> threadLabel
  runTCPServerSocket ss started getSocket $ \conn ->
    E.bracket (setup conn >>= maybe (fail "tls setup timeout") pure) closeConnection server
  where
    tCfg = serverTransportConfig cfg
    setup conn = timeout (tlsSetupTimeout cfg) $ do
      labelMyThread $ threadLabel <> "/setup"
      tls <- connectTLS Nothing tCfg serverParams conn
      getServerConnection tCfg (fst serverCreds) tls

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
      cId <- atomically $ stateTVar accepted $ \cId -> let cId' = cId + 1 in cId `seq` (cId', cId')
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
        again = [eAGAIN, eNETDOWN, ePROTO, eNOPROTOOPT, eHOSTDOWN, eNONET, eHOSTUNREACH, eOPNOTSUPP, eNETUNREACH]
        err = "socket accept error: " <> tshow e <> maybe "" ((", errno=" <>) . tshow) errno
        errno = ioe_errno e

type SocketState = (TVar Int, TVar Int, TVar (IntMap (Weak ThreadId)))

newSocketState :: IO SocketState
newSocketState = (,,) <$> newTVarIO 0 <*> newTVarIO 0 <*> newTVarIO mempty

closeServer :: TMVar Bool -> TVar (IntMap (Weak ThreadId)) -> Socket -> IO ()
closeServer started clients sock = do
  readTVarIO clients >>= mapM_ (deRefWeak >=> mapM_ killThread)
  close sock
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
      logInfo $ "binding to " <> tshow (addrAddress addr)
      bind sock $ addrAddress addr
      listen sock 1024
      pure sock
    setStarted sock = atomically (tryPutTMVar started True) >> pure sock

loadServerCredential :: ServerCredentials -> IO T.Credential
loadServerCredential ServerCredentials {caCertificateFile, certificateFile, privateKeyFile} =
  T.credentialLoadX509Chain certificateFile (maybeToList caCertificateFile) privateKeyFile >>= \case
    Right credential -> pure credential
    Left _ -> putStrLn "invalid credential" >> exitFailure

supportedTLSServerParams :: T.Credential -> Maybe [ALPN] -> T.ServerParams
supportedTLSServerParams = supportedTLSServerParams_ defaultSupportedParameters

supportedTLSServerParams_ :: T.Supported -> T.Credential -> Maybe [ALPN] -> T.ServerParams
supportedTLSServerParams_ serverSupported credential alpn_ =
  def
    { T.serverWantClientCert = False,
      T.serverHooks =
        def
          { T.onServerNameIndication = \_ -> pure $ T.Credentials [credential],
            T.onALPNClientSuggest = (\alpn -> pure . fromMaybe "" . find (`elem` alpn)) <$> alpn_
          },
      T.serverSupported = serverSupported
    }

loadFingerprint :: ServerCredentials -> IO Fingerprint
loadFingerprint ServerCredentials {caCertificateFile} = case caCertificateFile of
  Just certificateFile -> loadFileFingerprint certificateFile
  Nothing -> error "CA file must be used in protocol credentials"

loadFileFingerprint :: FilePath -> IO Fingerprint
loadFileFingerprint certificateFile = do
  (cert : _) <- SX.readSignedObject certificateFile
  pure $ XV.getFingerprint (cert :: X.SignedExact X.Certificate) X.HashSHA256
