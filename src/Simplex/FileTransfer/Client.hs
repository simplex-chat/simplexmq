{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeApplications #-}

module Simplex.FileTransfer.Client where

import Control.Logger.Simple
import Control.Monad
import Control.Monad.Except
import Control.Monad.Trans.Except
import Crypto.Random (ChaChaDRG)
import Data.Bifunctor (first)
import Data.ByteString.Builder (Builder, byteString)
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.Int (Int64)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Time.Clock (UTCTime)
import Data.Word (Word32)
import qualified Data.X509 as X
import qualified Data.X509.Validation as XV
import qualified Network.HTTP.Types as N
import qualified Network.HTTP2.Client as H
import Simplex.FileTransfer.Protocol
import Simplex.FileTransfer.Server.Env (supportedXFTPhandshakes)
import Simplex.FileTransfer.Transport
import Simplex.Messaging.Client
  ( NetworkConfig (..),
    ProtocolClientError (..),
    TransportSession,
    chooseTransportHost,
    defaultNetworkConfig,
    transportClientConfig,
    clientSocksCredentials,
    unexpectedResponse,
  )
import qualified Simplex.Messaging.Crypto as C
import qualified Simplex.Messaging.Crypto.Lazy as LC
import Simplex.Messaging.Encoding (smpDecode, smpEncode)
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Protocol
  ( BasicAuth,
    Protocol (..),
    ProtocolServer (..),
    RecipientId,
    SenderId,
    pattern NoEntity,
  )
import Simplex.Messaging.Transport (ALPN, HandshakeError (..), THandleAuth (..), THandleParams (..), TransportError (..), TransportPeer (..), defaultSupportedParams)
import Simplex.Messaging.Transport.Client (TransportClientConfig, TransportHost, alpn)
import Simplex.Messaging.Transport.HTTP2
import Simplex.Messaging.Transport.HTTP2.Client
import Simplex.Messaging.Transport.HTTP2.File
import Simplex.Messaging.Util (liftEitherWith, liftError', tshow, whenM)
import Simplex.Messaging.Version
import UnliftIO
import UnliftIO.Directory

data XFTPClient = XFTPClient
  { http2Client :: HTTP2Client,
    transportSession :: TransportSession FileResponse,
    thParams :: THandleParams XFTPVersion 'TClient,
    config :: XFTPClientConfig
  }

data XFTPClientConfig = XFTPClientConfig
  { xftpNetworkConfig :: NetworkConfig,
    serverVRange :: VersionRangeXFTP,
    clientALPN :: Maybe [ALPN]
  }

data XFTPChunkBody = XFTPChunkBody
  { chunkSize :: Int,
    chunkPart :: Int -> IO ByteString,
    http2Body :: HTTP2Body
  }

data XFTPChunkSpec = XFTPChunkSpec
  { filePath :: FilePath,
    chunkOffset :: Int64,
    chunkSize :: Word32
  }
  deriving (Eq, Show)

type XFTPClientError = ProtocolClientError XFTPErrorType

defaultXFTPClientConfig :: XFTPClientConfig
defaultXFTPClientConfig =
  XFTPClientConfig
    { xftpNetworkConfig = defaultNetworkConfig,
      serverVRange = supportedFileServerVRange,
      clientALPN = Just supportedXFTPhandshakes
    }

getXFTPClient :: TransportSession FileResponse -> XFTPClientConfig -> UTCTime -> (XFTPClient -> IO ()) -> IO (Either XFTPClientError XFTPClient)
getXFTPClient transportSession@(_, srv, _) config@XFTPClientConfig {clientALPN, xftpNetworkConfig, serverVRange} proxySessTs disconnected = runExceptT $ do
  let socksCreds = clientSocksCredentials xftpNetworkConfig proxySessTs transportSession
      ProtocolServer _ host port keyHash = srv
  useHost <- liftEither $ chooseTransportHost xftpNetworkConfig host
  let tcConfig = (transportClientConfig xftpNetworkConfig useHost False) {alpn = clientALPN}
      http2Config = xftpHTTP2Config tcConfig config
  clientVar <- newTVarIO Nothing
  let usePort = if null port then "443" else port
      clientDisconnected = readTVarIO clientVar >>= mapM_ disconnected
  http2Client <- liftError' xftpClientError $ getVerifiedHTTP2Client socksCreds useHost usePort (Just keyHash) Nothing http2Config clientDisconnected
  let HTTP2Client {sessionId, sessionALPN} = http2Client
      v = VersionXFTP 1
      thServerVRange = versionToRange v
      thParams0 = THandleParams {sessionId, blockSize = xftpBlockSize, thVersion = v, thServerVRange, thAuth = Nothing, implySessId = False, encryptBlock = Nothing, batch = True}
  logDebug $ "Client negotiated handshake protocol: " <> tshow sessionALPN
  thParams@THandleParams {thVersion} <- case sessionALPN of
    Just "xftp/1" -> xftpClientHandshakeV1 serverVRange keyHash http2Client thParams0
    _ -> pure thParams0
  logDebug $ "Client negotiated protocol: " <> tshow thVersion
  let c = XFTPClient {http2Client, thParams, transportSession, config}
  atomically $ writeTVar clientVar $ Just c
  pure c

xftpClientHandshakeV1 :: VersionRangeXFTP -> C.KeyHash -> HTTP2Client -> THandleParamsXFTP 'TClient -> ExceptT XFTPClientError IO (THandleParamsXFTP 'TClient)
xftpClientHandshakeV1 serverVRange keyHash@(C.KeyHash kh) c@HTTP2Client {sessionId, serverKey} thParams0 = do
  shs@XFTPServerHandshake {authPubKey = ck} <- getServerHandshake
  (vr, sk) <- processServerHandshake shs
  let v = maxVersion vr
  sendClientHandshake XFTPClientHandshake {xftpVersion = v, keyHash}
  pure thParams0 {thAuth = Just THAuthClient {serverPeerPubKey = sk, serverCertKey = ck, sessSecret = Nothing}, thVersion = v, thServerVRange = vr}
  where
    getServerHandshake :: ExceptT XFTPClientError IO XFTPServerHandshake
    getServerHandshake = do
      let helloReq = H.requestNoBody "POST" "/" []
      HTTP2Response {respBody = HTTP2Body {bodyHead = shsBody}} <-
        liftError' xftpClientError $ sendRequest c helloReq Nothing
      liftTransportErr (TEHandshake PARSE) . smpDecode =<< liftTransportErr TEBadBlock (C.unPad shsBody)
    processServerHandshake :: XFTPServerHandshake -> ExceptT XFTPClientError IO (VersionRangeXFTP, C.PublicKeyX25519)
    processServerHandshake XFTPServerHandshake {xftpVersionRange, sessionId = serverSessId, authPubKey = serverAuth} = do
      unless (sessionId == serverSessId) $ throwE $ PCETransportError TEBadSession
      case xftpVersionRange `compatibleVRange` serverVRange of
        Nothing -> throwE $ PCETransportError TEVersion
        Just (Compatible vr) ->
          fmap (vr,) . liftTransportErr (TEHandshake BAD_AUTH) $ do
            let (X.CertificateChain cert, exact) = serverAuth
            case cert of
              [_leaf, ca] | XV.Fingerprint kh == XV.getFingerprint ca X.HashSHA256 -> pure ()
              _ -> throwError "bad certificate"
            pubKey <- maybe (throwError "bad server key type") (`C.verifyX509` exact) serverKey
            C.x509ToPublic (pubKey, []) >>= C.pubKey
    sendClientHandshake :: XFTPClientHandshake -> ExceptT XFTPClientError IO ()
    sendClientHandshake chs = do
      chs' <- liftTransportErr TELargeMsg $ C.pad (smpEncode chs) xftpBlockSize
      let chsReq = H.requestBuilder "POST" "/" [] $ byteString chs'
      HTTP2Response {respBody = HTTP2Body {bodyHead}} <- liftError' xftpClientError $ sendRequest c chsReq Nothing
      unless (B.null bodyHead) $ throwE $ PCETransportError TEBadBlock
    liftTransportErr e = liftEitherWith (const $ PCETransportError e)

closeXFTPClient :: XFTPClient -> IO ()
closeXFTPClient XFTPClient {http2Client} = closeHTTP2Client http2Client

xftpClientServer :: XFTPClient -> String
xftpClientServer = B.unpack . strEncode . snd3 . transportSession
  where
    snd3 (_, s, _) = s

xftpTransportHost :: XFTPClient -> TransportHost
xftpTransportHost XFTPClient {http2Client = HTTP2Client {client_ = HClient {host}}} = host

xftpHTTP2Config :: TransportClientConfig -> XFTPClientConfig -> HTTP2ClientConfig
xftpHTTP2Config transportConfig XFTPClientConfig {xftpNetworkConfig = NetworkConfig {tcpConnectTimeout}} =
  defaultHTTP2ClientConfig
    { bodyHeadSize = xftpBlockSize,
      suportedTLSParams = defaultSupportedParams,
      connTimeout = tcpConnectTimeout,
      transportConfig
    }

xftpClientError :: HTTP2ClientError -> XFTPClientError
xftpClientError = \case
  HCResponseTimeout -> PCEResponseTimeout
  HCNetworkError -> PCENetworkError
  HCIOError e -> PCEIOError e

sendXFTPCommand :: forall p. FilePartyI p => XFTPClient -> C.APrivateAuthKey -> XFTPFileId -> FileCommand p -> Maybe XFTPChunkSpec -> ExceptT XFTPClientError IO (FileResponse, HTTP2Body)
sendXFTPCommand c@XFTPClient {thParams} pKey fId cmd chunkSpec_ = do
  -- TODO random corrId
  let corrIdUsedAsNonce = ""
  t <-
    liftEither . first PCETransportError $
      xftpEncodeAuthTransmission thParams pKey (corrIdUsedAsNonce, fId, FileCmd (sFileParty @p) cmd)
  sendXFTPTransmission c t chunkSpec_

sendXFTPTransmission :: XFTPClient -> ByteString -> Maybe XFTPChunkSpec -> ExceptT XFTPClientError IO (FileResponse, HTTP2Body)
sendXFTPTransmission XFTPClient {config, thParams, http2Client} t chunkSpec_ = do
  let req = H.requestStreaming N.methodPost "/" [] streamBody
      reqTimeout = xftpReqTimeout config $ (\XFTPChunkSpec {chunkSize} -> chunkSize) <$> chunkSpec_
  HTTP2Response {respBody = body@HTTP2Body {bodyHead}} <- withExceptT xftpClientError . ExceptT $ sendRequest http2Client req (Just reqTimeout)
  when (B.length bodyHead /= xftpBlockSize) $ throwE $ PCEResponseError BLOCK
  -- TODO validate that the file ID is the same as in the request?
  (_, _, (_, _fId, respOrErr)) <- liftEither . first PCEResponseError $ xftpDecodeTransmission thParams bodyHead
  case respOrErr of
    Right r -> case protocolError r of
      Just e -> throwE $ PCEProtocolError e
      _ -> pure (r, body)
    Left e -> throwE $ PCEResponseError e
  where
    streamBody :: (Builder -> IO ()) -> IO () -> IO ()
    streamBody send done = do
      send $ byteString t
      forM_ chunkSpec_ $ \XFTPChunkSpec {filePath, chunkOffset, chunkSize} ->
        withFile filePath ReadMode $ \h -> do
          hSeek h AbsoluteSeek $ fromIntegral chunkOffset
          hSendFile h send chunkSize
      done

createXFTPChunk ::
  XFTPClient ->
  C.APrivateAuthKey ->
  FileInfo ->
  NonEmpty C.APublicAuthKey ->
  Maybe BasicAuth ->
  ExceptT XFTPClientError IO (SenderId, NonEmpty RecipientId)
createXFTPChunk c spKey file rcps auth_ =
  sendXFTPCommand c spKey NoEntity (FNEW file rcps auth_) Nothing >>= \case
    (FRSndIds sId rIds, body) -> noFile body (sId, rIds)
    (r, _) -> throwE $ unexpectedResponse r

addXFTPRecipients :: XFTPClient -> C.APrivateAuthKey -> XFTPFileId -> NonEmpty C.APublicAuthKey -> ExceptT XFTPClientError IO (NonEmpty RecipientId)
addXFTPRecipients c spKey fId rcps =
  sendXFTPCommand c spKey fId (FADD rcps) Nothing >>= \case
    (FRRcvIds rIds, body) -> noFile body rIds
    (r, _) -> throwE $ unexpectedResponse r

uploadXFTPChunk :: XFTPClient -> C.APrivateAuthKey -> XFTPFileId -> XFTPChunkSpec -> ExceptT XFTPClientError IO ()
uploadXFTPChunk c spKey fId chunkSpec =
  sendXFTPCommand c spKey fId FPUT (Just chunkSpec) >>= okResponse

downloadXFTPChunk :: TVar ChaChaDRG -> XFTPClient -> C.APrivateAuthKey -> XFTPFileId -> XFTPRcvChunkSpec -> ExceptT XFTPClientError IO ()
downloadXFTPChunk g c@XFTPClient {config} rpKey fId chunkSpec@XFTPRcvChunkSpec {filePath, chunkSize} = do
  (rDhKey, rpDhKey) <- atomically $ C.generateKeyPair g
  sendXFTPCommand c rpKey fId (FGET rDhKey) Nothing >>= \case
    (FRFile sDhKey cbNonce, HTTP2Body {bodyHead = _bg, bodySize = _bs, bodyPart}) -> case bodyPart of
      -- TODO atm bodySize is set to 0, so chunkSize will be incorrect - validate once set
      Just chunkPart -> do
        let dhSecret = C.dh' sDhKey rpDhKey
        cbState <- liftEither . first PCECryptoError $ LC.cbInit dhSecret cbNonce
        let t = chunkTimeout config chunkSize
        ExceptT (sequence <$> (t `timeout` (download cbState `catches` errors))) >>= maybe (throwE PCEResponseTimeout) pure
        where
          errors =
            [ Handler $ \(_e :: H.HTTP2Error) -> pure $ Left PCENetworkError,
              Handler $ \(e :: IOException) -> pure $ Left (PCEIOError e),
              Handler $ \(_e :: SomeException) -> pure $ Left PCENetworkError
            ]
          download cbState =
            runExceptT . withExceptT PCEResponseError $
              receiveEncFile chunkPart cbState chunkSpec `catchError` \e ->
                whenM (doesFileExist filePath) (removeFile filePath) >> throwE e
      _ -> throwE $ PCEResponseError NO_FILE
    (r, _) -> throwE $ unexpectedResponse r

xftpReqTimeout :: XFTPClientConfig -> Maybe Word32 -> Int
xftpReqTimeout cfg@XFTPClientConfig {xftpNetworkConfig = NetworkConfig {tcpTimeout}} chunkSize_ =
  maybe tcpTimeout (chunkTimeout cfg) chunkSize_

chunkTimeout :: XFTPClientConfig -> Word32 -> Int
chunkTimeout XFTPClientConfig {xftpNetworkConfig = NetworkConfig {tcpTimeout, tcpTimeoutPerKb}} sz =
  tcpTimeout + fromIntegral (min ((fromIntegral sz `div` 1024) * tcpTimeoutPerKb) (fromIntegral (maxBound :: Int)))

deleteXFTPChunk :: XFTPClient -> C.APrivateAuthKey -> SenderId -> ExceptT XFTPClientError IO ()
deleteXFTPChunk c spKey sId = sendXFTPCommand c spKey sId FDEL Nothing >>= okResponse

ackXFTPChunk :: XFTPClient -> C.APrivateAuthKey -> RecipientId -> ExceptT XFTPClientError IO ()
ackXFTPChunk c rpKey rId = sendXFTPCommand c rpKey rId FACK Nothing >>= okResponse

pingXFTP :: XFTPClient -> ExceptT XFTPClientError IO ()
pingXFTP c@XFTPClient {thParams} = do
  t <-
    liftEither . first PCETransportError $
      xftpEncodeTransmission thParams ("", NoEntity, FileCmd SFRecipient PING)
  (r, _) <- sendXFTPTransmission c t Nothing
  case r of
    FRPong -> pure ()
    _ -> throwE $ unexpectedResponse r

okResponse :: (FileResponse, HTTP2Body) -> ExceptT XFTPClientError IO ()
okResponse = \case
  (FROk, body) -> noFile body ()
  (r, _) -> throwE $ unexpectedResponse r

-- TODO this currently does not check anything because response size is not set and bodyPart is always Just
noFile :: HTTP2Body -> a -> ExceptT XFTPClientError IO a
noFile HTTP2Body {bodyPart} a = case bodyPart of
  Just _ -> pure a -- throwE $ PCEResponseError HAS_FILE
  _ -> pure a

-- FACK :: FileCommand Recipient
-- PING :: FileCommand Recipient
