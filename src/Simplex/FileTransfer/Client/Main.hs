{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Simplex.FileTransfer.Client.Main (xftpClientCLI) where

import Control.Exception (Exception)
import Control.Monad
import Control.Monad.Except
import Crypto.Random (getRandomBytes)
import Data.Bifunctor (first)
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import qualified Data.ByteString.Lazy.Char8 as LB
import Data.Int (Int64)
import Data.List (foldl', sortOn)
import Data.List.NonEmpty (NonEmpty)
import Data.Map (Map)
import qualified Data.Map as M
import Data.Maybe (fromMaybe)
import Data.Word (Word32)
import Options.Applicative
import Simplex.FileTransfer.Client.Agent
import Simplex.FileTransfer.Description
import Simplex.Messaging.Agent.Lock
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Encoding.String (StrEncoding (..))
import Simplex.Messaging.Protocol (RecipientId, SenderId, SndPrivateSignKey, XFTPServer)
import Simplex.Messaging.Server.CLI (getCliCommand')
import Simplex.Messaging.Util (ifM)
import System.Exit (exitFailure)
import System.FilePath (splitExtensions, takeFileName, (</>))
import System.IO (IOMode (..))
import System.IO.Temp (getCanonicalTemporaryDirectory)
import UnliftIO
import UnliftIO.Directory

xftpClientVersion :: String
xftpClientVersion = "0.1.0"

defaultChunkSize :: FileSize Word32
defaultChunkSize = FileSize $ 8 * 1024 * 1024

newtype CLIError = CLIError String
  deriving (Eq, Show, Exception)

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
    filePath :: Maybe FilePath,
    tempPath :: Maybe FilePath
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
        <*> temp
    receiveP :: Parser ReceiveOptions
    receiveP =
      ReceiveOptions
        <$> argument str (metavar "FILE" <> help "File description file")
        <*> optional (argument str $ metavar "DIR" <> help "Directory to save file (default: system Downloads directory)")
        <*> temp
    randomP :: Parser RandomFileOptions
    randomP =
      RandomFileOptions
        <$> argument str (metavar "FILE" <> help "Path to save file")
        <*> argument strDec (metavar "SIZE" <> help "File size (bytes/kb/mb)")
    strDec = eitherReader $ strDecode . B.pack
    temp = optional (strOption $ long "temp" <> metavar "TEMP" <> help "Directory for temporary encrypted file (default: system temp directory)")

data SentFileChunk = SentFileChunk
  { chunkNo :: Int,
    chunkSize :: FileSize Word32,
    digest :: FileDigest,
    replicas :: [SentFileChunkReplica]
  }
  deriving (Eq, Show)

data SentFileChunkReplica = SentFileChunkReplica
  { server :: XFTPServer,
    recipients :: [(ChunkReplicaId, C.APrivateSignKey)]
  }
  deriving (Eq, Show)

data SentRecipientReplica = SentRecipientReplica
  { chunkNo :: Int,
    server :: XFTPServer,
    rcvNo :: Int,
    rcvId :: ChunkReplicaId,
    rcvKey :: C.APrivateSignKey,
    digest :: FileDigest,
    chunkSize :: FileSize Word32
  }

xftpClientCLI :: IO ()
xftpClientCLI =
  getCliCommand' cliCommandP clientVersion >>= \case
    SendFile opts -> cliSendFile opts
    ReceiveFile opts -> runE $ cliReceiveFile opts
    RandomFile opts -> cliRandomFile opts
  where
    clientVersion = "SimpleX XFTP client v" <> xftpClientVersion

runE :: ExceptT CLIError IO () -> IO ()
runE a =
  runExceptT a >>= \case
    Left (CLIError e) -> putStrLn e >> exitFailure
    _ -> pure ()

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
  let chunkSize = defaultChunkSize
  sentChunks <- uploadFile -- pass fileSize and chunkSize for splitting to chunks?
  -- concurrently: register and upload chunks to servers, get sndIds & rcvIds
  -- create/pivot n file descriptions with rcvIds
  -- save descriptions as files
  pure []
  where
    encryptFile :: IO (FilePath, C.Key, C.IV)
    encryptFile = undefined
    uploadFile :: IO [SentFileChunk]
    uploadFile = do
      a <- atomically $ newXFTPAgent defaultXFTPClientAgentConfig

      -- for each chunk uploadFileChunk
      undefined
    uploadFileChunk :: XFTPClientAgent -> Int -> IO (SenderId, SndPrivateSignKey, SentFileChunk)
    uploadFileChunk a chunkNo = do
      c <- runExceptT $ getXFTPServerClient a "srv"
      -- generate recipient keys
      -- register chunk on the server - createXFTPChunk
      -- upload chunk to server - uploadXFTPChunk
      undefined

    -- M chunks, R replicas, N recipients
    -- rcvReplicas: M[SentFileChunk] -> M * R * N [SentRecipientReplica]
    -- rcvChunks: M * R * N [SentRecipientReplica] -> N[ M[FileChunk] ]
    createFileDescriptions :: FileDescription -> [SentFileChunk] -> [FileDescription]
    createFileDescriptions fd sentChunks = map (\chunks -> (fd :: FileDescription) {chunks}) rcvChunks
      where
        rcvReplicas :: [SentRecipientReplica]
        rcvReplicas =
          concatMap
            ( \SentFileChunk {chunkNo, digest, chunkSize, replicas} ->
                concatMap
                  ( \SentFileChunkReplica {server, recipients} ->
                      zipWith (\rcvNo (rcvId, rcvKey) -> SentRecipientReplica {chunkNo, server, rcvNo, rcvId, rcvKey, digest, chunkSize}) [1 ..] recipients
                  )
                  replicas
            )
            sentChunks
        rcvChunks :: [[FileChunk]]
        rcvChunks = map (sortChunks . M.elems) $ M.elems $ foldl' addRcvChunk M.empty rcvReplicas
        sortChunks :: [FileChunk] -> [FileChunk]
        sortChunks = map reverseReplicas . sortOn (chunkNo :: FileChunk -> Int)
        reverseReplicas ch@FileChunk {replicas} = (ch :: FileChunk) {replicas = reverse replicas}
        addRcvChunk :: Map Int (Map Int FileChunk) -> SentRecipientReplica -> Map Int (Map Int FileChunk)
        addRcvChunk m SentRecipientReplica {chunkNo, server, rcvNo, rcvId, rcvKey, digest, chunkSize} =
          M.alter (Just . addOrChangeRecipient) rcvNo m
          where
            addOrChangeRecipient :: Maybe (Map Int FileChunk) -> Map Int FileChunk
            addOrChangeRecipient = \case
              Just m' -> M.alter (Just . addOrChangeChunk) chunkNo m'
              _ -> M.singleton chunkNo $ FileChunk {digest, chunkSize, replicas = [replica]}
            addOrChangeChunk :: Maybe FileChunk -> FileChunk
            addOrChangeChunk = \case
              Just ch@FileChunk {replicas} -> ch {replicas = replica : replicas}
              _ -> FileChunk {digest, chunkSize, replicas = [replica]}
            replica = FileChunkReplica {server, rcvId, rcvKey}

cliReceiveFile :: ReceiveOptions -> ExceptT CLIError IO ()
cliReceiveFile ReceiveOptions {fileDescription, filePath, tempPath} = do
  fd <- ExceptT $ first (CLIError . ("Failed to parse file description: " <>)) . strDecode <$> B.readFile fileDescription
  ValidFileDescription encSize FileDescription {name, chunks} <- liftEither . first CLIError $ validateFileDescription fd
  filePath' <- getFilePath name
  encPath' <- getEncPath tempPath name
  withFile encPath' WriteMode $ \h -> do
    liftIO $ LB.hPut h $ LB.replicate encSize '#'
    c <- atomically $ newXFTPAgent defaultXFTPClientAgentConfig
    writeLock <- atomically createLock
    -- download chunks concurrently - accept write lock
    -- forM_ chunks $ \fc -> downloadFileChunk fd fc fileDest
    -- decrypt file
    -- verify file digest
    pure ()
  where
    getFilePath :: String -> ExceptT CLIError IO FilePath
    getFilePath name =
      case filePath of
        Just path ->
          ifM (doesDirectoryExist path) (uniqueCombine path name) $
            ifM (doesFileExist path) (throwError $ CLIError "File already exists") (pure path)
        _ -> (`uniqueCombine` name) . (</> "Downloads") =<< getHomeDirectory

getEncPath :: MonadIO m => Maybe FilePath -> String -> m FilePath
getEncPath path name = (`uniqueCombine` (name <> ".encrypted")) =<< maybe (liftIO getCanonicalTemporaryDirectory) pure path

uniqueCombine :: MonadIO m => FilePath -> String -> m FilePath
uniqueCombine filePath fileName = tryCombine (0 :: Int)
  where
    tryCombine n =
      let (name, ext) = splitExtensions fileName
          suffix = if n == 0 then "" else "_" <> show n
          f = filePath </> (name <> suffix <> ext)
       in ifM (doesFileExist f) (tryCombine $ n + 1) (pure f)

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
