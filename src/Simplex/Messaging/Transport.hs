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

    -- * Transport via TLS 1.3 over TCP
    TLS (..),
    closeTLS,
    runTransportServer,
    runTransportClient,

    -- * SMP encrypted transport
    THandle (..),
    TransportError (..),
    serverHandshake,
    clientHandshake,
    tPutEncrypted,
    tGetEncrypted,
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
import Crypto.Cipher.Types (AuthTag)
import Data.Attoparsec.ByteString.Char8 (Parser)
import qualified Data.Attoparsec.ByteString.Char8 as A
import Data.Bifunctor (first)
import Data.ByteArray (xor)
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import qualified Data.ByteString.Lazy as BL
import Data.Default (def)
import Data.Either (fromRight)
import Data.Functor (($>))
import Data.Maybe (fromMaybe)
import Data.Set (Set)
import qualified Data.Set as S
import Data.String
import Data.Word (Word32)
import GHC.Generics (Generic)
import GHC.IO.Exception (IOErrorType (..))
import GHC.IO.Handle.Internals (ioe_EOF)
import Generic.Random (genericArbitraryU)
import Network.Socket
import qualified Network.TLS as T
import qualified Network.TLS.Extra as TE
import Network.Transport.Internal (decodeNum16, decodeNum32, encodeEnum16, encodeEnum32, encodeWord32)
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Parsers (parse, parseAll, parseRead1, parseString)
import Simplex.Messaging.Util (bshow, liftError)
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
  getServerConnection :: TLS -> IO c

  -- | Upgrade server TLS context to connection (used in the client)
  getClientConnection :: TLS -> IO c

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

-- * Transport via TLS 1.3 over TCP

data TLS = TLS {tlsContext :: T.Context, buffer :: TVar ByteString, getLock :: TMVar ()}

connectTLS :: (T.TLSParams p) => String -> (TLS -> IO c) -> p -> Socket -> IO c
connectTLS party getPartyConnection params sock =
  E.bracketOnError (T.contextNew sock params) closeTLS $ \tlsContext -> do
    T.handshake tlsContext
    buffer <- newTVarIO ""
    getLock <- newTMVarIO ()
    getPartyConnection TLS {tlsContext, buffer, getLock}
      `E.catch` \(e :: E.SomeException) -> putStrLn (party <> " exception: " <> show e) >> E.throwIO e

closeTLS :: T.Context -> IO ()
closeTLS ctx =
  (T.bye ctx >> T.contextClose ctx) -- sometimes socket was closed before 'TLS.bye'
    `E.catch` (\(_ :: E.SomeException) -> pure ()) -- so we catch the 'Broken pipe' error here

serverParams :: T.ServerParams
serverParams =
  def
    { T.serverWantClientCert = False,
      T.serverShared = def {T.sharedCredentials = T.Credentials [serverCredential]},
      T.serverHooks = def,
      T.serverSupported = supportedParameters
    }

clientParams :: T.ClientParams
clientParams =
  (T.defaultParamsClient "localhost" "5223")
    { T.clientShared = def,
      T.clientHooks = def {T.onServerCertificate = \_ _ _ _ -> pure []},
      T.clientSupported = supportedParameters
    }

serverCredential :: T.Credential
serverCredential =
  fromRight (error "invalid credential") $
    T.credentialLoadX509FromMemory serverCert serverPrivateKey

-- To generate self-signed certificate:
-- https://blog.pinterjann.is/ed25519-certificates.html

