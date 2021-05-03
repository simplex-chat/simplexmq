{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Simplex.Messaging.Transport where

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
import Data.Set (Set)
import qualified Data.Set as S
import Data.Word (Word32)
import GHC.Generics (Generic)
import GHC.IO.Exception (IOErrorType (..))
import GHC.IO.Handle.Internals (ioe_EOF)
import Generic.Random (genericArbitraryU)
import Network.Socket
import Network.Transport.Internal (decodeNum16, decodeNum32, encodeEnum16, encodeEnum32, encodeWord32)
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Parsers (parse, parseAll, parseRead1)
import Simplex.Messaging.Util (bshow, liftError)
import System.IO
import System.IO.Error
import Test.QuickCheck (Arbitrary (..))
import UnliftIO.Concurrent
import UnliftIO.Exception (Exception, IOException)
import qualified UnliftIO.Exception as E
import qualified UnliftIO.IO as IO
import UnliftIO.STM

-- * TCP transport

runTCPServer :: MonadUnliftIO m => TMVar Bool -> ServiceName -> (Handle -> m ()) -> m ()
runTCPServer started port server = do
  clients <- newTVarIO S.empty
  E.bracket (liftIO $ startTCPServer started port) (liftIO . closeServer clients) \sock -> forever $ do
    h <- liftIO $ acceptTCPConn sock
    tid <- forkFinally (server h) (const $ IO.hClose h)
    atomically . modifyTVar clients $ S.insert tid
  where
    closeServer :: TVar (Set ThreadId) -> Socket -> IO ()
    closeServer clients sock = do
      readTVarIO clients >>= mapM_ killThread
      close sock
      void . atomically $ tryPutTMVar started False

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
    setStarted sock = atomically (putTMVar started True) >> pure sock

acceptTCPConn :: Socket -> IO Handle
acceptTCPConn sock = accept sock >>= getSocketHandle . fst

runTCPClient :: MonadUnliftIO m => HostName -> ServiceName -> (Handle -> m a) -> m a
runTCPClient host port client = do
  h <- liftIO $ startTCPClient host port
  client h `E.finally` IO.hClose h

startTCPClient :: HostName -> ServiceName -> IO Handle
startTCPClient host port = withSocketsDo $ resolve >>= tryOpen err
  where
    err :: IOException
    err = mkIOError NoSuchThing "no address" Nothing Nothing

    resolve :: IO [AddrInfo]
    resolve =
      let hints = defaultHints {addrSocketType = Stream}
       in getAddrInfo (Just hints) (Just host) (Just port)

    tryOpen :: IOException -> [AddrInfo] -> IO Handle
    tryOpen e [] = E.throwIO e
    tryOpen _ (addr : as) =
      E.try (open addr) >>= either (`tryOpen` as) pure

    open :: AddrInfo -> IO Handle
    open addr = do
      sock <- socket (addrFamily addr) (addrSocketType addr) (addrProtocol addr)
      connect sock $ addrAddress addr
      getSocketHandle sock

getSocketHandle :: Socket -> IO Handle
getSocketHandle conn = do
  h <- socketToHandle conn ReadWriteMode
  hSetBinaryMode h True
  hSetNewlineMode h NewlineMode {inputNL = CRLF, outputNL = CRLF}
  hSetBuffering h LineBuffering
  return h

putLn :: Handle -> ByteString -> IO ()
putLn h = B.hPut h . (<> "\r\n")

getLn :: Handle -> IO ByteString
getLn h = trimCR <$> B.hGetLine h

trimCR :: ByteString -> ByteString
trimCR "" = ""
trimCR s = if B.last s == '\r' then B.init s else s

-- * Encrypted transport

data SMPVersion = SMPVersion Int Int Int Int
  deriving (Eq, Ord)

major :: SMPVersion -> (Int, Int)
major (SMPVersion a b _ _) = (a, b)

currentSMPVersion :: SMPVersion
currentSMPVersion = SMPVersion 0 3 0 0

serializeSMPVersion :: SMPVersion -> ByteString
serializeSMPVersion (SMPVersion a b c d) = B.intercalate "." [bshow a, bshow b, bshow c, bshow d]

smpVersionP :: Parser SMPVersion
smpVersionP =
  let ver = A.decimal <* A.char '.'
   in SMPVersion <$> ver <*> ver <*> ver <*> A.decimal

data THandle = THandle
  { handle :: Handle,
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

data TransportError
  = TEBadBlock
  | TEEncrypt
  | TEDecrypt
  | TEHandshake HandshakeError
  deriving (Eq, Generic, Read, Show, Exception)

data HandshakeError
  = ENCRYPT
  | DECRYPT
  | VERSION
  | RSA_KEY
  | HEADER
  | AES_KEYS
  | BAD_HASH
  | MAJOR_VERSION
  | TERMINATED
  deriving (Eq, Generic, Read, Show, Exception)

instance Arbitrary TransportError where arbitrary = genericArbitraryU

instance Arbitrary HandshakeError where arbitrary = genericArbitraryU

transportErrorP :: Parser TransportError
transportErrorP =
  "BLOCK" $> TEBadBlock
    <|> "AES_ENCRYPT" $> TEEncrypt
    <|> "AES_DECRYPT" $> TEDecrypt
    <|> TEHandshake <$> parseRead1

serializeTransportError :: TransportError -> ByteString
serializeTransportError = \case
  TEEncrypt -> "AES_ENCRYPT"
  TEDecrypt -> "AES_DECRYPT"
  TEBadBlock -> "BLOCK"
  TEHandshake e -> bshow e

tPutEncrypted :: THandle -> ByteString -> IO (Either TransportError ())
tPutEncrypted THandle {handle = h, sndKey, blockSize} block =
  encryptBlock sndKey (blockSize - C.authTagSize) block >>= \case
    Left _ -> pure $ Left TEEncrypt
    Right (authTag, msg) -> Right <$> B.hPut h (C.authTagToBS authTag <> msg)

tGetEncrypted :: THandle -> IO (Either TransportError ByteString)
tGetEncrypted THandle {handle = h, rcvKey, blockSize} =
  B.hGet h blockSize >>= decryptBlock rcvKey >>= \case
    Left _ -> pure $ Left TEDecrypt
    Right "" -> ioe_EOF
    Right msg -> pure $ Right msg

encryptBlock :: SessionKey -> Int -> ByteString -> IO (Either C.CryptoError (AuthTag, ByteString))
encryptBlock k@SessionKey {aesKey} size block = do
  ivBytes <- makeNextIV k
  runExceptT $ C.encryptAES aesKey ivBytes size block

decryptBlock :: SessionKey -> ByteString -> IO (Either C.CryptoError ByteString)
decryptBlock k@SessionKey {aesKey} block = do
  let (authTag, msg') = B.splitAt C.authTagSize block
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

-- | implements server transport handshake as per /rfcs/2021-01-26-crypto.md#transport-encryption
-- The numbers in function names refer to the steps in the document
serverHandshake :: Handle -> C.FullKeyPair -> ExceptT TransportError IO THandle
serverHandshake h (k, pk) = do
  liftIO sendHeaderAndPublicKey_1
  encryptedKeys <- receiveEncryptedKeys_4
  -- TODO server currently ignores blockSize returned by the client
  -- this is reserved for future support of streams
  ClientHandshake {blockSize = _, sndKey, rcvKey} <- decryptParseKeys_5 encryptedKeys
  th <- liftIO $ transportHandle h rcvKey sndKey transportBlockSize -- keys are swapped here
  sendWelcome_6 th
  pure th
  where
    sendHeaderAndPublicKey_1 :: IO ()
    sendHeaderAndPublicKey_1 = do
      let sKey = C.encodePubKey k
          header = ServerHeader {blockSize = transportBlockSize, keySize = B.length sKey}
      B.hPut h $ binaryServerHeader header <> sKey
    receiveEncryptedKeys_4 :: ExceptT TransportError IO ByteString
    receiveEncryptedKeys_4 =
      liftIO (B.hGet h $ C.publicKeySize k) >>= \case
        "" -> throwE $ TEHandshake TERMINATED
        ks -> pure ks
    decryptParseKeys_5 :: ByteString -> ExceptT TransportError IO ClientHandshake
    decryptParseKeys_5 encKeys =
      liftError (const $ TEHandshake DECRYPT) (C.decryptOAEP pk encKeys)
        >>= liftEither . parseClientHandshake
    sendWelcome_6 :: THandle -> ExceptT TransportError IO ()
    sendWelcome_6 th = ExceptT . tPutEncrypted th $ serializeSMPVersion currentSMPVersion <> " "

-- | implements client transport handshake as per /rfcs/2021-01-26-crypto.md#transport-encryption
-- The numbers in function names refer to the steps in the document
clientHandshake :: Handle -> Maybe C.KeyHash -> ExceptT TransportError IO THandle
clientHandshake h keyHash = do
  (k, blkSize) <- getHeaderAndPublicKey_1_2
  -- TODO currently client always uses the blkSize returned by the server
  keys@ClientHandshake {sndKey, rcvKey} <- liftIO $ generateKeys_3 blkSize
  sendEncryptedKeys_4 k keys
  th <- liftIO $ transportHandle h sndKey rcvKey blkSize
  getWelcome_6 th >>= checkVersion
  pure th
  where
    getHeaderAndPublicKey_1_2 :: ExceptT TransportError IO (C.PublicKey, Int)
    getHeaderAndPublicKey_1_2 = do
      header <- liftIO (B.hGet h serverHeaderSize)
      ServerHeader {blockSize, keySize} <- liftEither $ parse serverHeaderP (TEHandshake HEADER) header
      when (blockSize < transportBlockSize || blockSize > maxTransportBlockSize) $
        throwError $ TEHandshake HEADER
      s <- liftIO $ B.hGet h keySize
      maybe (pure ()) (validateKeyHash_2 s) keyHash
      key <- liftEither $ parseKey s
      pure (key, blockSize)
    parseKey :: ByteString -> Either TransportError C.PublicKey
    parseKey = first (const $ TEHandshake RSA_KEY) . parseAll C.binaryPubKeyP
    validateKeyHash_2 :: ByteString -> C.KeyHash -> ExceptT TransportError IO ()
    validateKeyHash_2 k kHash
      | C.getKeyHash k == kHash = pure ()
      | otherwise = throwE $ TEHandshake BAD_HASH
    generateKeys_3 :: Int -> IO ClientHandshake
    generateKeys_3 blkSize = ClientHandshake blkSize <$> generateKey <*> generateKey
    generateKey :: IO SessionKey
    generateKey = do
      aesKey <- C.randomAesKey
      baseIV <- C.randomIV
      pure SessionKey {aesKey, baseIV, counter = undefined}
    sendEncryptedKeys_4 :: C.PublicKey -> ClientHandshake -> ExceptT TransportError IO ()
    sendEncryptedKeys_4 k keys =
      liftError (const $ TEHandshake ENCRYPT) (C.encryptOAEP k $ serializeClientHandshake keys)
        >>= liftIO . B.hPut h
    getWelcome_6 :: THandle -> ExceptT TransportError IO SMPVersion
    getWelcome_6 th = ExceptT $ (>>= parseSMPVersion) <$> tGetEncrypted th
    parseSMPVersion :: ByteString -> Either TransportError SMPVersion
    parseSMPVersion = first (const $ TEHandshake VERSION) . A.parseOnly (smpVersionP <* A.space)
    checkVersion :: SMPVersion -> ExceptT TransportError IO ()
    checkVersion smpVersion =
      when (major smpVersion > major currentSMPVersion) . throwE $
        TEHandshake MAJOR_VERSION

data ServerHeader = ServerHeader {blockSize :: Int, keySize :: Int}
  deriving (Eq, Show)

binaryRsaTransport :: Int
binaryRsaTransport = 0

transportBlockSize :: Int
transportBlockSize = 4096

maxTransportBlockSize :: Int
maxTransportBlockSize = 65536

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

transportHandle :: Handle -> SessionKey -> SessionKey -> Int -> IO THandle
transportHandle h sk rk blockSize = do
  sndCounter <- newTVarIO 0
  rcvCounter <- newTVarIO 0
  pure
    THandle
      { handle = h,
        sndKey = sk {counter = sndCounter},
        rcvKey = rk {counter = rcvCounter},
        blockSize
      }
