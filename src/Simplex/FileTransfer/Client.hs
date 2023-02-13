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
import Data.ByteString.Builder (Builder, byteString)
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.List.NonEmpty (NonEmpty (..))
import GHC.IO.IOMode (IOMode (ReadMode))
import qualified Network.HTTP.Types as N
import qualified Network.HTTP2.Client as H
import Simplex.FileTransfer.Protocol
import Simplex.Messaging.Client
  ( NetworkConfig (..),
    ProtocolClientError (..),
    TransportSession,
    chooseTransportHost,
    defaultNetworkConfig,
    proxyUsername,
    transportClientConfig,
  )
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Protocol
  ( ErrorType (..),
    ProtocolServer (ProtocolServer),
    RcvPublicDhKey,
    RecipientId,
    SenderId,
  )
import Simplex.Messaging.Transport (supportedParameters)
import Simplex.Messaging.Transport.Client (TransportClientConfig)
import Simplex.Messaging.Transport.HTTP2
import Simplex.Messaging.Transport.HTTP2.Client
import Simplex.Messaging.Util (bshow, liftEitherError)
import UnliftIO.IO (withFile)

data XFTPClient = XFTPClient
  { http2Client :: HTTP2Client,
    config :: XFTPClientConfig
  }

data XFTPClientConfig = XFTPClientConfig
  { networkConfig :: NetworkConfig
  }

data XFTPChunkBody = XFTPChunkBody
  { chunkSize :: Int,
    chunkPart :: Int -> IO ByteString,
    http2Body :: HTTP2Body
  }

defaultXFTPClientConfig :: XFTPClientConfig
defaultXFTPClientConfig = XFTPClientConfig {networkConfig = defaultNetworkConfig}

getXFTPClient :: TransportSession FileResponse -> XFTPClientConfig -> IO () -> IO (Either ProtocolClientError XFTPClient)
getXFTPClient transportSession@(_, srv, _) config@XFTPClientConfig {networkConfig} disconnected = runExceptT $ do
  let tcConfig = transportClientConfig networkConfig
      http2Config = xftpHTTP2Config tcConfig config
      username = proxyUsername transportSession
      ProtocolServer _ host port keyHash = srv
  useHost <- liftEither $ chooseTransportHost networkConfig host
  http2Client <- liftEitherError xftpClientError $ getVerifiedHTTP2Client (Just username) useHost port (Just keyHash) Nothing http2Config disconnected
  pure XFTPClient {http2Client, config}

xftpHTTP2Config :: TransportClientConfig -> XFTPClientConfig -> HTTP2ClientConfig
xftpHTTP2Config transportConfig XFTPClientConfig {networkConfig = NetworkConfig {tcpConnectTimeout}} =
  defaultHTTP2ClientConfig
    { bodyHeadSize = xftpBlockSize,
      suportedTLSParams = supportedParameters,
      connTimeout = tcpConnectTimeout,
      transportConfig
    }

xftpClientError :: HTTP2ClientError -> ProtocolClientError
xftpClientError = \case
  HCResponseTimeout -> PCEResponseTimeout
  HCNetworkError -> PCENetworkError
  HCIOError e -> PCEIOError e

sendXFTPCommand :: forall p. FilePartyI p => XFTPClient -> C.APrivateSignKey -> XFTPFileId -> FileCommand p -> Maybe FilePath -> ExceptT ProtocolClientError IO (FileResponse, HTTP2Body)
sendXFTPCommand XFTPClient {http2Client = http2@HTTP2Client {sessionId}} pKey fId cmd filePath_ = do
  t <-
    liftEither . first PCETransportError $
      xftpEncodeTransmission sessionId (Just pKey) ("", fId, FileCmd (sFileParty @p) cmd)
  let req = H.requestStreaming N.methodPost "/" [] $ streamBody t
  HTTP2Response {respBody = body@HTTP2Body {bodyHead}} <- liftEitherError xftpClientError $ sendRequestDirect http2 req
  when (B.length bodyHead /= xftpBlockSize) $ throwError $ PCEResponseError BLOCK
  -- TODO validate that the file ID is the same as in the request?
  (_, _, (_, _fId, respOrErr)) <- liftEither . first PCEResponseError $ xftpDecodeTransmission sessionId bodyHead
  case respOrErr of
    Right r -> pure (r, body)
    Left e -> throwError $ PCEResponseError e
  where
    streamBody :: ByteString -> (Builder -> IO ()) -> IO () -> IO ()
    streamBody t sendChunk done = do
      sendChunk $ byteString t
      forM_ filePath_ $ \path -> withFile path ReadMode sendFile
      done
      where
        sendFile h =
          B.hGet h xftpBlockSize >>= \case
            "" -> pure ()
            bs -> sendChunk (byteString bs) >> sendFile h

createXFTPChunk ::
  XFTPClient ->
  C.APrivateSignKey ->
  FileInfo ->
  NonEmpty C.APublicVerifyKey ->
  ExceptT ProtocolClientError IO (SenderId, NonEmpty RecipientId)
createXFTPChunk c spKey file rsps =
  sendXFTPCommand c spKey "" (FNEW file rsps) Nothing >>= \case
    -- TODO check that body is empty
    (FRSndIds sId rIds, _body) -> pure (sId, rIds)
    (r, _) -> throwError . PCEUnexpectedResponse $ bshow r

uploadXFTPChunk :: XFTPClient -> C.APrivateSignKey -> XFTPFileId -> FilePath -> ExceptT ProtocolClientError IO ()
uploadXFTPChunk c spKey fId filePath =
  sendXFTPCommand c spKey fId FPUT (Just filePath) >>= \case
    -- TODO check that body is empty
    (FROk, _body) -> pure ()
    (r, _) -> throwError . PCEUnexpectedResponse $ bshow r

downloadXFTPChunk :: XFTPClient -> C.APrivateSignKey -> XFTPFileId -> RcvPublicDhKey -> ExceptT ProtocolClientError IO XFTPChunkBody
downloadXFTPChunk c rpKey fId dhKey =
  sendXFTPCommand c rpKey fId (FGET dhKey) Nothing >>= \case
    (FROk, http2Body@HTTP2Body {bodyHead, bodySize, bodyPart}) -> case bodyPart of
      -- TODO atm bodySize is set to 0, so chunkSize will be incorrect
      Just chunkPart -> pure XFTPChunkBody {chunkSize = bodySize - B.length bodyHead, chunkPart, http2Body}
      _ -> throwError $ PCEResponseError NO_MSG
    (r, _) -> throwError . PCEUnexpectedResponse $ bshow r

-- FADD :: NonEmpty RcvPublicVerifyKey -> FileCommand Sender
-- FDEL :: FileCommand Sender
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