serverCert :: ByteString
serverCert =
  "-----BEGIN CERTIFICATE-----\n\
  \MIIBSTCBygIUG8XHI4lGld/8Tb824iWF390hsOwwBQYDK2VxMCExCzAJBgNVBAYT\n\
  \AkRFMRIwEAYDVQQDDAlsb2NhbGhvc3QwIBcNMjExMTIwMTAwMTU5WhgPOTk5OTEy\n\
  \MzExMDAxNTlaMCExCzAJBgNVBAYTAkRFMRIwEAYDVQQDDAlsb2NhbGhvc3QwQzAF\n\
  \BgMrZXEDOgDVgTUc+4Ur9or2N0IKjNgBx649yzAoM5cJKE90OklUKYKdnk4V7kap\n\
  \oHX/d/OUgCdCYa6geMj69QAwBQYDK2VxA3MAlv8lp6xm+KgsGpE+5QLuNT0xdf/i\n\
  \jjJfqLzXzuBwE0+5HwxnrOZ1xMPs30aubiChbpJaJx2xPXkAmnR5Z4p7HcmnPm1P\n\
  \B1SKVlxfqTGWTsJI8E6rNjSsoTZR48DuDZuQthr4SWdcz+jkdFmprTrWHgMA\n\
  \-----END CERTIFICATE-----"

serverPrivateKey :: ByteString
serverPrivateKey =
  "-----BEGIN PRIVATE KEY-----\n\
  \MEcCAQAwBQYDK2VxBDsEOWbzhmByxZ0z656MQV0Vtbkv0VfMpwpvdal8W4Vu9gXu\n\
  \uT7CCDxjBTQQZ8yPnuUNY75jwlyEwbkM1g==\n\
  \-----END PRIVATE KEY-----"

supportedParameters :: T.Supported
supportedParameters =
  def
    { T.supportedVersions = [T.TLS13],
      T.supportedCiphers = [TE.cipher_TLS13_CHACHA20POLY1305_SHA256],
      T.supportedHashSignatures = [(T.HashIntrinsic, T.SignatureEd448)],
      T.supportedSecureRenegotiation = False,
      T.supportedGroups = [T.X448]
    }

-- | Run transport server (plain TCP or WebSockets) on passed TCP port and signal when server started and stopped via passed TMVar.
--
-- All accepted connections are passed to the passed function.
runTransportServer :: (Transport c, MonadUnliftIO m) => TMVar Bool -> ServiceName -> (c -> m ()) -> m ()
runTransportServer started port server = do
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
      connectTLS "server" getServerConnection serverParams newSock

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
      connectTLS "client" getClientConnection clientParams sock

instance Transport TLS where
  transportName _ = "Plain TLS 1.3 over TCP"
  getServerConnection = pure
  getClientConnection = pure
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

data SMPVersion = SMPVersion Int Int Int Int
  deriving (Eq, Ord)

instance IsString SMPVersion where
  fromString = parseString $ parseAll smpVersionP

major :: SMPVersion -> (Int, Int)
major (SMPVersion a b _ _) = (a, b)

currentSMPVersion :: SMPVersion
currentSMPVersion = "0.5.0.0"

currentSMPVersionStr :: ByteString
currentSMPVersionStr = serializeSMPVersion currentSMPVersion

serializeSMPVersion :: SMPVersion -> ByteString
serializeSMPVersion (SMPVersion a b c d) = B.intercalate "." [bshow a, bshow b, bshow c, bshow d]

smpVersionP :: Parser SMPVersion
smpVersionP =
  let ver = A.decimal <* A.char '.'
   in SMPVersion <$> ver <*> ver <*> ver <*> A.decimal

-- | The handle for SMP encrypted transport connection over Transport .
data THandle c = THandle
  { connection :: c,
    sndKey :: SessionKey,
    rcvKey :: SessionKey,
    blockSize :: Int
  }

data SessionKey = SessionKey
  { aesKey :: C.Key,
    baseIV :: C.IV,
    counter :: TVar Word32
  }

data ClientHandshake = ClientHandshake
  { blockSize :: Int,
    sndKey :: SessionKey,
    rcvKey :: SessionKey
  }

