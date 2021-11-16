{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
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

    -- * Transport over TCP
    runTransportServer,
    runTransportClient,

    -- * TCP transport
    TCP (..),

    -- * SMP encrypted transport
    THandle (..),
    TransportError (..),
    serverHandshake,
    clientHandshake,
    tPutEncrypted,
    tGetEncrypted,
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
import Crypto.Cipher.Types (AuthTag)
import Data.Attoparsec.ByteString.Char8 (Parser)
import qualified Data.Attoparsec.ByteString.Char8 as A
import Data.Bifunctor (first)
import Data.ByteArray (xor)
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.Functor (($>))
import Data.Maybe(fromMaybe)
import Data.Set (Set)
import qualified Data.Set as S
import Data.String
import Data.Word (Word32)
import GHC.Generics (Generic)
import GHC.IO.Exception (IOErrorType (..))
import GHC.IO.Handle.Internals (ioe_EOF)
import Generic.Random (genericArbitraryU)
import Network.Socket
import Network.Transport.Internal (decodeNum16, decodeNum32, encodeEnum16, encodeEnum32, encodeWord32)
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Parsers (parse, parseAll, parseRead1, parseString)
import Simplex.Messaging.Util (bshow, liftError)
import System.IO
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

  -- | Upgrade client socket to connection (used in the server)
  getServerConnection :: Socket -> IO c

  -- | Upgrade server socket to connection (used in the client)
  getClientConnection :: Socket -> IO c

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

-- * Transport over TCP

-- | Run transport server (plain TCP or WebSockets) on passed TCP port and signal when server started and stopped via passed TMVar.
--
-- All accepted connections are passed to the passed function.
runTransportServer :: (Transport c, MonadUnliftIO m) => TMVar Bool -> ServiceName -> (c -> m ()) -> m ()
runTransportServer started port server = do
  clients <- newTVarIO S.empty
  E.bracket (liftIO $ startTCPServer started port) (liftIO . closeServer clients) $ \sock -> forever $ do
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
    acceptConnection sock = accept sock >>= getServerConnection . fst

startTCPServer :: TMVar Bool -> ServiceName -> IO Socket
startTCPServer started port = withSocketsDo $ resolve >>= open >>= setStarted
  where
    resolve =
      let hints = defaultHints {addrFlags = [AI_PASSIVE], addrSocketType = Stream}
       in head <$> getAddrInfo (Just hints) Nothing (Just port)
    open addr = do
      sock <- socket (addrFamily addr) (addrSocketType addr) (addrProtocol addr)
      setSocketOption sock ReuseAddr 1
      -- removed for GHC 8.4.4
      -- withFdSocket sock setCloseOnExecIfNeeded
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
      getClientConnection sock

-- * TCP transport

newtype TCP = TCP {tcpHandle :: Handle}

instance Transport TCP where
  transportName _ = "TCP"
  getServerConnection = fmap TCP . getSocketHandle
  getClientConnection = getServerConnection
  closeConnection (TCP h) = hClose h `E.catch` \(_ :: E.SomeException) -> pure ()
  cGet = B.hGet . tcpHandle
  cPut = B.hPut . tcpHandle
  getLn = fmap trimCR . B.hGetLine . tcpHandle

getSocketHandle :: Socket -> IO Handle
getSocketHandle conn = do
  h <- socketToHandle conn ReadWriteMode
  hSetBinaryMode h True
  hSetNewlineMode h NewlineMode {inputNL = CRLF, outputNL = CRLF}
  hSetBuffering h LineBuffering
  return h

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
currentSMPVersion = "0.4.1.0"

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
serverHandshake :: forall c. Transport c => c -> Int -> C.FullKeyPair -> ExceptT TransportError IO (THandle c)
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
      let sKey = C.encodePubKey k
          header = ServerHeader {blockSize = srvBlockSize, keySize = B.length sKey}
      cPut c $ binaryServerHeader header
      cPut c sKey
    receiveEncryptedKeys_4 :: ExceptT TransportError IO ByteString
    receiveEncryptedKeys_4 =
      liftIO (cGet c $ C.publicKeySize k) >>= \case
        "" -> throwE $ TEHandshake TERMINATED
        ks -> pure ks
    decryptParseKeys_5 :: ByteString -> ExceptT TransportError IO ClientHandshake
    decryptParseKeys_5 encKeys =
      liftError (const $ TEHandshake DECRYPT) (C.decryptOAEP pk encKeys)
        >>= liftEither . parseClientHandshake
    sendWelcome_6 :: THandle c -> ExceptT TransportError IO ()
    sendWelcome_6 th = ExceptT . tPutEncrypted th $ serializeSMPVersion currentSMPVersion <> " "

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
    getHeaderAndPublicKey_1_2 :: ExceptT TransportError IO (C.PublicKey, Int)
    getHeaderAndPublicKey_1_2 = do
      header <- liftIO (cGet c serverHeaderSize)
      ServerHeader {blockSize, keySize} <- liftEither $ parse serverHeaderP (TEHandshake HEADER) header
      checkValidBlockSize blockSize
      s <- liftIO $ cGet c keySize
      maybe (pure ()) (validateKeyHash_2 s) keyHash
      key <- liftEither $ parseKey s
      pure (key, blockSize)
    parseKey :: ByteString -> Either TransportError C.PublicKey
    parseKey = first (const $ TEHandshake RSA_KEY) . parseAll C.binaryPubKeyP
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
    sendEncryptedKeys_4 :: C.PublicKey -> ClientHandshake -> ExceptT TransportError IO ()
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
