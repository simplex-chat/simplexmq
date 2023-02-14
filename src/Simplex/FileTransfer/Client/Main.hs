{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiWayIf #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Simplex.FileTransfer.Client.Main (xftpClientCLI) where

import Control.Monad
import Control.Monad.Except
import Crypto.Random (getRandomBytes)
import Data.Bifunctor (first)
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import qualified Data.ByteString.Lazy.Char8 as LB
import Data.Int (Int64)
import Data.List (foldl', sortOn)
import qualified Data.List.NonEmpty as L
import Data.Map (Map)
import qualified Data.Map as M
import Data.Maybe (fromMaybe)
import Data.Word (Word32)
import Options.Applicative
import Simplex.FileTransfer.Client
import Simplex.FileTransfer.Client.Agent
import Simplex.FileTransfer.Description
import Simplex.FileTransfer.Protocol (FileInfo (..))
import Simplex.Messaging.Agent.Lock
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Encoding
import Simplex.Messaging.Encoding.String (StrEncoding (..))
import Simplex.Messaging.Protocol (SenderId, SndPrivateSignKey, SndPublicVerifyKey, XFTPServer)
import Simplex.Messaging.Server.CLI (getCliCommand')
import Simplex.Messaging.Util (ifM)
import System.Exit (exitFailure)
import System.FilePath (splitExtensions, splitFileName, (</>))
import System.IO.Temp (getCanonicalTemporaryDirectory)
import UnliftIO
import UnliftIO.Directory

xftpClientVersion :: String
xftpClientVersion = "0.1.0"

defaultChunkSize :: Word32
defaultChunkSize = 8 * mb

smallChunkSize :: Word32
smallChunkSize = 1 * mb

fileSizeEncodingLength :: Int64
fileSizeEncodingLength = 8

mb :: Word32
mb = 1024 * 1024

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
    retryCount :: Int,
    tempPath :: Maybe FilePath
  }
  deriving (Show)

data ReceiveOptions = ReceiveOptions
  { fileDescription :: FilePath,
    filePath :: Maybe FilePath,
    retryCount :: Int,
    tempPath :: Maybe FilePath
  }
  deriving (Show)

data RandomFileOptions = RandomFileOptions
  { filePath :: FilePath,
    fileSize :: FileSize Int
  }
  deriving (Show)

defaultRetryCount :: Int
defaultRetryCount = 3

xftpServer :: XFTPServer
xftpServer = "xftp://vr0bXzm4iKkLvleRMxLznTS-lHjXEyXunxn_7VJckk4=@localhost:443"

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
        <*> retries
        <*> temp
    receiveP :: Parser ReceiveOptions
    receiveP =
      ReceiveOptions
        <$> argument str (metavar "FILE" <> help "File description file")
        <*> optional (argument str $ metavar "DIR" <> help "Directory to save file (default: system Downloads directory)")
        <*> retries
        <*> temp
    randomP :: Parser RandomFileOptions
    randomP =
      RandomFileOptions
        <$> argument str (metavar "FILE" <> help "Path to save file")
        <*> argument strDec (metavar "SIZE" <> help "File size (bytes/kb/mb)")
    strDec = eitherReader $ strDecode . B.pack
    retries = option auto (long "retry" <> short 'r' <> metavar "RETRY" <> help "Number of network retries" <> value defaultRetryCount <> showDefault)
    temp = optional (strOption $ long "temp" <> metavar "TEMP" <> help "Directory for temporary encrypted file (default: system temp directory)")

data SentFileChunk = SentFileChunk
  { chunkNo :: Int,
    sndId :: SenderId,
    sndPrivateKey :: SndPrivateSignKey,
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
    SendFile opts -> runE $ cliSendFile opts
    ReceiveFile opts -> runE $ cliReceiveFile opts
    RandomFile opts -> cliRandomFile opts
  where
    clientVersion = "SimpleX XFTP client v" <> xftpClientVersion

runE :: ExceptT CLIError IO () -> IO ()
runE a =
  runExceptT a >>= \case
    Left (CLIError e) -> putStrLn e >> exitFailure
    _ -> pure ()

cliSendFile :: SendOptions -> ExceptT CLIError IO ()
cliSendFile opts@SendOptions {filePath, outputDir, numRecipients, retryCount, tempPath} = do
  fds <- sendFile opts
  liftIO $ writeFileDescriptions filePath outputDir fds

writeFileDescriptions :: FilePath -> Maybe FilePath -> [FileDescription] -> IO ()
writeFileDescriptions filePath outputDir fds = do
  let (_, fileName) = splitFileName filePath
  outDir <- uniqueCombine (fromMaybe "./" outputDir) (fileName <> ".xftp/")
  createDirectoryIfMissing True outDir
  forM_ (zip [1 ..] fds) $ \(i, fd) -> do
    let fdPath = outDir </> ("rcv" <> show i <> ".xftp")
    B.writeFile fdPath $ strEncode fd

sendFile :: SendOptions -> ExceptT CLIError IO [FileDescription]
sendFile SendOptions {filePath, outputDir, numRecipients, retryCount, tempPath} = do
  (encPath, size, key, iv, chunkSpecs) <- liftIO encryptFile
  digest <- liftIO $ C.sha512Hashlazy <$> LB.readFile encPath
  sentChunks <- uploadFile chunkSpecs
  -- TODO if only small chunks, use different default size
  let fd = FileDescription {name = "", size, digest = FileDigest digest, key, iv, chunkSize = FileSize defaultChunkSize, chunks = []}
  pure $ createFileDescriptions fd $ map snd sentChunks
  where
    encryptFile :: IO (FilePath, FileSize Int64, C.Key, C.IV, [XFTPChunkSpec])
    encryptFile = do
      tempFile <- getEncPath tempPath "xftp"
      key <- C.randomAesKey
      iv <- C.randomIV
      fileSize <- fromInteger <$> getFileSize filePath
      let chunkSizes = prepareChunkSizes (fileSize + fileSizeEncodingLength)
          paddedSize = fromIntegral $ sum chunkSizes
      encrypt key iv fileSize paddedSize tempFile
      let chunkSpecs = prepareChunkSpecs tempFile chunkSizes
      pure (tempFile, FileSize paddedSize, key, iv, chunkSpecs)
      where
        prepareChunkSizes :: Int64 -> [Word32]
        prepareChunkSizes 0 = []
        prepareChunkSizes size
          | size >= defSz = replicate (fromIntegral n1) defaultChunkSize <> prepareChunkSizes remSz
          | size > defSz `div` 2 = [defaultChunkSize]
          | otherwise = replicate (fromIntegral n2') smallChunkSize
          where
            (n1, remSz) = size `divMod` defSz
            n2' = let (n2, rem) = (size `divMod` fromIntegral smallChunkSize) in if rem == 0 then n2 else n2 + 1
            defSz = fromIntegral defaultChunkSize :: Int64
        encrypt :: C.Key -> C.IV -> Int64 -> Int64 -> FilePath -> IO ()
        encrypt key iv fileSize paddedSize encFile = do
          f <- LB.readFile filePath
          withFile encFile WriteMode $ \h -> do
            B.hPut h (smpEncode fileSize)
            LB.hPut h f
            when (paddedSize > fileSize) $
              LB.hPut h (LB.replicate (fromIntegral $ paddedSize - fileSize - fileSizeEncodingLength) '#')
        prepareChunkSpecs :: FilePath -> [Word32] -> [XFTPChunkSpec]
        prepareChunkSpecs filePath chunkSizes = reverse . snd $ foldl' addSpec (0, []) chunkSizes
          where
            addSpec :: (Int64, [XFTPChunkSpec]) -> Word32 -> (Int64, [XFTPChunkSpec])
            addSpec (chunkOffset, specs) sz =
              let spec = XFTPChunkSpec {filePath, chunkOffset, chunkSize = fromIntegral sz}
               in (chunkOffset + fromIntegral sz, spec : specs)
    uploadFile :: [XFTPChunkSpec] -> ExceptT CLIError IO [(Int, SentFileChunk)]
    uploadFile chunks = do
      a <- atomically $ newXFTPAgent defaultXFTPClientAgentConfig
      -- TODO shuffle chunks
      forM (zip [1 ..] chunks) $ uploadFileChunk a
      where
        retries = withRetry retryCount
        uploadFileChunk :: XFTPClientAgent -> (Int, XFTPChunkSpec) -> ExceptT CLIError IO (Int, SentFileChunk)
        uploadFileChunk a (chunkNo, chunkSpec@XFTPChunkSpec {chunkSize}) = do
          (sndKey, spKey) <- liftIO $ C.generateSignatureKeyPair C.SEd25519
          rKeys <- liftIO $ L.fromList <$> replicateM numRecipients (C.generateSignatureKeyPair C.SEd25519)
          chInfo@FileInfo {digest} <- getChunkInfo sndKey chunkSpec
          -- TODO choose server randomly
          c <- retries $ withExceptT (CLIError . show) $ getXFTPServerClient a xftpServer
          (sndId, rIds) <- retries $ withExceptT (CLIError . show) $ createXFTPChunk c spKey chInfo $ L.map fst rKeys
          retries $ withExceptT (CLIError . show) $ uploadXFTPChunk c spKey sndId chunkSpec
          let recipients = L.toList $ L.map ChunkReplicaId rIds `L.zip` L.map snd rKeys
              replicas = [SentFileChunkReplica {server = xftpServer, recipients}]
          pure (chunkNo, SentFileChunk {chunkNo, sndId, sndPrivateKey = spKey, chunkSize = FileSize $ fromIntegral chunkSize, digest = FileDigest digest, replicas})
        getChunkInfo :: SndPublicVerifyKey -> XFTPChunkSpec -> ExceptT CLIError IO FileInfo
        getChunkInfo sndKey XFTPChunkSpec {chunkSize} = pure FileInfo {sndKey, size = fromIntegral chunkSize, digest = ""}

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
              _ -> M.singleton chunkNo $ FileChunk {chunkNo, digest, chunkSize, replicas = [replica]}
            addOrChangeChunk :: Maybe FileChunk -> FileChunk
            addOrChangeChunk = \case
              Just ch@FileChunk {replicas} -> ch {replicas = replica : replicas}
              _ -> FileChunk {chunkNo, digest, chunkSize, replicas = [replica]}
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
       in ifM (liftIO (print f) >> doesPathExist f) (tryCombine $ n + 1) (pure f)

withRetry :: Int -> ExceptT CLIError IO a -> ExceptT CLIError IO a
withRetry 0 _ = throwError $ CLIError "internal: no retry attempts"
withRetry 1 a = a
withRetry n a = a `catchError` \_ -> withRetry (n - 1) a

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
