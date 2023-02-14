{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Simplex.FileTransfer.Client.Main
  ( xftpClientCLI,
    sendFile,
    receiveFile,
  )
where

import Control.Concurrent.STM (atomically)
import Control.Monad
import Control.Monad.Except (runExceptT)
import Crypto.Random (getRandomBytes)
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import qualified Data.ByteString.Lazy.Char8 as LB
import Data.Int (Int64)
import Data.List.NonEmpty (NonEmpty)
import Data.Maybe (fromMaybe)
import Data.Word (Word32)
import Options.Applicative
import Simplex.FileTransfer.Client.Agent
import Simplex.FileTransfer.Description
import Simplex.Messaging.Agent.Lock
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Encoding.String (StrEncoding (..))
import Simplex.Messaging.Protocol (RecipientId, SenderId, XFTPServer)
import Simplex.Messaging.Server.CLI (getCliCommand')
import System.Directory (getFileSize)
import System.FilePath (takeFileName)
import System.IO (IOMode (..), withFile)

xftpClientVersion :: String
xftpClientVersion = "0.1.0"

data CliCommand
  = SendFile SendOptions
  | ReceiveFile ReceiveOptions
  | RandomFile RandomFileOptions

data SendOptions = SendOptions
  { filePath :: FilePath,
    outputDir :: Maybe FilePath,
    numRecipients :: Int,
    tempPath :: Maybe FilePath
  }
  deriving (Show)

data ReceiveOptions = ReceiveOptions
  { fileDescription :: FilePath,
    filePath :: Maybe FilePath
  }
  deriving (Show)

data RandomFileOptions = RandomFileOptions
  { filePath :: FilePath,
    fileSize :: FileSize Int
  }
  deriving (Show)

cliCommandP :: Parser CliCommand
cliCommandP =
  hsubparser
    ( command "send" (info (SendFile <$> sendP) (progDesc "Send file"))
        <> command "recv" (info (ReceiveFile <$> receiveP) (progDesc "Receive file"))
        <> command "rand" (info (RandomFile <$> randomP) (progDesc "Generate a random file of a given size"))
    )
  where
    sendP :: Parser SendOptions
    sendP =
      SendOptions
        <$> argument str (metavar "FILE" <> help "File to send")
        <*> optional (argument str $ metavar "DIR" <> help "Directory to save file descriptions (default: current directory)")
        <*> option auto (short 'n' <> metavar "COUNT" <> help "Number of recipients" <> value 1 <> showDefault)
        <*> optional (strOption $ long "temp" <> metavar "TEMP" <> help "Directory for temporary encrypted file (default: system temp directory)")
    receiveP :: Parser ReceiveOptions
    receiveP =
      ReceiveOptions
        <$> argument str (metavar "FILE" <> help "File description file")
        <*> optional (argument str $ metavar "DIR" <> help "Directory to save file (default: system Downloads directory)")
    randomP :: Parser RandomFileOptions
    randomP =
      RandomFileOptions
        <$> argument str (metavar "FILE" <> help "Path to save file")
        <*> argument strDec (metavar "SIZE" <> help "File size (bytes/kb/mb)")
    strDec = eitherReader $ strDecode . B.pack

xftpClientCLI :: IO ()
xftpClientCLI =
  getCliCommand' cliCommandP clientVersion >>= \case
    SendFile opts -> cliSendFile opts
    ReceiveFile opts -> cliReceiveFile opts
    RandomFile opts -> cliRandomFile opts
  where
    clientVersion = "SimpleX XFTP client v" <> xftpClientVersion

cliSendFile :: SendOptions -> IO ()
cliSendFile SendOptions {filePath, numRecipients, tempPath, outputDir} = do
  fds <- sendFile filePath tempPath numRecipients
  writeFileDescriptions outputDir fds

writeFileDescriptions :: Maybe FilePath -> [FileDescription] -> IO ()
writeFileDescriptions outputDir fds = do
  forM_ fds $ \fd -> do
    let fdPath = fromMaybe "." outputDir <> "/" <> "..."
    B.writeFile fdPath (strEncode fd)

sendFile :: FilePath -> Maybe FilePath -> Int -> IO [FileDescription]
sendFile filePath tempPath numRecipients = do
  digest <- C.sha512Hashlazy <$> LB.readFile filePath
  (encPath, key, iv) <- encryptFile
  -- fsz <- getFileSize filePath
  -- let fileSize = FileSize (fromIntegral fsz)
  fileSize :: FileSize Int64 <- FileSize . fromInteger <$> getFileSize filePath
  let chunkSize = defChunkSize
  chunksData <- uploadFile -- pass fileSize and chunkSize for splitting to chunks?
  -- concurrently: register and upload chunks to servers, get sndIds & rcvIds
  -- create/pivot n file descriptions with rcvIds
  -- save descriptions as files
  pure []
  where
    encryptFile :: IO (FilePath, C.Key, C.IV)
    encryptFile = undefined
    uploadFile :: IO [(Int, FileSize Word32, XFTPServer, SenderId, NonEmpty (RecipientId, C.APrivateSignKey))]
    uploadFile = do
      a <- atomically $ newXFTPAgent defaultXFTPClientAgentConfig
      c <- runExceptT $ getXFTPServerClient a "srv"
      -- for each chunk uploadFileChunk
      undefined
    uploadFileChunk :: XFTPClientAgent -> Int -> IO (SenderId, NonEmpty (RecipientId, C.APrivateSignKey))
    uploadFileChunk c chunkNo = do
      -- generate recipient keys
      -- register chunk on the server - createXFTPChunk
      -- upload chunk to server - uploadXFTPChunk
      undefined
    createFileDescriptions :: FileSize Int64 -> ByteString -> C.Key -> C.IV -> FileSize Word32 -> [(Int, FileSize Word32, XFTPServer, SenderId, NonEmpty (RecipientId, C.APrivateSignKey))] -> IO [FileDescription]
    createFileDescriptions size digest key iv chunkSize chunksData = do
      let name = takeFileName filePath
      -- pivot chunksData - 1 recipient id per chunk per server?
      -- create receiver index list to zip chunks replicas data with in uploadFileChunk?
      --   (Int, NonEmpty (RecipientId, C.APrivateSignKey))
      undefined

cliReceiveFile :: ReceiveOptions -> IO ()
cliReceiveFile ReceiveOptions {fileDescription, filePath} = do
  r <- strDecode <$> B.readFile fileDescription
  case r of
    Left e -> putStrLn $ "Failed to parse file description: " <> e
    Right fd -> receiveFile fd filePath

receiveFile :: FileDescription -> Maybe FilePath -> IO ()
receiveFile fd@FileDescription {chunks} filePath = do
  -- create empty file
  c <- atomically $ newXFTPAgent defaultXFTPClientAgentConfig
  writeLock <- atomically createLock
  -- download chunks concurrently - accept write lock
  -- forM_ chunks $ \fc -> downloadFileChunk fd fc fileDest
  -- decrypt file
  -- verify file digest
  pure ()

createDownloadFile :: FileDescription -> FilePath -> IO ()
createDownloadFile FileDescription {size} filePath = do
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

cliRandomFile :: RandomFileOptions -> IO ()
cliRandomFile RandomFileOptions {filePath, fileSize = FileSize size} =
  withFile filePath WriteMode (`saveRandomFile` size)
  where
    mb = 1024 * 1024
    saveRandomFile h sz = do
      bytes <- getRandomBytes $ min mb sz
      B.hPut h bytes
      when (sz > mb) $ saveRandomFile h (sz - mb)
