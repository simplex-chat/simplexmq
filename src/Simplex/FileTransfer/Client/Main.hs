{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

module Simplex.FileTransfer.Client.Main
  ( xftpClientCLI,
    uploadFile,
    downloadFile,
  )
where

import Control.Concurrent.STM (atomically)
import Control.Monad
import Control.Monad.Except (runExceptT)
import Crypto.Random (getRandomBytes)
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import qualified Data.ByteString.Lazy.Char8 as LB
import Data.List.NonEmpty (NonEmpty)
import Options.Applicative
import Simplex.FileTransfer.Client.Agent
import Simplex.FileTransfer.Description
import Simplex.Messaging.Agent.Lock
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Encoding.String (StrEncoding (..))
import Simplex.Messaging.Protocol (RecipientId, SenderId)
import Simplex.Messaging.Server.CLI (getCliCommand')

xftpClientVersion :: String
xftpClientVersion = "0.1.0"

data CliCommand
  = UploadFile UploadOptions
  | DownloadFile DownloadOptions
  | RandomFile RandomFileOptions

data UploadOptions = UploadOptions
  { filePath :: FilePath,
    tmpPath :: FilePath,
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
  { size :: Int,
    path :: FilePath
  }
  deriving (Show)

cliCommandP :: Parser CliCommand
cliCommandP =
  hsubparser
    ( command "upload" (info (UploadFile <$> uploadP) (progDesc "Upload file"))
        <> command "download" (info (DownloadFile <$> downloadP) (progDesc "Download file"))
        <> command "random" (info (RandomFile <$> randomP) (progDesc "Generate a random file"))
    )
  where
    uploadP :: Parser UploadOptions
    uploadP =
      UploadOptions
        <$> strOption (long "file" <> short 'f' <> metavar "FILE" <> help "File to upload")
        <*> strOption (long "tmp" <> short 't' <> metavar "DIR" <> help "Directory to save temporary encrypted file" <> value "/tmp")
        <*> option
          auto
          (long "num" <> short 'n' <> metavar "NUM" <> help "Number of recipients" <> value 1)
        <*> strOption (long "desc-dir" <> short 'd' <> metavar "DIR" <> help "Directory to save file descriptions")
    downloadP :: Parser DownloadOptions
    downloadP =
      DownloadOptions
        <$> strOption (long "desc" <> short 'd' <> metavar "DESC" <> help "File description")
        <*> strOption (long "output" <> short 'o' <> metavar "FILE" <> help "Path to save file")
    randomP :: Parser RandomFileOptions
    randomP =
      RandomFileOptions
        <$> option
          auto
          (long "size" <> short 's' <> metavar "SIZE" <> help "File size in megabytes" <> value 8)
        <*> strOption (long "output" <> short 'o' <> metavar "FILE" <> help "Path to save file" <> value "./random.bin")

xftpClientCLI :: IO ()
xftpClientCLI =
  getCliCommand' cliCommandP clientVersion >>= \case
    UploadFile UploadOptions {filePath, tmpPath, numRecipients, fileDescriptionsDest} -> cliUploadFile filePath tmpPath numRecipients fileDescriptionsDest
    DownloadFile DownloadOptions {fileDescription, fileDest} -> cliDownloadFile fileDescription fileDest
    RandomFile RandomFileOptions {size, path} -> cliRandomFile size path
  where
    clientVersion = "SimpleX XFTP client v" <> xftpClientVersion

cliUploadFile :: FilePath -> FilePath -> Int -> FilePath -> IO ()
cliUploadFile filePath tmpPath numRecipients fileDescriptionsDest = do
  fds <- uploadFile filePath tmpPath numRecipients
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
    computeFileDigest = C.sha256Hashlazy <$> LB.readFile filePath
    encryptFile :: IO (FilePath, C.Key, C.IV)
    encryptFile = undefined
    uploadFileChunk :: XFTPClientAgent -> Int -> IO (SenderId, NonEmpty RecipientId)
    uploadFileChunk c chunkNo = do
      -- generate recipient keys
      -- register chunk on the server - createXFTPChunk
      -- upload chunk to server - uploadXFTPChunk
      undefined

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
  xftp <- runExceptT $ getXFTPServerClient c server
  -- create XFTPClient for download, put it to map, disconnect should remove from map
  -- download and decrypt (DH) chunk from server using XFTPClient
  -- verify chunk digest - in the client
  withLock writeLock "save" $ pure ()
  where
    --   save to correct location in file - also in the client

    downloadReplica :: FileChunkReplica -> IO ByteString
    downloadReplica FileChunkReplica {server, rcvId, rcvKey} = undefined -- download chunk from server using XFTPClient
    verifyChunkDigest :: ByteString -> IO ()
    verifyChunkDigest = undefined
    writeChunk :: ByteString -> IO ()
    writeChunk = undefined
downloadFileChunk _ _ _ _ _ = pure ()

cliRandomFile :: Int -> FilePath -> IO ()
cliRandomFile size path = do
  bytes <- getRandomBytes (size * 1024 * 1024)
  B.writeFile path bytes