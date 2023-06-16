{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Simplex.Messaging.Transport.Server
  ( runTransportServer,
    runTCPServer,
    TransportServerConfig (..),
    defaultTransportServerConfig,
    loadSupportedTLSServerParams,
    loadTLSServerParams,
    loadFingerprint,
    smpServerHandshake,
  )
where

import Control.Applicative ((<|>))
import Control.Concurrent.STM (stateTVar)
import Control.Logger.Simple
import Control.Monad.Except
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
import Simplex.Messaging.Util (catchAll_, tshow)
import System.Exit (exitFailure)
import System.Mem.Weak (Weak, deRefWeak)
import UnliftIO.Concurrent
import qualified UnliftIO.Exception as E
import UnliftIO.STM

data TransportServerConfig = TransportServerConfig
  { logTLSErrors :: Bool,
    recvTimeout :: Int, -- SO_RCVTIMEO: timeout in microseconds
    sendTimeout :: Int -- SO_SNDTIMEO: timeout in microseconds
  }
  deriving (Eq, Show)

defaultTransportServerConfig :: TransportServerConfig
defaultTransportServerConfig = TransportServerConfig
  { logTLSErrors = True,
    recvTimeout = 40000000, -- 40 seconds
    sendTimeout = 40000000 -- 40 seconds
  }

-- | Run transport server (plain TCP or WebSockets) on passed TCP port and signal when server started and stopped via passed TMVar.
--
-- All accepted connections are passed to the passed function.
runTransportServer :: forall c m. (Transport c, MonadUnliftIO m) => TMVar Bool -> ServiceName -> T.ServerParams -> TransportServerConfig -> (c -> m ()) -> m ()
runTransportServer started port serverParams cfg@TransportServerConfig {logTLSErrors} server = do
  u <- askUnliftIO
  liftIO . runTCPServer started port cfg $ \conn ->
    E.bracket
      (connectTLS Nothing logTLSErrors serverParams conn >>= getServerConnection)
      closeConnection
      (unliftIO u . server)

-- | Run TCP server without TLS
runTCPServer :: TMVar Bool -> ServiceName -> TransportServerConfig -> (Socket -> IO ()) -> IO ()
runTCPServer started port cfg server = do
  clients <- atomically TM.empty
  clientId <- newTVarIO 0
  E.bracket
    (startTCPServer started port cfg)
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

startTCPServer :: TMVar Bool -> ServiceName -> TransportServerConfig -> IO Socket
startTCPServer started port TransportServerConfig {recvTimeout, sendTimeout} = withSocketsDo $ resolve >>= open >>= setStarted
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
      setSocketOption sock RecvTimeOut recvTimeout
      setSocketOption sock SendTimeOut sendTimeout
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