-- | Error of SMP encrypted transport over TCP.
data TransportError
  = -- | error parsing transport block
    TEBadBlock
  | -- | block encryption error
    TEEncrypt
  | -- | block decryption error
    TEDecrypt
  | -- | transport handshake error
    TEHandshake HandshakeError
  deriving (Eq, Generic, Read, Show, Exception)

-- | Transport handshake error.
data HandshakeError
  = -- | encryption error
    ENCRYPT
  | -- | decryption error
    DECRYPT
  | -- | error parsing protocol version
    VERSION
  | -- | error parsing RSA key
    RSA_KEY
  | -- | error parsing server transport header or invalid block size
    HEADER
  | -- | error parsing AES keys
    AES_KEYS
  | -- | not matching RSA key hash
    BAD_HASH
  | -- | lower major agent version than protocol version
    MAJOR_VERSION
  | -- | TCP transport terminated
    TERMINATED
  deriving (Eq, Generic, Read, Show, Exception)

instance Arbitrary TransportError where arbitrary = genericArbitraryU

instance Arbitrary HandshakeError where arbitrary = genericArbitraryU

-- | SMP encrypted transport error parser.
transportErrorP :: Parser TransportError
transportErrorP =
  "BLOCK" $> TEBadBlock
    <|> "AES_ENCRYPT" $> TEEncrypt
    <|> "AES_DECRYPT" $> TEDecrypt
    <|> TEHandshake <$> parseRead1

-- | Serialize SMP encrypted transport error.
serializeTransportError :: TransportError -> ByteString
serializeTransportError = \case
  TEEncrypt -> "AES_ENCRYPT"
  TEDecrypt -> "AES_DECRYPT"
  TEBadBlock -> "BLOCK"
  TEHandshake e -> bshow e

-- | Encrypt and send block to SMP encrypted transport.
tPutEncrypted :: Transport c => THandle c -> ByteString -> IO (Either TransportError ())
tPutEncrypted THandle {connection = c, sndKey, blockSize} block =
  encryptBlock sndKey (blockSize - C.authTagSize) block >>= \case
    Left _ -> pure $ Left TEEncrypt
    Right (authTag, msg) -> Right <$> cPut c (msg <> C.authTagToBS authTag)

-- | Receive and decrypt block from SMP encrypted transport.
tGetEncrypted :: Transport c => THandle c -> IO (Either TransportError ByteString)
tGetEncrypted THandle {connection = c, rcvKey, blockSize} =
  cGet c blockSize >>= decryptBlock rcvKey >>= \case
    Left _ -> pure $ Left TEDecrypt
    Right "" -> ioe_EOF
    Right msg -> pure $ Right msg

encryptBlock :: SessionKey -> Int -> ByteString -> IO (Either C.CryptoError (AuthTag, ByteString))
encryptBlock k@SessionKey {aesKey} size block = do
  ivBytes <- makeNextIV k
  runExceptT $ C.encryptAES aesKey ivBytes size block

