{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

module Simplex.FileTransfer.Client.Main
  ( fileClientCLI,
    uploadFile,
    downloadFile,
  )
where

import Control.Monad
import Control.Monad.Except (ExceptT, MonadError (throwError), runExceptT)
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Options.Applicative
import Simplex.FileTransfer.Description
import Simplex.Messaging.Encoding.String (StrEncoding (..))
import Simplex.Messaging.Agent.Lock
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Protocol (SenderId, RecipientId)
import Data.List.NonEmpty (NonEmpty)
import Simplex.FileTransfer.Client.Agent

data CliCommand
  = UploadFile UploadOptions
  | DownloadFile DownloadOptions
  | RandomFile RandomFileOptions

data UploadOptions = UploadOptions
  { file :: FilePath,
    numRecipients :: Int,
    fileDescriptionsDest :: FilePath
  }
  deriving (Show)

data DownloadOptions = DownloadOptions
  { fileDescription :: FilePath,
    fileDest :: FilePath
  }
  deriving (Show)

data RandomFileOptions = RandomFileOptions
  { size :: Int
  }
  deriving (Show)

cliCommandP :: Parser CliCommand
cliCommandP = undefined

getCliCommand :: IO CliCommand
getCliCommand = execParser $ info (cliCommandP <**> helper) fullDesc

fileClientCLI :: IO ()
fileClientCLI =
  getCliCommand >>= \case
    UploadFile UploadOptions {file, numRecipients, fileDescriptionsDest} -> cliUploadFile file numRecipients fileDescriptionsDest
    DownloadFile DownloadOptions {fileDescription, fileDest} -> cliDownloadFile fileDescription fileDest

cliUploadFile :: FilePath -> Int -> FilePath -> IO ()
cliUploadFile file numRecipients fileDescriptionsDest = do
  fds <- uploadFile file numRecipients
  writeFileDescriptions fileDescriptionsDest fds

writeFileDescriptions :: FilePath -> [FileDescription] -> IO ()
writeFileDescriptions fileDescriptionsDest fds = do
  forM_ fds $ \fd -> do
    let fdPath = fileDescriptionsDest <> "/" <> "..."
    B.writeFile fdPath (strEncode fd)

uploadFile :: FilePath -> FilePath -> Int -> IO [FileDescription]
uploadFile filePath tmpPath numRecipients = do
  digest <- computeFileDigest
  (encPath, key, iv) <- encryptFile
  c <- atomically newXFTPAgent
  -- concurrently: register and upload chunks to servers, get sndIds & rcvIds
  -- create/pivot n file descriptions with rcvIds
  -- save descriptions as files
  pure []
  where
    computeFileDigest :: IO ByteString
    computeFileDigest = undefined
    encryptFile :: IO (FilePath, C.Key, C.IV)
    encryptFile = undefined
    uploadFileChunk :: XFTPClientAgent -> Int -> IO (SenderId, NonEmpty RecipientId)
    uploadFileChunk c chunkNo = do
      -- generate recipient keys
      -- register chunk on the server - createXFTPChunk
      -- upload chunk to server - uploadXFTPChunk

cliDownloadFile :: FilePath -> FilePath -> IO ()
cliDownloadFile fileDescription fileDest = do
  r <- strDecode <$> B.readFile fileDescription
  case r of
    Left e -> putStrLn $ "Failed to parse file description: " <> e
    Right fd -> downloadFile fd fileDest

downloadFile :: FileDescription -> FilePath -> IO ()
downloadFile fd@FileDescription {chunks} fileDest = do
  -- create empty file
  c <- atomically newXFTPAgent
  writeLock <- atomically createLock
  -- download chunks concurrently - accept write lock
  -- forM_ chunks $ \fc -> downloadFileChunk fd fc fileDest
  -- decrypt file
  -- verify file digest
  pure ()

createDownloadFile :: FileDescription -> FilePath -> IO ()
createDownloadFile FileDescription {size} fileDest = do
  -- create empty file
  -- can fail if no space or path does not exist
  pure ()

downloadFileChunk :: XFTPClientAgent -> Lock -> FileDescription -> FileChunk -> FilePath -> IO ()
downloadFileChunk c writeLock FileDescription {key, iv} FileChunk {replicas = FileChunkReplica {server} : _} fileDest = do
  xftp <- getXFTPServerClient c server
  -- create XFTPClient for download, put it to map, disconnect should remove from map
  -- download and decrypt (DH) chunk from server using XFTPClient
  -- verify chunk digest - in the client
  withLock writeLock "save" $ pure ()
  --   save to correct location in file - also in the client
  where
    downloadReplica :: FileChunkReplica -> IO ByteString
    downloadReplica FileChunkReplica {server, rcvId, rcvKey} = undefined -- download chunk from server using XFTPClient
    verifyChunkDigest :: ByteString -> IO ()
    verifyChunkDigest = undefined
    writeChunk :: ByteString -> IO ()
    writeChunk = undefined
downloadFileChunk _ _ _ = throwError "No replicas"
