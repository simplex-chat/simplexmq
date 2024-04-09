{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Simplex.Messaging.Transport.Server
  ( TransportServerConfig (..),
    defaultTransportServerConfig,
    runTransportServerState,
    SocketState,
    newSocketState,
    runTransportServer,
    runTransportServerSocket,
    runTCPServer,
    runTCPServerSocket,
    startTCPServer,
    loadSupportedTLSServerParams,
    loadTLSServerParams,
    loadFingerprint,
    smpServerHandshake,
    tlsServerCredentials
  )
where

import Control.Applicative ((<|>))
import Control.Logger.Simple
import Control.Monad
import qualified Crypto.Store.X509 as SX
import Data.Default (def)
import Data.List (find)
import Data.IntMap.Strict (IntMap)
import qualified Data.IntMap.Strict as IM
import Data.Maybe (fromJust)
import qualified Data.X509 as X
import Data.X509.Validation (Fingerprint (..))
import qualified Data.X509.Validation as XV
import Network.Socket
import qualified Network.TLS as T
import Simplex.Messaging.Transport
import Simplex.Messaging.Util (catchAll_, labelMyThread, tshow, atomically')
import System.Exit (exitFailure)
import System.Mem.Weak (Weak, deRefWeak)
import UnliftIO (timeout)
import UnliftIO.Concurrent
import qualified UnliftIO.Exception as E
import UnliftIO.STM

data TransportServerConfig = TransportServerConfig
  { logTLSErrors :: Bool,
    tlsSetupTimeout :: Int,
    transportTimeout :: Int
  }
  deriving (Eq, Show)

defaultTransportServerConfig :: TransportServerConfig
defaultTransportServerConfig =
  TransportServerConfig
    { logTLSErrors = True,
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
runTransportServer :: forall c. Transport c => TMVar Bool -> ServiceName -> T.ServerParams -> TransportServerConfig -> (c -> IO ()) -> IO ()
runTransportServer started port params cfg server = do
  ss <- atomically newSocketState
  runTransportServerState ss started port params cfg server

runTransportServerState :: forall c . Transport c => SocketState -> TMVar Bool -> ServiceName -> T.ServerParams -> TransportServerConfig -> (c -> IO ()) -> IO ()
runTransportServerState ss started port = runTransportServerSocketState ss started (startTCPServer started port) (transportName (TProxy :: TProxy c))

-- | Run a transport server with provided connection setup and handler.
runTransportServerSocket :: Transport a => TMVar Bool -> IO Socket -> String -> T.ServerParams -> TransportServerConfig -> (a -> IO ()) -> IO ()
runTransportServerSocket started getSocket threadLabel serverParams cfg server = do
  ss <- atomically newSocketState
  runTransportServerSocketState ss started getSocket threadLabel serverParams cfg server

-- | Run a transport server with provided connection setup and handler.
runTransportServerSocketState :: Transport a => SocketState -> TMVar Bool -> IO Socket -> String -> T.ServerParams -> TransportServerConfig -> (a -> IO ()) -> IO ()
runTransportServerSocketState ss started getSocket threadLabel serverParams cfg server = do
  labelMyThread $ "transport server for " <> threadLabel
  runTCPServerSocket ss started getSocket $ \conn ->
    E.bracket (setup conn >>= maybe (fail "tls setup timeout") pure) closeConnection server
  where
    tCfg = serverTransportConfig cfg
    setup conn = timeout (tlsSetupTimeout cfg) $ do
      labelMyThread $ threadLabel <> "/setup"
      tls <- connectTLS Nothing tCfg serverParams conn
      getServerConnection tCfg (fst $ tlsServerCredentials serverParams) tls

tlsServerCredentials :: T.ServerParams -> (X.CertificateChain, X.PrivKey)
tlsServerCredentials serverParams = case T.sharedCredentials $ T.serverShared serverParams of
  T.Credentials [creds] -> creds
  _ -> error "server has more than one key"

-- | Run TCP server without TLS
runTCPServer :: TMVar Bool -> ServiceName -> (Socket -> IO ()) -> IO ()
runTCPServer started port server = do
  ss <- atomically newSocketState
  runTCPServerSocket ss started (startTCPServer started port) server

-- | Wrap socket provider in a TCP server bracket.
runTCPServerSocket :: SocketState -> TMVar Bool -> IO Socket -> (Socket -> IO ()) -> IO ()
runTCPServerSocket (accepted, gracefullyClosed, clients) started getSocket server =
  E.bracket getSocket (closeServer started clients) $ \sock ->
    forever . E.bracketOnError (accept sock) (close . fst) $ \(conn, _peer) -> do
      cId <- atomically $ stateTVar accepted $ \cId -> let cId' = cId + 1 in cId `seq` (cId', cId')
      let closeConn _ = do
            atomically $ modifyTVar' clients $ IM.delete cId
            gracefulClose conn 5000 `catchAll_` pure () -- catchAll_ is needed here in case the connection was closed earlier
            atomically $ modifyTVar' gracefullyClosed (+1)
      tId <- mkWeakThreadId =<< server conn `forkFinally` closeConn
      atomically $ modifyTVar' clients $ IM.insert cId tId

type SocketState = (TVar Int, TVar Int, TVar (IntMap (Weak ThreadId)))

newSocketState :: STM SocketState
newSocketState = (,,) <$> newTVar 0 <*> newTVar 0 <*> newTVar mempty

closeServer :: TMVar Bool -> TVar (IntMap (Weak ThreadId)) -> Socket -> IO ()
closeServer started clients sock = do
  readTVarIO clients >>= mapM_ (deRefWeak >=> mapM_ killThread)
  close sock
  void . atomically' $ tryPutTMVar started False

startTCPServer :: TMVar Bool -> ServiceName -> IO Socket
startTCPServer started port = withSocketsDo $ resolve >>= open >>= setStarted
  where
    resolve =
      let hints = defaultHints {addrFlags = [AI_PASSIVE], addrSocketType = Stream}
       in select <$> getAddrInfo (Just hints) Nothing (Just port)
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
    setStarted sock = atomically' (tryPutTMVar started True) >> pure sock

loadTLSServerParams :: FilePath -> FilePath -> FilePath -> IO T.ServerParams
loadTLSServerParams = loadSupportedTLSServerParams supportedParameters

loadSupportedTLSServerParams :: T.Supported -> FilePath -> FilePath -> FilePath -> IO T.ServerParams
loadSupportedTLSServerParams serverSupported caCertificateFile certificateFile privateKeyFile =
  fromCredential <$> loadServerCredential
  where
    loadServerCredential :: IO T.Credential
    loadServerCredential =
      T.credentialLoadX509Chain certificateFile [caCertificateFile] privateKeyFile >>= \case
        Right credential -> pure credential
        Left _ -> putStrLn "invalid credential" >> exitFailure
    fromCredential :: T.Credential -> T.ServerParams
    fromCredential credential =
      def
        { T.serverWantClientCert = False,
          T.serverShared = def {T.sharedCredentials = T.Credentials [credential]},
          T.serverHooks = def,
          T.serverSupported = serverSupported
        }

loadFingerprint :: FilePath -> IO Fingerprint
loadFingerprint certificateFile = do
  (cert : _) <- SX.readSignedObject certificateFile
  pure $ XV.getFingerprint (cert :: X.SignedExact X.Certificate) X.HashSHA256
