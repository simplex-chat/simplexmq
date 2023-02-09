{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

module Simplex.FileTransfer.Client where

import Control.Arrow (first)
import Control.Concurrent.STM (TVar, newTVarIO, readTVar, readTVarIO)
import Control.Concurrent.STM.TVar (writeTVar)
import Control.Exception (SomeException, bracket)
import Control.Exception.Base (handle)
import Control.Logger.Simple (logDebug)
import Control.Monad.Except
import Control.Monad.STM (atomically)
import Control.Monad.Trans.Except
import qualified Data.Aeson as J
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import Data.ByteString.Builder (lazyByteString)
import Data.List.NonEmpty (NonEmpty, fromList, nonEmpty)
import Data.Maybe (isNothing)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Word (Word16)
import Foreign (Word32)
import GHC.IO.Handle (hFileSize)
import GHC.IO.IOMode (IOMode (..))
import Network.HTTP.Types (Status)
import qualified Network.HTTP.Types as N
import Network.HTTP2.Client (FileSpec (..), Request)
import qualified Network.HTTP2.Client as H
import Network.HTTP2.Server (Response)
import Network.Socket (ServiceName)
import Network.TLS (HostName)
import Simplex.FileTransfer.Protocol (FileCmd (FileCmd), FileCommand (FPUT), FilePartyI, FileResponse (..), SFileParty (SSender))
import Simplex.FileTransfer.Server.Env (FileRequest (..))
-- import Simplex.FileTransfer.Server.Store (NewFileRec (..))
import Simplex.Messaging.Client hiding (qSize)
import Simplex.Messaging.Crypto (APrivateSignKey)
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Encoding.String (StrEncoding (strDecode))
import Simplex.Messaging.Notifications.Protocol
import Simplex.Messaging.Protocol (QueueId, RcvPublicVerifyKey, SndPublicVerifyKey, bs)
import Simplex.Messaging.Transport.Client (TransportClientConfig (..))
import Simplex.Messaging.Transport.HTTP2 (HTTP2Body (..), http2TLSParams)
import Simplex.Messaging.Transport.HTTP2.Client (HTTP2Client, HTTP2ClientConfig (..), HTTP2ClientError, HTTP2Response (HTTP2Response), defaultHTTP2ClientConfig, getHTTP2Client, respBody, response, sendRequest)
import Simplex.Messaging.Util (bshow)
import System.Directory.Internal.Prelude (fromMaybe)
import System.IO (withFile)

type FileClient = ProtocolClient FileResponse

data FileHTTP2Client = FileHTTP2Client
  { https2Client :: TVar (Maybe HTTP2Client)
  }

createFileClient :: HostName -> HTTP2ClientConfig -> IO FileHTTP2Client
createFileClient host cfg = do
  https2Client <- newTVarIO Nothing
  void $ connectHTTPS2 host "1234" cfg https2Client
  pure FileHTTP2Client {https2Client}

connectHTTPS2 :: HostName -> ServiceName -> HTTP2ClientConfig -> TVar (Maybe HTTP2Client) -> IO (Either HTTP2ClientError HTTP2Client)
connectHTTPS2 host port http2cfg https2Client = do
  r <- getHTTP2Client host port Nothing http2cfg disconnected
  case r of
    Right client -> atomically . writeTVar https2Client $ Just client
    Left e -> putStrLn $ "Error connecting to host: " <> show e
  pure r
  where
    disconnected = atomically $ writeTVar https2Client Nothing

{- createHTTPS2Request :: FileRequest -> IO Request
createHTTPS2Request fileReq = do
  pure $ H.requestBuilder N.methodPost path headers (lazyByteString $ J.encode fileReq)
  where
    path = "/file/"
    headers = []
 -}
createFileHTTPS2Request :: FilePath -> IO Request
createFileHTTPS2Request f = do
  fileSize <- getFileSize f
  let fileSizeInt64 = fromInteger (fromMaybe 0 fileSize)
  pure $ H.requestFile N.methodPost path headers (FileSpec f 0 fileSizeInt64)
  where
    path = "/file/"
    headers = []

getFileSize :: FilePath -> IO (Maybe Integer)
getFileSize path =
  handle handler $
    withFile
      path
      ReadMode
      ( \h -> do
          size <- hFileSize h
          return $ Just size
      )
  where
    handler :: SomeException -> IO (Maybe Integer)
    handler _ = return Nothing

{-

processUpload :: IO ()
processUpload = do
  client <- createFileClient "localhost" defaultHTTP2ClientConfig
  c <- readTVarIO (https2Client client)
  case c of
    Just http2 -> do
      (sPub, sKey) <- C.generateSignatureKeyPair C.SEd25519
      (rPub, rKey) <- C.generateSignatureKeyPair C.SEd25519
      let fileSize = 10000
      resp <- addFile http2 (sPub, sKey) (fromList [rPub]) fileSize
      case resp of
        Just (FRChunkIds sChunkId rChunkIds)  ->  do
          file <- readFileToUpload "tempFile"
          _ <- uploadFile http2 sChunkId (sPub, sKey) file
          print "Done all"
        _ -> pure ()
      print "Done"
    _ -> print "No client"
  pure ()

addFile :: HTTP2Client -> (SndPublicVerifyKey, APrivateSignKey) -> NonEmpty RcvPublicVerifyKey -> Word32 -> IO (Maybe FileResponse)
addFile http2 (senderPubKey, _senderPrivKey) recipientKeys fileSize = do
  let new = FileReqNew NewFileRec {senderPubKey, recipientKeys, fileSize}
  req <- liftIO $ createHTTPS2Request new
  -- createAndSecureQueue
  sendRequest (http2 :: HTTP2Client) req >>= \case
    Right (HTTP2Response response respBody _) -> do
      let status = H.responseStatus response
          -- decodedBody = J.decodeStrict' respBody
      logDebug $ "File response: " <> T.pack (show status)
      print "Done"
    Left _ -> do
      print "Error"
  pure Nothing

readFileToUpload :: FilePath -> IO ByteString
readFileToUpload = B.readFile

 uploadFile :: HTTP2Client -> FileChunkId -> (SndPublicVerifyKey, APrivateSignKey) -> ByteString -> IO (Maybe FileResponse)
uploadFile http2 chunkId (_senderPubKey, senderPrivKey) file = do
  let upload = FileReqCmd (bs chunkId) chunkId FPUT
  req <- liftIO $ createHTTPS2Request upload
  -- createAndSecureQueue
  sendRequest (http2 :: HTTP2Client) req >>= \case
    Right (HTTP2Response response respBody _) -> do
      let status = H.responseStatus response
          -- decodedBody = J.decodeStrict' respBody
      logDebug $ "File response: " <> T.pack (show status)
      print "Done"
    Left _ -> do
      print "Error"
  pure Nothing
 -}

processUpload :: IO ()
processUpload = do
  client <-
    createFileClient
      "localhost"
      HTTP2ClientConfig
        { qSize = 64,
          connTimeout = 10000000,
          transportConfig = TransportClientConfig Nothing Nothing True,
          bufferSize = 16384,
          suportedTLSParams = http2TLSParams
        }
  c <- readTVarIO (https2Client client)
  case c of
    Just http2 -> do
      _ <- uploadFile http2 "tempFile"
      print "Done"
    _ -> print "No client"
  pure ()

uploadFile :: HTTP2Client -> FilePath -> IO (Maybe FileResponse)
uploadFile http2 f = do
  req <- liftIO $ createFileHTTPS2Request f
  -- createAndSecureQueue
  sendRequest (http2 :: HTTP2Client) req >>= \case
    Right (HTTP2Response response HTTP2Body {bodyHead}) -> do
      let status = H.responseStatus response
      -- decodedBody = J.decodeStrict' respBody
      logDebug $ "File response: " <> T.pack (show status)
      print "Done"
    Left _ -> do
      print "Error"
  pure Nothing
