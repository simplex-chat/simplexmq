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

data CliCommand
  = UploadFile UploadOptions
  | DownloadFile DownloadOptions

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

uploadFile :: FilePath -> Int -> IO [FileDescription]
uploadFile file numRecipients = do
  r <- runExceptT $ uploadFile' file numRecipients
  case r of
    Left e -> putStrLn ("Failed to upload file: " <> e) >> pure []
    Right fds -> pure fds

uploadFile' :: FilePath -> Int -> ExceptT String IO [FileDescription]
uploadFile' file numRecipients = do
  -- create XFTPClient for upload
  -- encrypt file
  -- split file into chunks
  -- create chunks on servers, get sndIds & rcvIds
  -- upload chunks to servers via sndIds
  -- create n file descriptions with rcvIds
  pure []

cliDownloadFile :: FilePath -> FilePath -> IO ()
cliDownloadFile fileDescription fileDest = do
  r <- strDecode <$> B.readFile fileDescription
  case r of
    Left e -> putStrLn $ "Failed to parse file description: " <> e
    Right fd -> downloadFile fd fileDest

downloadFile :: FileDescription -> FilePath -> IO ()
downloadFile fd fileDest = do
  r <- runExceptT $ downloadFile' fd fileDest
  case r of
    Left e -> putStrLn $ "Failed to download file: " <> e
    Right () -> putStrLn "File downloaded successfully"

downloadFile' :: FileDescription -> FilePath -> ExceptT String IO ()
downloadFile' fd@FileDescription {chunks} fileDest = do
  -- create XFTPClient for download
  forM_ chunks $ \fc -> downloadFileChunk fd fc fileDest

downloadFileChunk :: FileDescription -> FileChunk -> FilePath -> ExceptT String IO ()
downloadFileChunk FileDescription {key, iv} FileChunk {replicas = replica : _} fileDest = do
  chunk <- downloadReplica replica
  chunk' <- decryptChunk chunk
  verifyChunkDigest chunk'
  writeChunk chunk'
  where
    downloadReplica :: FileChunkReplica -> ExceptT String IO ByteString
    downloadReplica FileChunkReplica {server, rcvId, rcvKey} = undefined -- download chunk from server using XFTPClient
    decryptChunk :: ByteString -> ExceptT String IO ByteString
    decryptChunk = undefined
    verifyChunkDigest :: ByteString -> ExceptT String IO ()
    verifyChunkDigest = undefined
    writeChunk :: ByteString -> ExceptT String IO ()
    writeChunk = undefined
downloadFileChunk _ _ _ = throwError "No replicas"
