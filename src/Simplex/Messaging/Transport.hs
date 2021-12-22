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
  ( -- * Transport connection class
    Transport (..),
    TProxy (..),
    ATransport (..),
    TransportPeer (..),

    -- * Transport over TLS 1.2
    PartyAlias (..),
    runTransportServer,
    runTransportClient,
    loadTLSServerParams,
    getCertificateHash,

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
    currentSMPVersionStr,

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
import qualified Data.Attoparsec.ByteString.Char8 as A
import Data.Bifunctor (first)
import Data.ByteString.Base64
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import qualified Data.ByteString.Lazy as BL
import Data.Default (def)
import Data.Functor (($>))
import Data.Set (Set)
import qualified Data.Set as S
import Data.String
import qualified Data.X509 as X
import qualified Data.X509.CertificateStore as XS
import qualified Data.X509.Validation as XV
import GHC.Generics (Generic)
import GHC.IO.Exception (IOErrorType (..))
import GHC.IO.Handle.Internals (ioe_EOF)
import Generic.Random (genericArbitraryU)
import Network.Socket
import qualified Network.TLS as T
import qualified Network.TLS.Extra as TE
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Parsers (parseAll, parseRead1, parseString)
import Simplex.Messaging.Util (bshow)
import System.Exit (exitFailure)
import System.IO.Error
import Test.QuickCheck (Arbitrary (..))
import UnliftIO.Concurrent
import UnliftIO.Exception (Exception, IOException)
import qualified UnliftIO.Exception as E
import UnliftIO.STM

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

-- | Party name to print on exception handling - for debugging.
newtype PartyAlias = PartyAlias {partyAlias :: String} deriving (Show)

-- | Run transport server (plain TCP or WebSockets) on passed TCP port and signal when server started and stopped via passed TMVar.
--
-- All accepted connections are passed to the passed function.
runTransportServer :: forall c m. (Transport c, MonadUnliftIO m) => PartyAlias -> TMVar Bool -> ServiceName -> T.ServerParams -> (c -> m ()) -> m ()
runTransportServer PartyAlias {partyAlias} started port serverParams server = do
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
      ctx <- connectTLS partyAlias serverParams newSock
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
runTransportClient :: Transport c => MonadUnliftIO m => PartyAlias -> HostName -> ServiceName -> C.CertificateHash -> (c -> m a) -> m a
runTransportClient partyAlias host port certificateHash client = do
  let clientParams = mkTLSClientParams host port certificateHash
  c <- liftIO $ startTCPClient partyAlias host port clientParams
  client c `E.finally` liftIO (closeConnection c)

startTCPClient :: forall c. Transport c => PartyAlias -> HostName -> ServiceName -> T.ClientParams -> IO c
startTCPClient PartyAlias {partyAlias} host port clientParams = withSocketsDo $ resolve >>= tryOpen err
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
      ctx <- connectTLS partyAlias clientParams sock
      getClientConnection ctx

loadTLSServerParams :: FilePath -> FilePath -> IO T.ServerParams
loadTLSServerParams certificateFile privateKeyFile =
  fromCredential <$> loadServerCredential
  where
    loadServerCredential :: IO T.Credential
    loadServerCredential =
      T.credentialLoadX509 certificateFile privateKeyFile >>= \case
        Right credential -> pure credential
        Left _ -> putStrLn "invalid credential" >> exitFailure
    fromCredential :: T.Credential -> T.ServerParams
    fromCredential credential =
      def
        { T.serverWantClientCert = False,
          T.serverShared = def {T.sharedCredentials = T.Credentials [credential]},
          T.serverHooks = def,
          T.serverSupported = supportedParameters
        }

mkTLSClientParams :: HostName -> ServiceName -> C.CertificateHash -> T.ClientParams
mkTLSClientParams host port certificateHash = do
  let p = B.pack port
  (T.defaultParamsClient host p)
    { T.clientShared = def,
      T.clientHooks = def {T.onServerCertificate = \_ _ _ -> validateCertificateChain certificateHash host p},
      T.clientSupported = supportedParameters
    }

validateCertificateChain :: C.CertificateHash -> HostName -> ByteString -> X.CertificateChain -> IO [XV.FailedReason]
validateCertificateChain _ _ _ (X.CertificateChain []) = pure [XV.EmptyChain]
validateCertificateChain expectedHash host port cc@(X.CertificateChain sc@[cert]) = do
  let certificateHash = C.certificateHash . X.getCertificate $ cert
      fr = checkHash certificateHash
  -- putStrLn $ "certificate hash: " <> (B.unpack . encode . C.unCertificateHash) certificateHash
  -- putStrLn $ "expected hash: " <> (B.unpack . encode . C.unCertificateHash) expectedHash
  if null fr
    then x509validate
    else pure fr
  where
    checkHash :: C.CertificateHash -> [XV.FailedReason]
    checkHash hash
      | hash == expectedHash = []
      | otherwise = [XV.UnknownCA]
    x509validate :: IO [XV.FailedReason]
    x509validate = XV.validate X.HashSHA256 hooks checks certStore cache serviceID cc
      where
        hooks :: XV.ValidationHooks
        hooks = XV.defaultHooks
        checks :: XV.ValidationChecks
        checks = XV.defaultChecks {XV.checkLeafV3 = False} -- TODO create v3 certificates? https://stackoverflow.com/a/18242720
        certStore = XS.makeCertificateStore sc
        cache :: XV.ValidationCache
        cache = XV.exceptionValidationCache [] -- we don't store certificate Fingerprints on clients
        serviceID :: XV.ServiceID
        serviceID = (host, port)
validateCertificateChain _ _ _ (X.CertificateChain (_ : _ : _)) = pure [XV.AuthorityTooDeep]

supportedParameters :: T.Supported
supportedParameters =
  def
    { T.supportedVersions = [T.TLS12],
      T.supportedCiphers = [TE.cipher_ECDHE_ECDSA_CHACHA20POLY1305_SHA256],
      T.supportedHashSignatures = [(T.HashIntrinsic, T.SignatureEd448), (T.HashIntrinsic, T.SignatureEd25519)],
      T.supportedSecureRenegotiation = False,
      T.supportedGroups = [T.X448, T.X25519]
    }

getCertificateHash :: FilePath -> IO ByteString
getCertificateHash certificateFile = do
  x509 <- SX.readSignedObject certificateFile
  let certificate = X.getCertificate (head x509) -- we should have only one certificate
  pure $ (encode . C.unCertificateHash) (C.certificateHash certificate)

-- * TLS 1.2 Transport

data TLS = TLS
  { tlsContext :: T.Context,
    tlsPeer :: TransportPeer,
    tlsUniq :: ByteString,
    buffer :: TVar ByteString,
    getLock :: TMVar ()
  }

connectTLS :: T.TLSParams p => String -> p -> Socket -> IO T.Context
connectTLS party params sock =
  E.bracketOnError (T.contextNew sock params) closeTLS $ \ctx -> do
    T.handshake ctx
      `E.catch` \(e :: E.SomeException) -> putStrLn (party <> " exception: " <> show e) >> E.throwIO e
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

data SMPVersion = SMPVersion Int Int Int
  deriving (Eq, Ord)

instance IsString SMPVersion where
  fromString = parseString $ parseAll smpVersionP

currentSMPVersion :: SMPVersion
currentSMPVersion = "0.5.1"

currentSMPVersionStr :: ByteString
currentSMPVersionStr = serializeSMPVersion currentSMPVersion

serializeSMPVersion :: SMPVersion -> ByteString
serializeSMPVersion (SMPVersion a b c) = B.intercalate "." [bshow a, bshow b, bshow c]

smpVersionP :: Parser SMPVersion
smpVersionP =
  let ver = A.decimal <* A.char '.'
   in SMPVersion <$> ver <*> ver <*> A.decimal

-- | The handle for SMP encrypted transport connection over Transport .
data THandle c = THandle
  { connection :: c,
    sessionId :: ByteString,
    blockSize :: Int
  }

data Handshake = Handshake
  { sessionId :: ByteString,
    smpVersion :: SMPVersion
  }

serializeHandshake :: Handshake -> ByteString
serializeHandshake Handshake {sessionId, smpVersion} =
  sessionId <> " " <> serializeSMPVersion smpVersion <> " "

handshakeP :: Parser Handshake
handshakeP = Handshake <$> A.takeWhile (/= ' ') <* A.space <*> smpVersionP <* A.space

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
tPutBlock THandle {connection = c, blockSize} block
  | len > blockSize = pure $ Left TELargeMsg
  | otherwise = Right <$> cPut c (block <> B.replicate (blockSize - len) '#')
  where
    len = B.length block

-- | Receive block from SMP transport.
tGetBlock :: Transport c => THandle c -> IO ByteString
tGetBlock THandle {connection = c, blockSize} =
  cGet c blockSize >>= \case
    "" -> ioe_EOF
    msg -> pure msg

-- | Server SMP transport handshake.
--
-- See https://github.com/simplex-chat/simplexmq/blob/master/protocol/simplex-messaging.md#appendix-a
serverHandshake :: Transport c => c -> Int -> ExceptT TransportError IO (THandle c)
serverHandshake c blockSize = do
  let th@THandle {sessionId} = tHandle c blockSize
  _ <- getPeerHello th
  sendHelloToPeer th sessionId
  pure th

-- | Client SMP transport handshake.
--
-- See https://github.com/simplex-chat/simplexmq/blob/master/protocol/simplex-messaging.md#appendix-a
clientHandshake :: forall c. Transport c => c -> Int -> ExceptT TransportError IO (THandle c)
clientHandshake c blockSize = do
  let th@THandle {sessionId} = tHandle c blockSize
  sendHelloToPeer th ""
  Handshake {sessionId = sessId} <- getPeerHello th
  if sessionId == sessId
    then pure th
    else throwE TEBadSession

sendHelloToPeer :: Transport c => THandle c -> ByteString -> ExceptT TransportError IO ()
sendHelloToPeer th sessionId =
  let handshake = Handshake {sessionId, smpVersion = currentSMPVersion}
   in ExceptT . tPutBlock th $ serializeHandshake handshake

getPeerHello :: Transport c => THandle c -> ExceptT TransportError IO Handshake
getPeerHello th = ExceptT $ parseHandshake <$> tGetBlock th
  where
    parseHandshake :: ByteString -> Either TransportError Handshake
    parseHandshake = first (const $ TEHandshake PARSE) . A.parseOnly handshakeP

tHandle :: Transport c => c -> Int -> THandle c
tHandle c blockSize =
  THandle {connection = c, sessionId = encode $ tlsUnique c, blockSize}
