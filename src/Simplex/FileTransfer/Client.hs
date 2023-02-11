{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

module Simplex.FileTransfer.Client where

import Control.Monad.Except
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString.Builder (lazyByteString)
import qualified Data.ByteString.Char8 as B
import Data.ByteString.Lazy (fromStrict)
import Data.List.NonEmpty (NonEmpty (..))
import qualified Network.HTTP.Types as N
import qualified Network.HTTP2.Client as H
import Simplex.FileTransfer.Protocol
import Simplex.Messaging.Client (ClientCommand, NetworkConfig (..), ProtocolClientError (..), TransportSession, chooseTransportHost, proxyUsername, transportClientConfig)
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Protocol (ErrorType (..), ProtocolServer (ProtocolServer), RecipientId, SenderId, SentRawTransmission, encodeTransmission, tDecodeParseValidate, tEncode, tEncodeBatch, tParse)
import Simplex.Messaging.Transport (TransportError (..), supportedParameters)
import Simplex.Messaging.Transport.Client (TransportClientConfig)
import Simplex.Messaging.Transport.HTTP2
import Simplex.Messaging.Transport.HTTP2.Client
import Simplex.Messaging.Util (bshow, liftEitherError)

data XFTPClient = XFTPClient
  { http2Client :: HTTP2Client,
    config :: XFTPClientConfig
  }

data XFTPClientConfig = XFTPClientConfig
  { networkConfig :: NetworkConfig,
    blockSize :: Int
  }

getXFTPClient :: TransportSession FileResponse -> XFTPClientConfig -> IO () -> IO (Either ProtocolClientError XFTPClient)
getXFTPClient transportSession@(_, srv, _) config@XFTPClientConfig {networkConfig} disconnected = runExceptT $ do
  let tcConfig = transportClientConfig networkConfig
      http2Config = xftpHTTP2Config networkConfig tcConfig config
      username = proxyUsername transportSession
      ProtocolServer _ host port keyHash = srv
  useHost <- liftEither $ chooseTransportHost networkConfig host
  http2Client <- liftEitherError xftpClientError $ getVerifiedHTTP2Client (Just username) useHost port (Just keyHash) Nothing http2Config disconnected
  pure XFTPClient {http2Client, config}

xftpHTTP2Config :: NetworkConfig -> TransportClientConfig -> XFTPClientConfig -> HTTP2ClientConfig
xftpHTTP2Config NetworkConfig {tcpConnectTimeout} transportConfig XFTPClientConfig {blockSize} =
  defaultHTTP2ClientConfig
    { bodyHeadSize = blockSize,
      suportedTLSParams = supportedParameters,
      connTimeout = tcpConnectTimeout,
      transportConfig
    }

xftpClientError :: HTTP2ClientError -> ProtocolClientError
xftpClientError = \case
  HCResponseTimeout -> PCEResponseTimeout
  HCNetworkError -> PCENetworkError
  HCIOError e -> PCEIOError e

sendXFTPCommand :: forall p. FilePartyI p => XFTPClient -> Maybe C.APrivateSignKey -> XFTPFileId -> FileCommand p -> Maybe FilePath -> ExceptT ProtocolClientError IO (FileResponse, HTTP2Body)
sendXFTPCommand c@XFTPClient {http2Client = http2@HTTP2Client {sessionId}, config = XFTPClientConfig {blockSize}} pKey fId cmd filePath_ = do
  t <- xftpTransmission c (pKey, fId, FileCmd (sFileParty @p) cmd)
  -- TODO add file to request body, as lazy bytestring
  let req = H.requestBuilder N.methodPost "/" [] (lazyByteString $ fromStrict t)
  HTTP2Response {respBody = body@HTTP2Body {bodyHead, bodySize}} <- liftEitherError xftpClientError $ sendRequest http2 req
  when (bodySize < blockSize || B.length bodyHead /= blockSize) $ throwError $ PCEResponseError BLOCK
  case tParse True bodyHead of
    resp :| [] -> do
      -- TODO validate that the file ID is the same as in the request?
      let (_, _, (_, _fId, respOrErr)) = tDecodeParseValidate sessionId currentXFTPVersion resp
      case respOrErr of
        Right r -> pure (r, body)
        Left e -> throwError $ PCEResponseError e
    _ -> throwError $ PCEResponseError BLOCK

xftpTransmission :: XFTPClient -> ClientCommand FileResponse -> ExceptT ProtocolClientError IO ByteString
xftpTransmission XFTPClient {http2Client = HTTP2Client {sessionId}, config = XFTPClientConfig {blockSize}} (pKey, fId, cmd) = do
  let t = encodeTransmission currentXFTPVersion sessionId ("", fId, cmd)
      t' = tEncodeBatch 1 . tEncode $ signTransmission t
  liftEither . first (const $ PCETransportError TELargeMsg) $ C.pad t' blockSize
  where
    signTransmission :: ByteString -> SentRawTransmission
    signTransmission t = ((`C.sign` t) <$> pKey, t)

createXFTPChunk ::
  XFTPClient ->
  C.APrivateSignKey ->
  FileInfo ->
  NonEmpty C.APublicVerifyKey ->
  ExceptT ProtocolClientError IO (SenderId, NonEmpty RecipientId)
createXFTPChunk c spKey file rsps =
  sendXFTPCommand c (Just spKey) "" (FNEW file rsps) Nothing >>= \case
    -- TODO check that body is empty
    (FRSndIds sId rIds, _body) -> pure (sId, rIds)
    (r, _) -> throwError . PCEUnexpectedResponse $ bshow r

-- FNEW :: FileInfo -> NonEmpty RcvPublicVerifyKey -> FileCommand Sender
-- FADD :: NonEmpty RcvPublicVerifyKey -> FileCommand Sender
-- FPUT :: FileCommand Sender
-- FDEL :: FileCommand Sender
-- FGET :: RcvPublicDhKey -> FileCommand Recipient
-- FACK :: FileCommand Recipient
-- PING :: FileCommand Recipient

{- createHTTPS2Request :: FileRequest -> IO Request
createHTTPS2Request fileReq = do
  pure $ H.requestBuilder N.methodPost path headers (lazyByteString $ J.encode fileReq)
  where
    path = "/file/"
    headers = []
 -}
-- createFileHTTPS2Request :: FilePath -> IO Request
-- createFileHTTPS2Request f = do
--   fileSize <- getFileSize f
--   let fileSizeInt64 = fromInteger (fromMaybe 0 fileSize)
--   pure $ H.requestFile N.methodPost path headers (FileSpec f 0 fileSizeInt64)
--   where
--     path = "/file/"
--     headers = []

-- getFileSize :: FilePath -> IO (Maybe Integer)
-- getFileSize path =
--   handle handler $
--     withFile
--       path
--       ReadMode
--       ( \h -> do
--           size <- hFileSize h
--           return $ Just size
--       )
--   where
--     handler :: SomeException -> IO (Maybe Integer)
--     handler _ = return Nothing

-- {-

-- processUpload :: IO ()
-- processUpload = do
--   client <- createFileClient "localhost" defaultHTTP2ClientConfig
--   c <- readTVarIO (https2Client client)
--   case c of
--     Just http2 -> do
--       (sPub, sKey) <- C.generateSignatureKeyPair C.SEd25519
--       (rPub, rKey) <- C.generateSignatureKeyPair C.SEd25519
--       let fileSize = 10000
--       resp <- addFile http2 (sPub, sKey) (fromList [rPub]) fileSize
--       case resp of
--         Just (FRChunkIds sChunkId rChunkIds)  ->  do
--           file <- readFileToUpload "tempFile"
--           _ <- uploadFile http2 sChunkId (sPub, sKey) file
--           print "Done all"
--         _ -> pure ()
--       print "Done"
--     _ -> print "No client"
--   pure ()

-- addFile :: HTTP2Client -> (SndPublicVerifyKey, APrivateSignKey) -> NonEmpty RcvPublicVerifyKey -> Word32 -> IO (Maybe FileResponse)
-- addFile http2 (senderPubKey, _senderPrivKey) recipientKeys fileSize = do
--   let new = FileReqNew NewFileRec {senderPubKey, recipientKeys, fileSize}
--   req <- liftIO $ createHTTPS2Request new
--   -- createAndSecureQueue
--   sendRequest (http2 :: HTTP2Client) req >>= \case
--     Right (HTTP2Response response respBody _) -> do
--       let status = H.responseStatus response
--           -- decodedBody = J.decodeStrict' respBody
--       logDebug $ "File response: " <> T.pack (show status)
--       print "Done"
--     Left _ -> do
--       print "Error"
--   pure Nothing

-- readFileToUpload :: FilePath -> IO ByteString
-- readFileToUpload = B.readFile

--  uploadFile :: HTTP2Client -> FileChunkId -> (SndPublicVerifyKey, APrivateSignKey) -> ByteString -> IO (Maybe FileResponse)
-- uploadFile http2 chunkId (_senderPubKey, senderPrivKey) file = do
--   let upload = FileReqCmd (bs chunkId) chunkId FPUT
--   req <- liftIO $ createHTTPS2Request upload
--   -- createAndSecureQueue
--   sendRequest (http2 :: HTTP2Client) req >>= \case
--     Right (HTTP2Response response respBody _) -> do
--       let status = H.responseStatus response
--           -- decodedBody = J.decodeStrict' respBody
--       logDebug $ "File response: " <> T.pack (show status)
--       print "Done"
--     Left _ -> do
--       print "Error"
--   pure Nothing
--  -}

-- processUpload :: IO ()
-- processUpload = do
--   client <-
--     createFileClient
--       "localhost"
--       HTTP2ClientConfig
--         { qSize = 64,
--           connTimeout = 10000000,
--           transportConfig = TransportClientConfig Nothing Nothing True,
--           bufferSize = 16384,
--           suportedTLSParams = http2TLSParams
--         }
--   c <- readTVarIO (https2Client client)
--   case c of
--     Just http2 -> do
--       _ <- uploadFile http2 "tempFile"
--       print "Done"
--     _ -> print "No client"
--   pure ()

-- uploadFile :: HTTP2Client -> FilePath -> IO (Maybe FileResponse)
-- uploadFile http2 f = do
--   req <- liftIO $ createFileHTTPS2Request f
--   -- createAndSecureQueue
--   sendRequest (http2 :: HTTP2Client) req >>= \case
--     Right (HTTP2Response response HTTP2Body {bodyHead}) -> do
--       let status = H.responseStatus response
--       -- decodedBody = J.decodeStrict' respBody
--       logDebug $ "File response: " <> T.pack (show status)
--       print "Done"
--     Left _ -> do
--       print "Error"
--   pure Nothing
