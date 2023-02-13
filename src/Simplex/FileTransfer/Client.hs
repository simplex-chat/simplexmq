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
import Data.Int (Int64)
import Data.List.NonEmpty (NonEmpty (..))
import qualified Network.HTTP.Types as N
import qualified Network.HTTP2.Client as H
import Simplex.FileTransfer.Protocol
import Simplex.FileTransfer.Transport (receveFile, sendFile)
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
import System.IO (IOMode (..), SeekMode (..))
import UnliftIO.IO (hSeek, withFile)

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

data XFTPChunkSpec = XFTPChunkSpec
  { filePath :: FilePath,
    chunkOffset :: Int64,
    chunkSize :: Int
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

sendXFTPCommand :: forall p. FilePartyI p => XFTPClient -> C.APrivateSignKey -> XFTPFileId -> FileCommand p -> Maybe XFTPChunkSpec -> ExceptT ProtocolClientError IO (FileResponse, HTTP2Body)
sendXFTPCommand XFTPClient {http2Client = http2@HTTP2Client {sessionId}} pKey fId cmd chunkSpec_ = do
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
    streamBody t send done = do
      send $ byteString t
      forM_ chunkSpec_ $ \XFTPChunkSpec {filePath, chunkOffset, chunkSize} ->
        withFile filePath ReadMode $ \h -> do
          hSeek h AbsoluteSeek $ fromIntegral chunkOffset
          sendFile h send chunkSize
      done

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

uploadXFTPChunk :: XFTPClient -> C.APrivateSignKey -> XFTPFileId -> XFTPChunkSpec -> ExceptT ProtocolClientError IO ()
uploadXFTPChunk c spKey fId chunkSpec =
  sendXFTPCommand c spKey fId FPUT (Just chunkSpec) >>= \case
    -- TODO check that body is empty
    (FROk, _body) -> pure ()
    (r, _) -> throwError . PCEUnexpectedResponse $ bshow r

downloadXFTPChunk :: XFTPClient -> C.APrivateSignKey -> XFTPFileId -> RcvPublicDhKey -> ExceptT ProtocolClientError IO (RcvPublicDhKey, XFTPChunkBody)
downloadXFTPChunk c rpKey fId rKey =
  sendXFTPCommand c rpKey fId (FGET rKey) Nothing >>= \case
    (FRFile sKey, http2Body@HTTP2Body {bodyHead, bodySize, bodyPart}) -> case bodyPart of
      -- TODO atm bodySize is set to 0, so chunkSize will be incorrect
      Just chunkPart -> do
        let chunk = XFTPChunkBody {chunkSize = bodySize - B.length bodyHead, chunkPart, http2Body}
        pure (sKey, chunk)
      _ -> throwError $ PCEResponseError NO_MSG
    (r, _) -> throwError . PCEUnexpectedResponse $ bshow r

receiveXFTPChunk :: XFTPChunkBody -> XFTPChunkSpec -> ExceptT ProtocolClientError IO ()
receiveXFTPChunk XFTPChunkBody {chunkPart} XFTPChunkSpec {filePath, chunkOffset, chunkSize} = liftIO $ do
  withFile filePath WriteMode $ \h -> do
    hSeek h AbsoluteSeek $ fromIntegral chunkOffset
    -- TODO chunk decryption
    void $ receveFile h chunkPart 0

-- FADD :: NonEmpty RcvPublicVerifyKey -> FileCommand Sender
-- FDEL :: FileCommand Sender
-- FACK :: FileCommand Recipient
-- PING :: FileCommand Recipient
