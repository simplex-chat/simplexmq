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

    -- * Transport over TLS 1.3
    runTransportServer,
    runTransportClient,
    loadTLSServerParams,

    -- * TLS 1.3 Transport
    TLS (..),
    closeTLS,

    -- * SMP encrypted transport
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

import Control.Applicative (optional, (<|>))
import Control.Monad.Except
import Control.Monad.IO.Unlift
import Control.Monad.Trans.Except (throwE)
import Data.Attoparsec.ByteString.Char8 (Parser)
import qualified Data.Attoparsec.ByteString.Char8 as A
import Data.Bifunctor (first)
import Data.ByteString.Base64
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import qualified Data.ByteString.Lazy as BL
import Data.Default (def)
import Data.Functor (($>))
import Data.Maybe (fromMaybe)
import Data.Set (Set)
import qualified Data.Set as S
import Data.String
import GHC.Generics (Generic)
import GHC.IO.Exception (IOErrorType (..))
import GHC.IO.Handle.Internals (ioe_EOF)
import Generic.Random (genericArbitraryU)
import Network.Socket
import qualified Network.TLS as T
import qualified Network.TLS.Extra as TE
import Simplex.Messaging.Parsers (base64P, parseAll, parseRead1, parseString)
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

  -- | Upgrade client TLS context to connection (used in the server)
  getServerConnection :: T.Context -> IO c

  -- | Upgrade server TLS context to connection (used in the client)
  getClientConnection :: T.Context -> IO c

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

data TProxy c = TProxy

data ATransport = forall c. Transport c => ATransport (TProxy c)

-- * Transport over TLS 1.3

-- | Run transport server (plain TCP or WebSockets) on passed TCP port and signal when server started and stopped via passed TMVar.
--
-- All accepted connections are passed to the passed function.
runTransportServer :: (Transport c, MonadUnliftIO m) => TMVar Bool -> ServiceName -> T.ServerParams -> (c -> m ()) -> m ()
runTransportServer started port serverParams server = do
  clients <- newTVarIO S.empty
  E.bracket
    (liftIO $ startTCPServer started port)
    (liftIO . closeServer clients)
    $ \sock -> forever $ do
      c <- liftIO $ acceptConnection sock
      tid <- forkFinally (server c) (const $ liftIO $ closeConnection c)
      atomically . modifyTVar clients $ S.insert tid
  where
    closeServer :: TVar (Set ThreadId) -> Socket -> IO ()
    closeServer clients sock = do
      readTVarIO clients >>= mapM_ killThread
      close sock
      void . atomically $ tryPutTMVar started False
    acceptConnection :: Transport c => Socket -> IO c
    acceptConnection sock = do
      (newSock, _) <- accept sock
      ctx <- connectTLS "server" serverParams newSock
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
runTransportClient :: Transport c => MonadUnliftIO m => HostName -> ServiceName -> (c -> m a) -> m a
runTransportClient host port client = do
  c <- liftIO $ startTCPClient host port
  client c `E.finally` liftIO (closeConnection c)

startTCPClient :: forall c. Transport c => HostName -> ServiceName -> IO c
startTCPClient host port = withSocketsDo $ resolve >>= tryOpen err
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
      ctx <- connectTLS "client" clientParams sock
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

-- * TLS 1.3 Transport

data TLS = TLS {tlsContext :: T.Context, buffer :: TVar ByteString, getLock :: TMVar ()}

connectTLS :: T.TLSParams p => String -> p -> Socket -> IO T.Context
connectTLS party params sock =
  E.bracketOnError (T.contextNew sock params) closeTLS $ \ctx -> do
    T.handshake ctx
      `E.catch` \(e :: E.SomeException) -> putStrLn (party <> " exception: " <> show e) >> E.throwIO e
    pure ctx

newTLS :: T.Context -> IO TLS
newTLS tlsContext = do
  buffer <- newTVarIO ""
  getLock <- newTMVarIO ()
  pure TLS {tlsContext, buffer, getLock}

closeTLS :: T.Context -> IO ()
closeTLS ctx =
  (T.bye ctx >> T.contextClose ctx) -- sometimes socket was closed before 'TLS.bye'
    `E.catch` (\(_ :: E.SomeException) -> pure ()) -- so we catch the 'Broken pipe' error here

clientParams :: T.ClientParams
clientParams =
  (T.defaultParamsClient "localhost" "5223")
    { T.clientShared = def,
      T.clientHooks = def {T.onServerCertificate = \_ _ _ _ -> pure []},
      T.clientSupported = supportedParameters
    }

