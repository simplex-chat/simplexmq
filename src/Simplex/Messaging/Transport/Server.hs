{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Simplex.Messaging.Transport.Server
  ( TransportServerConfig (..),
    defaultTransportServerConfig,
    runTransportServer,
    runTransportServerSocket,
    runTCPServer,
    runTCPServerSocket,
    startTCPServer,
    loadSupportedTLSServerParams,
    loadTLSServerParams,
    loadFingerprint,
    smpServerHandshake,
  )
where

import Control.Applicative ((<|>))
import Control.Logger.Simple
import Control.Monad
import Control.Monad.IO.Unlift
import qualified Crypto.Store.X509 as SX
import Data.Default (def)
import Data.List (find)
import Data.Maybe (fromJust)
import qualified Data.X509 as X
import Data.X509.Validation (Fingerprint (..))
import qualified Data.X509.Validation as XV
import Network.Socket
import qualified Network.TLS as T
import Simplex.Messaging.TMap (TMap)
import qualified Simplex.Messaging.TMap as TM
import Simplex.Messaging.Transport
import Simplex.Messaging.Util (catchAll_, labelMyThread, tshow)
import System.Exit (exitFailure)
import System.Mem.Weak (Weak, deRefWeak)
import UnliftIO.Concurrent
import qualified UnliftIO.Exception as E
import UnliftIO.STM

data TransportServerConfig = TransportServerConfig
  { logTLSErrors :: Bool,
    transportTimeout :: Int
  }
  deriving (Eq, Show)

defaultTransportServerConfig :: TransportServerConfig
defaultTransportServerConfig =
  TransportServerConfig
    { logTLSErrors = True,
      transportTimeout = 40000000
    }

serverTransportConfig :: TransportServerConfig -> TransportConfig
serverTransportConfig TransportServerConfig {logTLSErrors} =
  -- TransportConfig {logTLSErrors, transportTimeout = Just transportTimeout}
  TransportConfig {logTLSErrors, transportTimeout = Nothing}

-- | Run transport server (plain TCP or WebSockets) on passed TCP port and signal when server started and stopped via passed TMVar.
--
-- All accepted connections are passed to the passed function.
runTransportServer :: forall c m. (Transport c, MonadUnliftIO m) => TMVar Bool -> ServiceName -> T.ServerParams -> TransportServerConfig -> (c -> m ()) -> m ()
runTransportServer started port = runTransportServerSocket started (startTCPServer started port) (transportName (TProxy :: TProxy c))

-- | Run a transport server with provided connection setup and handler.
runTransportServerSocket :: (MonadUnliftIO m, T.TLSParams p, Transport a) => TMVar Bool -> IO Socket -> String -> p -> TransportServerConfig -> (a -> m ()) -> m ()
runTransportServerSocket started getSocket threadLabel serverParams cfg server = do
  u <- askUnliftIO
  let tCfg = serverTransportConfig cfg
  labelMyThread $ "transport server for " <> threadLabel
  liftIO . runTCPServerSocket started getSocket $ \conn ->
    E.bracket
      (connectTLS Nothing tCfg serverParams conn >>= getServerConnection tCfg)
      closeConnection
      (unliftIO u . server)

-- | Run TCP server without TLS
runTCPServer :: TMVar Bool -> ServiceName -> (Socket -> IO ()) -> IO ()
runTCPServer started port = runTCPServerSocket started $ startTCPServer started port

-- | Wrap socket provider in a TCP server bracket.
runTCPServerSocket :: TMVar Bool -> IO Socket -> (Socket -> IO ()) -> IO ()
runTCPServerSocket started getSocket server = do
  clients <- atomically TM.empty
  clientId <- newTVarIO 0
  E.bracket
    getSocket
    (closeServer started clients)
    $ \sock -> forever . E.bracketOnError (accept sock) (close . fst) $ \(conn, _peer) -> do
      -- catchAll_ is needed here in case the connection was closed earlier
      cId <- atomically $ stateTVar clientId $ \cId -> let cId' = cId + 1 in (cId', cId')
      let closeConn _ = atomically (TM.delete cId clients) >> gracefulClose conn 5000 `catchAll_` pure ()
      tId <- mkWeakThreadId =<< server conn `forkFinally` closeConn
      atomically $ TM.insert cId tId clients

closeServer :: TMVar Bool -> TMap Int (Weak ThreadId) -> Socket -> IO ()
closeServer started clients sock = do
  readTVarIO clients >>= mapM_ (deRefWeak >=> mapM_ killThread)
  close sock
  void . atomically $ tryPutTMVar started False

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
    setStarted sock = atomically (tryPutTMVar started True) >> pure sock

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
