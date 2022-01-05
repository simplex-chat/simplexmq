{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

-- |
-- Module      : Simplex.Messaging.Transport
-- Copyright   : (c) simplex.chat
-- License     : AGPL-3
--
-- Maintainer  : chat@simplex.chat
-- Stability   : experimental
-- Portability : non-portable
--
-- This module defines basic TCP server and client and SMP protocol encrypted transport over TCP.
--
-- See https://github.com/simplex-chat/simplexmq/blob/master/protocol/simplex-messaging.md#appendix-a
module Simplex.Messaging.Transport
  ( -- * SMP transport parameters
    smpBlockSize,
    supportedSMPVersions,
    simplexMQVersion,

    -- * Transport connection class
    Transport (..),
    TProxy (..),
    ATransport (..),
    TransportPeer (..),

    -- * Transport over TLS 1.2
    runTransportServer,
    runTransportClient,
    loadTLSServerParams,
    loadFingerprint,

    -- * TLS 1.2 Transport
    TLS (..),
    closeTLS,
    withTlsUnique,

    -- * SMP transport
    THandle (..),
    TransportError (..),
    serverHandshake,
    clientHandshake,
    tPutBlock,
    tGetBlock,
    serializeTransportError,
    transportErrorP,

    -- * Trim trailing CR
    trimCR,
  )
where

import Control.Applicative ((<|>))
import Control.Monad.Except
import Control.Monad.IO.Unlift
import Control.Monad.Trans.Except (throwE)
import qualified Crypto.Store.X509 as SX
import Data.Attoparsec.ByteString.Char8 (Parser)
import Data.Bifunctor (first)
import Data.Bitraversable (bimapM)
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import qualified Data.ByteString.Lazy as BL
import Data.Default (def)
import Data.Functor (($>))
import Data.Set (Set)
import qualified Data.Set as S
import Data.Word (Word16)
import qualified Data.X509 as X
import qualified Data.X509.CertificateStore as XS
import Data.X509.Validation (Fingerprint (..))
import qualified Data.X509.Validation as XV
import GHC.Generics (Generic)
import GHC.IO.Exception (IOErrorType (..))
import GHC.IO.Handle.Internals (ioe_EOF)
import Generic.Random (genericArbitraryU)
import Network.Socket
import qualified Network.TLS as T
import qualified Network.TLS.Extra as TE
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Encoding
import Simplex.Messaging.Parsers (parse, parseRead1)
import Simplex.Messaging.Util (bshow)
import Simplex.Messaging.Version
import System.Exit (exitFailure)
import System.IO.Error
import Test.QuickCheck (Arbitrary (..))
import UnliftIO.Concurrent
import UnliftIO.Exception (Exception, IOException)
import qualified UnliftIO.Exception as E
import UnliftIO.STM

-- * Transport parameters

smpBlockSize :: Int
smpBlockSize = 16384

supportedSMPVersions :: VersionRange
supportedSMPVersions = mkVersionRange 1 1

simplexMQVersion :: String
simplexMQVersion = "0.5.1"

-- * Transport connection class

class Transport c where
  transport :: ATransport
  transport = ATransport (TProxy @c)

  transportName :: TProxy c -> String

  transportPeer :: c -> TransportPeer

  -- | Upgrade server TLS context to connection (used in the server)
  getServerConnection :: T.Context -> IO c

  -- | Upgrade client TLS context to connection (used in the client)
  getClientConnection :: T.Context -> IO c

  -- | tls-unique channel binding per RFC5929
  tlsUnique :: c -> ByteString

  -- | Close connection
  closeConnection :: c -> IO ()

  -- | Read fixed number of bytes from connection
  cGet :: c -> Int -> IO ByteString

  -- | Write bytes to connection
  cPut :: c -> ByteString -> IO ()

  -- | Receive ByteString from connection, allowing LF or CRLF termination.
  getLn :: c -> IO ByteString

  -- | Send ByteString to connection terminating it with CRLF.
  putLn :: c -> ByteString -> IO ()
  putLn c = cPut c . (<> "\r\n")

data TransportPeer = TClient | TServer
  deriving (Eq, Show)

data TProxy c = TProxy

data ATransport = forall c. Transport c => ATransport (TProxy c)

-- * Transport over TLS 1.2

-- | Run transport server (plain TCP or WebSockets) on passed TCP port and signal when server started and stopped via passed TMVar.
--
-- All accepted connections are passed to the passed function.
runTransportServer :: forall c m. (Transport c, MonadUnliftIO m) => TMVar Bool -> ServiceName -> T.ServerParams -> (c -> m ()) -> m ()
runTransportServer started port serverParams server = do
  clients <- newTVarIO S.empty
  E.bracket
    (liftIO $ startTCPServer started port)
    (liftIO . closeServer clients)
    $ \sock -> forever $ connectClients sock clients `E.catch` \(_ :: E.SomeException) -> pure ()
  where
    connectClients :: Socket -> TVar (Set ThreadId) -> m ()
    connectClients sock clients = do
      c <- liftIO $ acceptConnection sock
      tid <- server c `forkFinally` const (liftIO $ closeConnection c)
      atomically . modifyTVar clients $ S.insert tid
    closeServer :: TVar (Set ThreadId) -> Socket -> IO ()
    closeServer clients sock = do
      readTVarIO clients >>= mapM_ killThread
      close sock
      void . atomically $ tryPutTMVar started False
    acceptConnection :: Socket -> IO c
    acceptConnection sock = do
      (newSock, _) <- accept sock
      ctx <- connectTLS serverParams newSock
      getServerConnection ctx

startTCPServer :: TMVar Bool -> ServiceName -> IO Socket
startTCPServer started port = withSocketsDo $ resolve >>= open >>= setStarted
  where
    resolve =
      let hints = defaultHints {addrFlags = [AI_PASSIVE], addrSocketType = Stream}
       in head <$> getAddrInfo (Just hints) Nothing (Just port)
    open addr = do
      sock <- socket (addrFamily addr) (addrSocketType addr) (addrProtocol addr)
      setSocketOption sock ReuseAddr 1
      withFdSocket sock setCloseOnExecIfNeeded
      bind sock $ addrAddress addr
      listen sock 1024
      return sock
    setStarted sock = atomically (tryPutTMVar started True) >> pure sock

-- | Connect to passed TCP host:port and pass handle to the client.
runTransportClient :: Transport c => MonadUnliftIO m => HostName -> ServiceName -> C.KeyHash -> (c -> m a) -> m a
runTransportClient host port keyHash client = do
  let clientParams = mkTLSClientParams host port keyHash
  c <- liftIO $ startTCPClient host port clientParams
  client c `E.finally` liftIO (closeConnection c)

startTCPClient :: forall c. Transport c => HostName -> ServiceName -> T.ClientParams -> IO c
startTCPClient host port clientParams = withSocketsDo $ resolve >>= tryOpen err
  where
    err :: IOException
    err = mkIOError NoSuchThing "no address" Nothing Nothing

    resolve :: IO [AddrInfo]
    resolve =
      let hints = defaultHints {addrSocketType = Stream}
       in getAddrInfo (Just hints) (Just host) (Just port)

    tryOpen :: IOException -> [AddrInfo] -> IO c
    tryOpen e [] = E.throwIO e
    tryOpen _ (addr : as) =
      E.try (open addr) >>= either (`tryOpen` as) pure

    open :: AddrInfo -> IO c
    open addr = do
      sock <- socket (addrFamily addr) (addrSocketType addr) (addrProtocol addr)
      connect sock $ addrAddress addr
      ctx <- connectTLS clientParams sock
      getClientConnection ctx

loadTLSServerParams :: FilePath -> FilePath -> FilePath -> IO T.ServerParams
loadTLSServerParams caCertificateFile certificateFile privateKeyFile =
  fromCredential <$> loadServerCredential
  where
    loadServerCredential :: IO T.Credential
    loadServerCredential =
      -- T.credentialLoadX509Chain certificateFile [caCertificateFile] privateKeyFile >>= \case
      T.credentialLoadX509 certificateFile privateKeyFile >>= \case
        Right credential -> pure credential
        Left _ -> putStrLn "invalid credential" >> exitFailure
    fromCredential :: T.Credential -> T.ServerParams
    fromCredential credential =
      def
        { T.serverWantClientCert = False,
          T.serverShared = def {T.sharedCredentials = T.Credentials [credential]},
          T.serverHooks = def,
          T.serverSupported = def
        }
    serverSupported :: T.Supported
    serverSupported =
      def
        { T.supportedVersions = [T.TLS12, T.SSL3],
          T.supportedCiphers =
            [ TE.cipher_ECDHE_ECDSA_CHACHA20POLY1305_SHA256,
              TE.cipher_AES256GCM_SHA384,
              TE.cipher_ECDHE_ECDSA_AES256GCM_SHA384
            ],
          T.supportedHashSignatures =
            [ (T.HashIntrinsic, T.SignatureEd448),
              (T.HashIntrinsic, T.SignatureEd25519),
              (T.HashSHA512, T.SignatureECDSA),
              (T.HashSHA384, T.SignatureECDSA),
              (T.HashSHA256, T.SignatureECDSA)
            ],
          T.supportedSecureRenegotiation = False,
          T.supportedGroups = [T.X448, T.X25519, T.P384]
        }

loadFingerprint :: FilePath -> IO Fingerprint
loadFingerprint certificateFile = do
  (cert : _) <- SX.readSignedObject certificateFile
  pure $ XV.getFingerprint (cert :: X.SignedExact X.Certificate) X.HashSHA256

-- * TLS 1.2 Transport

data TLS = TLS
  { tlsContext :: T.Context,
    tlsPeer :: TransportPeer,
    tlsUniq :: ByteString,
    buffer :: TVar ByteString,
    getLock :: TMVar ()
  }

connectTLS :: T.TLSParams p => p -> Socket -> IO T.Context
connectTLS params sock =
  E.bracketOnError (T.contextNew sock params) closeTLS $ \ctx -> do
    T.handshake ctx
      `E.catch` \(e :: E.SomeException) -> putStrLn ("exception: " <> show e) >> E.throwIO e
    pure ctx

getTLS :: TransportPeer -> T.Context -> IO TLS
getTLS tlsPeer cxt = withTlsUnique tlsPeer cxt newTLS
  where
    newTLS tlsUniq = do
      buffer <- newTVarIO ""
      getLock <- newTMVarIO ()
      pure TLS {tlsContext = cxt, tlsPeer, tlsUniq, buffer, getLock}

withTlsUnique :: TransportPeer -> T.Context -> (ByteString -> IO c) -> IO c
withTlsUnique peer cxt f =
  cxtFinished peer cxt
    >>= maybe (closeTLS cxt >> ioe_EOF) f
  where
    cxtFinished TServer = T.getPeerFinished
    cxtFinished TClient = T.getFinished

closeTLS :: T.Context -> IO ()
closeTLS ctx =
  (T.bye ctx >> T.contextClose ctx) -- sometimes socket was closed before 'TLS.bye'
    `E.catch` (\(_ :: E.SomeException) -> pure ()) -- so we catch the 'Broken pipe' error here

mkTLSClientParams :: HostName -> ServiceName -> C.KeyHash -> T.ClientParams
mkTLSClientParams host port keyHash = do
  let p = B.pack port
  (T.defaultParamsClient host p)
    { T.clientShared = def,
      T.clientHooks = def {T.onServerCertificate = \_ _ _ -> validateCertificateChain keyHash host p},
      T.clientSupported = clientSupported
    }
  where
    clientSupported :: T.Supported
    clientSupported =
      def
        { T.supportedVersions = [T.TLS12],
          T.supportedCiphers = [TE.cipher_ECDHE_ECDSA_CHACHA20POLY1305_SHA256],
          T.supportedHashSignatures = [(T.HashIntrinsic, T.SignatureEd448), (T.HashIntrinsic, T.SignatureEd25519)],
          T.supportedSecureRenegotiation = False,
          T.supportedGroups = [T.X448, T.X25519]
        }

validateCertificateChain :: C.KeyHash -> HostName -> ByteString -> X.CertificateChain -> IO [XV.FailedReason]
validateCertificateChain _ _ _ (X.CertificateChain []) = pure [XV.EmptyChain]
validateCertificateChain _ _ _ (X.CertificateChain [_]) = pure [XV.EmptyChain]
validateCertificateChain (C.KeyHash kh) host port cc@(X.CertificateChain sc@[_, caCert]) =
  if Fingerprint kh == XV.getFingerprint caCert X.HashSHA256
    then x509validate
    else pure [XV.UnknownCA]
  where
    x509validate :: IO [XV.FailedReason]
    x509validate = XV.validate X.HashSHA256 hooks checks certStore cache serviceID cc
      where
        hooks = XV.defaultHooks
        checks = XV.defaultChecks
        certStore = XS.makeCertificateStore sc
        cache = XV.exceptionValidationCache [] -- we manually check fingerprint only of the identity certificate (ca.crt)
        serviceID = (host, port)
validateCertificateChain _ _ _ _ = pure [XV.AuthorityTooDeep]

instance Transport TLS where
  transportName _ = "TLS 1.2"
  transportPeer = tlsPeer
  getServerConnection = getTLS TServer
  getClientConnection = getTLS TClient
  tlsUnique = tlsUniq
  closeConnection tls = closeTLS $ tlsContext tls

  cGet :: TLS -> Int -> IO ByteString
  cGet TLS {tlsContext, buffer, getLock} n =
    E.bracket_
      (atomically $ takeTMVar getLock)
      (atomically $ putTMVar getLock ())
      $ do
        b <- readChunks =<< readTVarIO buffer
        let (s, b') = B.splitAt n b
        atomically $ writeTVar buffer b'
        pure s
    where
      readChunks :: ByteString -> IO ByteString
      readChunks b
        | B.length b >= n = pure b
        | otherwise = readChunks . (b <>) =<< T.recvData tlsContext `E.catch` handleEOF
      handleEOF = \case
        T.Error_EOF -> E.throwIO TEBadBlock
        e -> E.throwIO e

  cPut :: TLS -> ByteString -> IO ()
  cPut tls = T.sendData (tlsContext tls) . BL.fromStrict

  getLn :: TLS -> IO ByteString
  getLn TLS {tlsContext, buffer, getLock} = do
    E.bracket_
      (atomically $ takeTMVar getLock)
      (atomically $ putTMVar getLock ())
      $ do
        b <- readChunks =<< readTVarIO buffer
        let (s, b') = B.break (== '\n') b
        atomically $ writeTVar buffer (B.drop 1 b') -- drop '\n' we made a break at
        pure $ trimCR s
    where
      readChunks :: ByteString -> IO ByteString
      readChunks b
        | B.elem '\n' b = pure b
        | otherwise = readChunks . (b <>) =<< T.recvData tlsContext `E.catch` handleEOF
      handleEOF = \case
        T.Error_EOF -> E.throwIO TEBadBlock
        e -> E.throwIO e

-- | Trim trailing CR from ByteString.
trimCR :: ByteString -> ByteString
trimCR "" = ""
trimCR s = if B.last s == '\r' then B.init s else s

-- * SMP transport

-- | The handle for SMP encrypted transport connection over Transport .
data THandle c = THandle
  { connection :: c,
    sessionId :: ByteString,
    -- | agreed SMP server protocol version
    smpVersion :: Word16
  }

data ServerHandshake = ServerHandshake
  { smpVersionRange :: VersionRange,
    sessionId :: ByteString
  }

data ClientHandshake = ClientHandshake
  { -- | agreed SMP server protocol version
    smpVersion :: Word16,
    -- | server identity - CA certificate fingerprint
    keyHash :: C.KeyHash
  }

instance Encoding ClientHandshake where
  smpEncode ClientHandshake {smpVersion, keyHash} = smpEncode (smpVersion, keyHash)
  smpP = do
    smpVersion <- smpP
    keyHash <- smpP
    pure ClientHandshake {smpVersion, keyHash}

instance Encoding ServerHandshake where
  smpEncode ServerHandshake {smpVersionRange, sessionId} =
    smpEncode (smpVersionRange, sessionId)
  smpP = ServerHandshake <$> smpP <*> smpP

-- | Error of SMP encrypted transport over TCP.
data TransportError
  = -- | error parsing transport block
    TEBadBlock
  | -- | message does not fit in transport block
    TELargeMsg
  | -- | incorrect session ID
    TEBadSession
  | -- | transport handshake error
    TEHandshake HandshakeError
  deriving (Eq, Generic, Read, Show, Exception)

-- | Transport handshake error.
data HandshakeError
  = -- | parsing error
    PARSE
  | -- | incompatible peer version
    VERSION
  | -- | incorrect server identity
    IDENTITY
  deriving (Eq, Generic, Read, Show, Exception)

instance Arbitrary TransportError where arbitrary = genericArbitraryU

instance Arbitrary HandshakeError where arbitrary = genericArbitraryU

-- | SMP encrypted transport error parser.
transportErrorP :: Parser TransportError
transportErrorP =
  "BLOCK" $> TEBadBlock
    <|> "LARGE_MSG" $> TELargeMsg
    <|> "SESSION" $> TEBadSession
    <|> TEHandshake <$> parseRead1

-- | Serialize SMP encrypted transport error.
serializeTransportError :: TransportError -> ByteString
serializeTransportError = \case
  TEBadBlock -> "BLOCK"
  TELargeMsg -> "LARGE_MSG"
  TEBadSession -> "SESSION"
  TEHandshake e -> bshow e

-- | Pad and send block to SMP transport.
tPutBlock :: Transport c => THandle c -> ByteString -> IO (Either TransportError ())
tPutBlock THandle {connection = c} block =
  bimapM (const $ pure TELargeMsg) (cPut c) $
    C.pad block smpBlockSize

-- | Receive block from SMP transport.
tGetBlock :: Transport c => THandle c -> IO (Either TransportError ByteString)
tGetBlock THandle {connection = c} =
  cGet c smpBlockSize >>= \case
    "" -> ioe_EOF
    msg -> pure . first (const TELargeMsg) $ C.unPad msg

-- | Server SMP transport handshake.
--
-- See https://github.com/simplex-chat/simplexmq/blob/master/protocol/simplex-messaging.md#appendix-a
serverHandshake :: forall c. Transport c => c -> C.KeyHash -> ExceptT TransportError IO (THandle c)
serverHandshake c kh = do
  let th@THandle {sessionId} = tHandle c
  sendHandshake th $ ServerHandshake {sessionId, smpVersionRange = supportedSMPVersions}
  getHandshake th >>= \case
    ClientHandshake {smpVersion, keyHash}
      | keyHash /= kh ->
        throwE $ TEHandshake IDENTITY
      | smpVersion `isCompatible` supportedSMPVersions -> do
        pure (th :: THandle c) {smpVersion}
      | otherwise -> throwE $ TEHandshake VERSION

-- | Client SMP transport handshake.
--
-- See https://github.com/simplex-chat/simplexmq/blob/master/protocol/simplex-messaging.md#appendix-a
clientHandshake :: forall c. Transport c => c -> C.KeyHash -> ExceptT TransportError IO (THandle c)
clientHandshake c keyHash = do
  let th@THandle {sessionId} = tHandle c
  ServerHandshake {sessionId = sessId, smpVersionRange} <- getHandshake th
  if sessionId /= sessId
    then throwE TEBadSession
    else case smpVersionRange `compatibleVersion` supportedSMPVersions of
      Just smpVersion -> do
        sendHandshake th $ ClientHandshake {smpVersion, keyHash}
        pure (th :: THandle c) {smpVersion}
      Nothing -> throwE $ TEHandshake VERSION

sendHandshake :: (Transport c, Encoding smp) => THandle c -> smp -> ExceptT TransportError IO ()
sendHandshake th = ExceptT . tPutBlock th . smpEncode

getHandshake :: (Transport c, Encoding smp) => THandle c -> ExceptT TransportError IO smp
getHandshake th = ExceptT $ (parse smpP (TEHandshake PARSE) =<<) <$> tGetBlock th

tHandle :: Transport c => c -> THandle c
tHandle c =
  THandle {connection = c, sessionId = tlsUnique c, smpVersion = 0}