supportedParameters :: T.Supported
supportedParameters =
  def
    { T.supportedVersions = [T.TLS13],
      T.supportedCiphers = [TE.cipher_TLS13_CHACHA20POLY1305_SHA256],
      T.supportedHashSignatures = [(T.HashIntrinsic, T.SignatureEd448), (T.HashIntrinsic, T.SignatureEd25519)],
      T.supportedSecureRenegotiation = False,
      T.supportedGroups = [T.X448, T.X25519]
    }

instance Transport TLS where
  transportName _ = "TLS 1.3"
  getServerConnection = newTLS
  getClientConnection = newTLS
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

-- * SMP encrypted transport

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
  { sessionIdentifier :: ByteString,
    smpVersion :: SMPVersion
  }

serializeHandshake :: Handshake -> ByteString
serializeHandshake Handshake {sessionIdentifier, smpVersion} =
  encode sessionIdentifier <> " " <> serializeSMPVersion smpVersion <> " "

handshakeP :: Parser Handshake
handshakeP = Handshake <$> base64OrEmptyP <* A.space <*> smpVersionP <* A.space

base64OrEmptyP :: Parser ByteString
base64OrEmptyP = fromMaybe "" <$> optional base64P

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
  | -- | lower counterparty version
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
serverHandshake :: forall c. Transport c => c -> Int -> ExceptT TransportError IO (THandle c)
serverHandshake c blockSize = do
  th <- liftIO $ transportHandle c blockSize
  clientHello <- getClientHello th
  -- liftIO $ putStrLn "server - after getClientHello"
  checkHandshake clientHello
  sendServerHello th
  pure th
  where
    sendServerHello :: THandle c -> ExceptT TransportError IO ()
    sendServerHello th = do
      let handshake = Handshake {sessionIdentifier = "abc", smpVersion = currentSMPVersion}
      ExceptT . tPutBlock th $ serializeHandshake handshake
    getClientHello :: THandle c -> ExceptT TransportError IO Handshake
    getClientHello th = ExceptT $ do
      -- liftIO $ putStrLn "server - before tGetBlock"
      block <- tGetBlock th
      -- liftIO $ putStrLn "server - after tGetBlock"
      -- liftIO $ putStrLn (unpack block)
      case parseHandshake block of
        Left e -> pure $ Left e
        Right handshake -> pure $ Right handshake
    checkHandshake :: Handshake -> ExceptT TransportError IO ()
    checkHandshake Handshake {smpVersion} =
      when (smpVersion < currentSMPVersion) . throwE $
        TEHandshake VERSION

-- | Client SMP transport handshake.
--
-- See https://github.com/simplex-chat/simplexmq/blob/master/protocol/simplex-messaging.md#appendix-a
clientHandshake :: forall c. Transport c => c -> Int -> ExceptT TransportError IO (THandle c)
clientHandshake c blockSize = do
  th <- liftIO $ transportHandle c blockSize
  -- liftIO $ putStrLn "client - before sendClientHello"
  sendClientHello th
  -- liftIO $ putStrLn "client - after sendClientHello"
  serverHello <- getServerHello th
  -- liftIO $ putStrLn "client - after getServerHello"
  checkHandshake serverHello
  pure th
  where
    sendClientHello :: THandle c -> ExceptT TransportError IO ()
    sendClientHello th = do
      let handshake = Handshake {sessionIdentifier = "", smpVersion = currentSMPVersion}
      -- serHandshake = serializeHandshake handshake
      -- liftIO $ putStrLn ("\"" <> unpack serHandshake <> "\"")
      -- ExceptT . tPutBlock th $ serHandshake
      ExceptT . tPutBlock th $ serializeHandshake handshake
    getServerHello :: THandle c -> ExceptT TransportError IO Handshake
    getServerHello th = ExceptT $ do
      block <- tGetBlock th
      case parseHandshake block of
        Left e -> pure $ Left e
        Right handshake -> pure $ Right handshake
    checkHandshake :: Handshake -> ExceptT TransportError IO ()
    checkHandshake Handshake {smpVersion} =
      when (smpVersion < currentSMPVersion) . throwE $
        TEHandshake VERSION

parseHandshake :: ByteString -> Either TransportError Handshake
parseHandshake = first (const $ TEHandshake PARSE) . A.parseOnly handshakeP

transportHandle :: c -> Int -> IO (THandle c)
transportHandle c blockSize = do
  pure
    THandle
      { connection = c,
        sessionId = "",
        blockSize
      }
