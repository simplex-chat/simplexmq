{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Simplex.Messaging.Transport where

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
import Data.Set (Set)
import qualified Data.Set as S
import Data.Word (Word32)
import GHC.IO.Exception (IOErrorType (..))
import GHC.IO.Handle.Internals (ioe_EOF)
import Network.Socket
import Network.Transport.Internal (encodeWord32)
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Parsers (parse, parseAll)
import Simplex.Messaging.Util (bshow, liftError)
import System.IO
import System.IO.Error
import UnliftIO.Concurrent
import UnliftIO.Exception (Exception, IOException)
import qualified UnliftIO.Exception as E
import qualified UnliftIO.IO as IO
import UnliftIO.STM

-- * TCP transport

runTCPServer :: MonadUnliftIO m => ServiceName -> (Handle -> m ()) -> m ()
runTCPServer port server = do
  clients <- newTVarIO S.empty
  E.bracket (liftIO $ startTCPServer port) (liftIO . closeServer clients) $ \sock -> forever $ do
    h <- liftIO $ acceptTCPConn sock
    tid <- forkFinally (server h) (const $ IO.hClose h)
    atomically . modifyTVar clients $ S.insert tid
  where
    closeServer :: TVar (Set ThreadId) -> Socket -> IO ()
    closeServer clients sock = readTVarIO clients >>= mapM_ killThread >> close sock

startTCPServer :: ServiceName -> IO Socket
startTCPServer port = withSocketsDo $ resolve >>= open
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

acceptTCPConn :: Socket -> IO Handle
acceptTCPConn sock = accept sock >>= getSocketHandle . fst

runTCPClient :: MonadUnliftIO m => HostName -> ServiceName -> (Handle -> m a) -> m a
runTCPClient host port client = do
  h <- liftIO $ startTCPClient host port
  client h `E.finally` IO.hClose h

startTCPClient :: HostName -> ServiceName -> IO Handle
startTCPClient host port =
  withSocketsDo $
    resolve >>= foldM tryOpen (Left err) >>= either E.throwIO return -- replace fold with recursion
  where
    err :: IOException
    err = mkIOError NoSuchThing "no address" Nothing Nothing

    resolve :: IO [AddrInfo]
    resolve =
      let hints = defaultHints {addrSocketType = Stream}
       in getAddrInfo (Just hints) (Just host) (Just port)

    tryOpen :: Exception e => Either e Handle -> AddrInfo -> IO (Either e Handle)
    tryOpen (Left _) addr = E.try $ open addr
    tryOpen h _ = return h

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
getLn h = trim_cr <$> B.hGetLine h
  where
    trim_cr "" = ""
    trim_cr s = if B.last s == '\r' then B.init s else s

-- * Encrypted transport

data SMPVersion = SMPVersion Int Int Int Int
  deriving (Eq, Ord)

major :: SMPVersion -> (Int, Int)
major (SMPVersion a b _ _) = (a, b)

currentSMPVersion :: SMPVersion
currentSMPVersion = SMPVersion 0 2 0 0

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

data HandshakeKeys = HandshakeKeys
  { sndKey :: SessionKey,
    rcvKey :: SessionKey
  }

data TransportError
  = TransportCryptoError C.CryptoError
  | TransportParsingError
  | TransportHandshakeError String
  deriving (Eq, Show, Exception)

tPutEncrypted :: THandle -> ByteString -> IO (Either TransportError ())
tPutEncrypted THandle {handle = h, sndKey, blockSize} block =
  encryptBlock sndKey (blockSize - C.authTagSize) block >>= \case
    Left e -> return . Left $ TransportCryptoError e
    Right (authTag, msg) -> Right <$> B.hPut h (C.authTagToBS authTag <> msg)

tGetEncrypted :: THandle -> IO (Either TransportError ByteString)
tGetEncrypted THandle {handle = h, rcvKey, blockSize} =
  B.hGet h blockSize >>= decryptBlock rcvKey >>= \case
    Left e -> pure . Left $ TransportCryptoError e
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
  liftIO sendPublicKey_1
  encryptedKeys <- receiveEncryptedKeys_4
  HandshakeKeys {sndKey, rcvKey} <- decryptParseKeys_5 encryptedKeys
  th <- liftIO $ transportHandle h rcvKey sndKey -- keys are swapped here
  sendWelcome_6 th
  pure th
  where
    sendPublicKey_1 :: IO ()
    sendPublicKey_1 = putLn h $ C.serializePubKey k
    receiveEncryptedKeys_4 :: ExceptT TransportError IO ByteString
    receiveEncryptedKeys_4 =
      liftIO (B.hGet h $ C.publicKeySize k) >>= \case
        "" -> throwE $ TransportHandshakeError "EOF"
        ks -> pure ks
    decryptParseKeys_5 :: ByteString -> ExceptT TransportError IO HandshakeKeys
    decryptParseKeys_5 encKeys =
      liftError TransportCryptoError (C.decryptOAEP pk encKeys)
        >>= liftEither . parseHandshakeKeys
    sendWelcome_6 :: THandle -> ExceptT TransportError IO ()
    sendWelcome_6 th = ExceptT . tPutEncrypted th $ serializeSMPVersion currentSMPVersion <> " "

-- | implements client transport handshake as per /rfcs/2021-01-26-crypto.md#transport-encryption
-- The numbers in function names refer to the steps in the document
clientHandshake :: Handle -> Maybe C.KeyHash -> ExceptT TransportError IO THandle
clientHandshake h keyHash = do
  k <- getPublicKey_1_2
  keys@HandshakeKeys {sndKey, rcvKey} <- liftIO generateKeys_3
  sendEncryptedKeys_4 k keys
  th <- liftIO $ transportHandle h sndKey rcvKey
  getWelcome_6 th >>= checkVersion
  pure th
  where
    getPublicKey_1_2 :: ExceptT TransportError IO C.PublicKey
    getPublicKey_1_2 = do
      s <- liftIO $ getLn h
      maybe (pure ()) (validateKeyHash_2 s) keyHash
      liftEither $ parseKey s
    parseKey :: ByteString -> Either TransportError C.PublicKey
    parseKey = first TransportHandshakeError . parseAll C.pubKeyP
    validateKeyHash_2 :: ByteString -> C.KeyHash -> ExceptT TransportError IO ()
    validateKeyHash_2 k kHash
      | C.getKeyHash k == kHash = pure ()
      | otherwise = throwE $ TransportHandshakeError "wrong key hash"
    generateKeys_3 :: IO HandshakeKeys
    generateKeys_3 = HandshakeKeys <$> generateKey <*> generateKey
    generateKey :: IO SessionKey
    generateKey = do
      aesKey <- C.randomAesKey
      baseIV <- C.randomIV
      pure SessionKey {aesKey, baseIV, counter = undefined}
    sendEncryptedKeys_4 :: C.PublicKey -> HandshakeKeys -> ExceptT TransportError IO ()
    sendEncryptedKeys_4 k keys =
      liftError TransportCryptoError (C.encryptOAEP k $ serializeHandshakeKeys keys)
        >>= liftIO . B.hPut h
    getWelcome_6 :: THandle -> ExceptT TransportError IO SMPVersion
    getWelcome_6 th = ExceptT $ (>>= parseSMPVersion) <$> tGetEncrypted th
    parseSMPVersion :: ByteString -> Either TransportError SMPVersion
    parseSMPVersion = first TransportHandshakeError . A.parseOnly (smpVersionP <* A.space)
    checkVersion :: SMPVersion -> ExceptT TransportError IO ()
    checkVersion smpVersion =
      when (major smpVersion > major currentSMPVersion) . throwE $
        TransportHandshakeError "SMP server version"

serializeHandshakeKeys :: HandshakeKeys -> ByteString
serializeHandshakeKeys HandshakeKeys {sndKey, rcvKey} =
  serializeKey sndKey <> serializeKey rcvKey
  where
    serializeKey :: SessionKey -> ByteString
    serializeKey SessionKey {aesKey, baseIV} = C.unKey aesKey <> C.unIV baseIV

handshakeKeysP :: Parser HandshakeKeys
handshakeKeysP = HandshakeKeys <$> keyP <*> keyP
  where
    keyP :: Parser SessionKey
    keyP = do
      aesKey <- C.aesKeyP
      baseIV <- C.ivP
      pure SessionKey {aesKey, baseIV, counter = undefined}

parseHandshakeKeys :: ByteString -> Either TransportError HandshakeKeys
parseHandshakeKeys = parse handshakeKeysP $ TransportHandshakeError "parsing keys"

transportHandle :: Handle -> SessionKey -> SessionKey -> IO THandle
transportHandle h sk rk = do
  sndCounter <- newTVarIO 0
  rcvCounter <- newTVarIO 0
  pure
    THandle
      { handle = h,
        sndKey = sk {counter = sndCounter},
        rcvKey = rk {counter = rcvCounter},
        blockSize = 8192
      }
