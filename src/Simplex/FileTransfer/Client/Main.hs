{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

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
import Data.List.NonEmpty (NonEmpty)
import Data.Maybe (fromMaybe)
import Options.Applicative
import Simplex.FileTransfer.Client.Agent
import Simplex.FileTransfer.Description
import Simplex.Messaging.Agent.Lock
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Encoding.String (StrEncoding (..))
import Simplex.Messaging.Protocol (RecipientId, SenderId)
import Simplex.Messaging.Server.CLI (getCliCommand')
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
        <$> argument str (metavar "FILE" <> help "File path to send")
        <*> optional outputP
        <*> option auto (short 'n' <> metavar "COUNT" <> help "Number of recipients" <> value 1)
        <*> optional (strOption $ long "temp" <> metavar "TEMP" <> help "Directory for temporary encrypted file")
    receiveP :: Parser ReceiveOptions
    receiveP =
      ReceiveOptions
        <$> argument str (metavar "FILE" <> help "File description file")
        <*> optional outputP
    randomP :: Parser RandomFileOptions
    randomP =
      RandomFileOptions
        <$> argument str (metavar "FILE" <> help "Path to save file")
        <*> ( option strDec (long "size" <> short 's' <> metavar "SIZE" <> help "File size (bytes/kb/mb)")
                <|> argument strDec (metavar "SIZE" <> help "File size (bytes/kb/mb)")
            )
    outputP =
      strOption (long "output" <> short 'o' <> metavar "DIR" <> help "Directory to save file descriptions")
        <|> argument str (metavar "DIR" <> help "Directory to save file descriptions")
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
  c <- atomically $ newXFTPAgent defaultXFTPClientAgentConfig
  -- concurrently: register and upload chunks to servers, get sndIds & rcvIds
  -- create/pivot n file descriptions with rcvIds
  -- save descriptions as files
  pure []
  where
    encryptFile :: IO (FilePath, C.Key, C.IV)
    encryptFile = undefined
    uploadFileChunk :: XFTPClientAgent -> Int -> IO (SenderId, NonEmpty RecipientId)
    uploadFileChunk c chunkNo = do
      -- generate recipient keys
      -- register chunk on the server - createXFTPChunk
      -- upload chunk to server - uploadXFTPChunk
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