decryptBlock :: SessionKey -> ByteString -> IO (Either C.CryptoError ByteString)
decryptBlock k@SessionKey {aesKey} block = do
  let (msg', authTag) = B.splitAt (B.length block - C.authTagSize) block
  ivBytes <- makeNextIV k
  runExceptT $ C.decryptAES aesKey ivBytes msg' (C.bsToAuthTag authTag)

makeNextIV :: SessionKey -> IO C.IV
makeNextIV SessionKey {baseIV, counter} = atomically $ do
  c <- readTVar counter
  writeTVar counter $ c + 1
  pure $ iv c
  where
    (start, rest) = B.splitAt 4 $ C.unIV baseIV
    iv c = C.IV $ (start `xor` encodeWord32 c) <> rest

-- | Server SMP encrypted transport handshake.
--
-- See https://github.com/simplex-chat/simplexmq/blob/master/protocol/simplex-messaging.md#appendix-a
--
-- The numbers in function names refer to the steps in the document.
serverHandshake :: forall c. Transport c => c -> Int -> C.KeyPair 'C.RSA -> ExceptT TransportError IO (THandle c)
serverHandshake c srvBlockSize (k, pk) = do
  checkValidBlockSize srvBlockSize
  liftIO sendHeaderAndPublicKey_1
  encryptedKeys <- receiveEncryptedKeys_4
  ClientHandshake {blockSize, sndKey, rcvKey} <- decryptParseKeys_5 encryptedKeys
  checkValidBlockSize blockSize
  th <- liftIO $ transportHandle c rcvKey sndKey blockSize -- keys are swapped here
  sendWelcome_6 th
  pure th
  where
    sendHeaderAndPublicKey_1 :: IO ()
    sendHeaderAndPublicKey_1 = do
      let sKey = C.encodeKey k
          header = ServerHeader {blockSize = srvBlockSize, keySize = B.length sKey}
      cPut c $ binaryServerHeader header
      cPut c sKey
    receiveEncryptedKeys_4 :: ExceptT TransportError IO ByteString
    receiveEncryptedKeys_4 =
      liftIO (cGet c $ C.keySize k) >>= \case
        "" -> throwE $ TEHandshake TERMINATED
        ks -> pure ks
    decryptParseKeys_5 :: ByteString -> ExceptT TransportError IO ClientHandshake
    decryptParseKeys_5 encKeys =
      liftError (const $ TEHandshake DECRYPT) (C.decryptOAEP pk encKeys)
        >>= liftEither . parseClientHandshake
    sendWelcome_6 :: THandle c -> ExceptT TransportError IO ()
    sendWelcome_6 th = ExceptT . tPutEncrypted th $ currentSMPVersionStr <> " "

-- | Client SMP encrypted transport handshake.
--
-- See https://github.com/simplex-chat/simplexmq/blob/master/protocol/simplex-messaging.md#appendix-a
--
-- The numbers in function names refer to the steps in the document.
clientHandshake :: forall c. Transport c => c -> Maybe Int -> Maybe C.KeyHash -> ExceptT TransportError IO (THandle c)
clientHandshake c blkSize_ keyHash = do
  mapM_ checkValidBlockSize blkSize_
  (k, blkSize) <- getHeaderAndPublicKey_1_2
  let clientBlkSize = fromMaybe blkSize blkSize_
  chs@ClientHandshake {sndKey, rcvKey} <- liftIO $ generateKeys_3 clientBlkSize
  sendEncryptedKeys_4 k chs
  th <- liftIO $ transportHandle c sndKey rcvKey clientBlkSize
  getWelcome_6 th >>= checkVersion
  pure th
  where
    getHeaderAndPublicKey_1_2 :: ExceptT TransportError IO (C.PublicKey 'C.RSA, Int)
    getHeaderAndPublicKey_1_2 = do
      header <- liftIO (cGet c serverHeaderSize)
      ServerHeader {blockSize, keySize} <- liftEither $ parse serverHeaderP (TEHandshake HEADER) header
      checkValidBlockSize blockSize
      s <- liftIO $ cGet c keySize
      maybe (pure ()) (validateKeyHash_2 s) keyHash
      key <- liftEither $ parseKey s
      pure (key, blockSize)
    parseKey :: ByteString -> Either TransportError (C.PublicKey 'C.RSA)
    parseKey = first (const $ TEHandshake RSA_KEY) . parseAll C.binaryKeyP
    validateKeyHash_2 :: ByteString -> C.KeyHash -> ExceptT TransportError IO ()
    validateKeyHash_2 k (C.KeyHash kHash)
      | C.sha256Hash k == kHash = pure ()
      | otherwise = throwE $ TEHandshake BAD_HASH
    generateKeys_3 :: Int -> IO ClientHandshake
    generateKeys_3 blkSize = ClientHandshake blkSize <$> generateKey <*> generateKey
    generateKey :: IO SessionKey
    generateKey = do
      aesKey <- C.randomAesKey
      baseIV <- C.randomIV
      pure SessionKey {aesKey, baseIV, counter = undefined}
    sendEncryptedKeys_4 :: C.PublicKey 'C.RSA -> ClientHandshake -> ExceptT TransportError IO ()
    sendEncryptedKeys_4 k chs =
      liftError (const $ TEHandshake ENCRYPT) (C.encryptOAEP k $ serializeClientHandshake chs)
        >>= liftIO . cPut c
    getWelcome_6 :: THandle c -> ExceptT TransportError IO SMPVersion
    getWelcome_6 th = ExceptT $ (>>= parseSMPVersion) <$> tGetEncrypted th
    parseSMPVersion :: ByteString -> Either TransportError SMPVersion
    parseSMPVersion = first (const $ TEHandshake VERSION) . A.parseOnly (smpVersionP <* A.space)
    checkVersion :: SMPVersion -> ExceptT TransportError IO ()
    checkVersion smpVersion =
      when (major smpVersion > major currentSMPVersion) . throwE $
        TEHandshake MAJOR_VERSION

checkValidBlockSize :: Int -> ExceptT TransportError IO ()
checkValidBlockSize blkSize =
  when (blkSize `notElem` transportBlockSizes) . throwError $ TEHandshake HEADER

data ServerHeader = ServerHeader {blockSize :: Int, keySize :: Int}
  deriving (Eq, Show)

binaryRsaTransport :: Int
binaryRsaTransport = 0

transportBlockSizes :: [Int]
transportBlockSizes = map (* 1024) [4, 8, 16, 32, 64]

serverHeaderSize :: Int
serverHeaderSize = 8

binaryServerHeader :: ServerHeader -> ByteString
binaryServerHeader ServerHeader {blockSize, keySize} =
  encodeEnum32 blockSize <> encodeEnum16 binaryRsaTransport <> encodeEnum16 keySize

serverHeaderP :: Parser ServerHeader
serverHeaderP = ServerHeader <$> int32 <* binaryRsaTransportP <*> int16

serializeClientHandshake :: ClientHandshake -> ByteString
serializeClientHandshake ClientHandshake {blockSize, sndKey, rcvKey} =
  encodeEnum32 blockSize <> encodeEnum16 binaryRsaTransport <> serializeKey sndKey <> serializeKey rcvKey
  where
    serializeKey :: SessionKey -> ByteString
    serializeKey SessionKey {aesKey, baseIV} = C.unKey aesKey <> C.unIV baseIV

clientHandshakeP :: Parser ClientHandshake
clientHandshakeP = ClientHandshake <$> int32 <* binaryRsaTransportP <*> keyP <*> keyP
  where
    keyP :: Parser SessionKey
    keyP = do
      aesKey <- C.aesKeyP
      baseIV <- C.ivP
      pure SessionKey {aesKey, baseIV, counter = undefined}

int32 :: Parser Int
int32 = decodeNum32 <$> A.take 4

int16 :: Parser Int
int16 = decodeNum16 <$> A.take 2

binaryRsaTransportP :: Parser ()
binaryRsaTransportP = binaryRsa =<< int16
  where
    binaryRsa :: Int -> Parser ()
    binaryRsa n
      | n == binaryRsaTransport = pure ()
      | otherwise = fail "unknown transport mode"

parseClientHandshake :: ByteString -> Either TransportError ClientHandshake
parseClientHandshake = parse clientHandshakeP $ TEHandshake AES_KEYS

transportHandle :: c -> SessionKey -> SessionKey -> Int -> IO (THandle c)
transportHandle c sk rk blockSize = do
  sndCounter <- newTVarIO 0
  rcvCounter <- newTVarIO 0
  pure
    THandle
      { connection = c,
        sndKey = sk {counter = sndCounter},
        rcvKey = rk {counter = rcvCounter},
        blockSize
      }
