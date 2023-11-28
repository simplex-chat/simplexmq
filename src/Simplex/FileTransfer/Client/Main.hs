{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# OPTIONS_GHC -fno-warn-ambiguous-fields #-}

module Simplex.FileTransfer.Client.Main
  ( SendOptions (..),
    CLIError (..),
    xftpClientCLI,
    cliSendFile,
    cliSendFileOpts,
    prepareChunkSizes,
    prepareChunkSpecs,
    maxFileSize,
    fileSizeLen,
    getChunkDigest,
    SentRecipientReplica (..),
  )
where

import Control.Logger.Simple
import Control.Monad
import Control.Monad.Except
import Crypto.Random (getRandomBytes)
import qualified Data.Attoparsec.ByteString.Char8 as A
import Data.Bifunctor (first)
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import qualified Data.ByteString.Lazy.Char8 as LB
import Data.Char (toLower)
import Data.Int (Int64)
import Data.List (foldl', sortOn)
import Data.List.NonEmpty (NonEmpty (..), nonEmpty)
import qualified Data.List.NonEmpty as L
import Data.Map (Map)
import qualified Data.Map as M
import Data.Maybe (fromMaybe)
import qualified Data.Text as T
import Data.Word (Word32)
import GHC.Records (HasField (getField))
import Options.Applicative
import Simplex.FileTransfer.Chunks
import Simplex.FileTransfer.Client
import Simplex.FileTransfer.Client.Agent
import Simplex.FileTransfer.Client.Presets
import Simplex.FileTransfer.Crypto
import Simplex.FileTransfer.Description
import Simplex.FileTransfer.Protocol
import Simplex.FileTransfer.Transport (XFTPRcvChunkSpec (..))
import Simplex.FileTransfer.Types
import Simplex.FileTransfer.Util (uniqueCombine)
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Crypto.File (CryptoFile (..), FTCryptoError (..))
import qualified Simplex.Messaging.Crypto.File as CF
import qualified Simplex.Messaging.Crypto.Lazy as LC
import Simplex.Messaging.Encoding
import Simplex.Messaging.Encoding.String (StrEncoding (..))
import Simplex.Messaging.Parsers (parseAll)
import Simplex.Messaging.Protocol (ProtoServerWithAuth (..), SenderId, SndPrivateSignKey, XFTPServer, XFTPServerWithAuth)
import Simplex.Messaging.Server.CLI (getCliCommand')
import Simplex.Messaging.Util (groupAllOn, ifM, tshow, whenM)
import System.Exit (exitFailure)
import System.FilePath (splitFileName, (</>))
import System.IO.Temp (getCanonicalTemporaryDirectory)
import System.Random (StdGen, newStdGen, randomR)
import UnliftIO
import UnliftIO.Directory

xftpClientVersion :: String
xftpClientVersion = "1.0.1"

maxFileSize :: Int64
maxFileSize = gb 1

maxFileSizeStr :: String
maxFileSizeStr = B.unpack . strEncode $ FileSize maxFileSize

fileSizeLen :: Int64
fileSizeLen = 8

newtype CLIError = CLIError String
  deriving (Eq, Show, Exception)

cliCryptoError :: FTCryptoError -> CLIError
cliCryptoError = \case
  FTCECryptoError e -> CLIError $ "Error decrypting file: " <> show e
  FTCEInvalidHeader e -> CLIError $ "Invalid file header: " <> e
  FTCEInvalidAuthTag -> CLIError "Error decrypting file: incorrect auth tag"
  FTCEInvalidFileSize -> CLIError "Error decrypting file: incorrect file size"
  FTCEFileIOError e -> CLIError $ "File IO error: " <> show e

data CliCommand
  = SendFile SendOptions
  | ReceiveFile ReceiveOptions
  | DeleteFile DeleteOptions
  | RandomFile RandomFileOptions
  | FileDescrInfo InfoOptions

data SendOptions = SendOptions
  { filePath :: FilePath,
    outputDir :: Maybe FilePath,
    numRecipients :: Int,
    xftpServers :: [XFTPServerWithAuth],
    retryCount :: Int,
    tempPath :: Maybe FilePath,
    verbose :: Bool
  }
  deriving (Show)

data ReceiveOptions = ReceiveOptions
  { fileDescription :: FilePath,
    filePath :: Maybe FilePath,
    retryCount :: Int,
    tempPath :: Maybe FilePath,
    verbose :: Bool,
    yes :: Bool
  }
  deriving (Show)

data DeleteOptions = DeleteOptions
  { fileDescription :: FilePath,
    retryCount :: Int,
    verbose :: Bool,
    yes :: Bool
  }
  deriving (Show)

newtype InfoOptions = InfoOptions
  { fileDescription :: FilePath
  }
  deriving (Show)

data RandomFileOptions = RandomFileOptions
  { filePath :: FilePath,
    fileSize :: FileSize Int64
  }
  deriving (Show)

defaultRetryCount :: Int
defaultRetryCount = 3

cliCommandP :: Parser CliCommand
cliCommandP =
  hsubparser
    ( command "send" (info (SendFile <$> sendP) (progDesc "Send file"))
        <> command "recv" (info (ReceiveFile <$> receiveP) (progDesc "Receive file"))
        <> command "del" (info (DeleteFile <$> deleteP) (progDesc "Delete file from server(s)"))
        <> command "info" (info (FileDescrInfo <$> infoP) (progDesc "Show file description"))
    )
    <|> hsubparser (command "rand" (info (RandomFile <$> randomP) (progDesc "Generate a random file of a given size")) <> internal)
  where
    sendP :: Parser SendOptions
    sendP =
      SendOptions
        <$> argument str (metavar "FILE" <> help "File to send")
        <*> optional (argument str $ metavar "DIR" <> help "Directory to save file descriptions (default: current directory)")
        <*> option auto (short 'n' <> metavar "COUNT" <> help "Number of recipients" <> value 1 <> showDefault)
        <*> xftpServers
        <*> retryCountP
        <*> temp
        <*> verboseP
    receiveP :: Parser ReceiveOptions
    receiveP =
      ReceiveOptions
        <$> fileDescrArg
        <*> optional (argument str $ metavar "DIR" <> help "Directory to save file (default: system Downloads directory)")
        <*> retryCountP
        <*> temp
        <*> verboseP
        <*> yesP
    deleteP :: Parser DeleteOptions
    deleteP =
      DeleteOptions
        <$> fileDescrArg
        <*> retryCountP
        <*> verboseP
        <*> yesP
    infoP :: Parser InfoOptions
    infoP = InfoOptions <$> fileDescrArg
    randomP :: Parser RandomFileOptions
    randomP =
      RandomFileOptions
        <$> argument str (metavar "FILE" <> help "Path to save file")
        <*> argument str (metavar "SIZE" <> help "File size (bytes/kb/mb/gb)")
    fileDescrArg = argument str (metavar "FILE" <> help "File description file")
    retryCountP = option auto (long "retry" <> short 'r' <> metavar "RETRY" <> help "Number of network retries" <> value defaultRetryCount <> showDefault)
    temp = optional (strOption $ long "tmp" <> metavar "TMP" <> help "Directory for temporary encrypted file (default: system temp directory)")
    verboseP = switch (long "verbose" <> short 'v' <> help "Verbose output")
    yesP = switch (long "yes" <> short 'y' <> help "Yes to questions")
    xftpServers =
      option
        parseXFTPServers
        ( long "servers"
            <> short 's'
            <> metavar "SERVER"
            <> help "Semicolon-separated list of XFTP server(s) to use (each server can have more than one hostname)"
            <> value []
        )
    parseXFTPServers = eitherReader $ parseAll xftpServersP . B.pack
    xftpServersP = strP `A.sepBy1` A.char ';'

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
    replicaId :: ChunkReplicaId,
    replicaKey :: C.APrivateSignKey,
    digest :: FileDigest,
    chunkSize :: FileSize Word32
  }

logCfg :: LogConfig
logCfg = LogConfig {lc_file = Nothing, lc_stderr = True}

xftpClientCLI :: IO ()
xftpClientCLI =
  getCliCommand' cliCommandP clientVersion >>= \case
    SendFile opts -> runLogE opts $ cliSendFile opts
    ReceiveFile opts -> runLogE opts $ cliReceiveFile opts
    DeleteFile opts -> runLogE opts $ cliDeleteFile opts
    FileDescrInfo opts -> runE $ cliFileDescrInfo opts
    RandomFile opts -> cliRandomFile opts
  where
    clientVersion = "SimpleX XFTP client v" <> xftpClientVersion

runLogE :: HasField "verbose" a Bool => a -> ExceptT CLIError IO () -> IO ()
runLogE opts a
  | getField @"verbose" opts = setLogLevel LogDebug >> withGlobalLogging logCfg (runE a)
  | otherwise = runE a

runE :: ExceptT CLIError IO () -> IO ()
runE a =
  runExceptT a >>= \case
    Left (CLIError e) -> putStrLn e >> exitFailure
    _ -> pure ()

cliSendFile :: SendOptions -> ExceptT CLIError IO ()
cliSendFile opts = cliSendFileOpts opts True $ printProgress "Uploaded"

cliSendFileOpts :: SendOptions -> Bool -> (Int64 -> Int64 -> IO ()) -> ExceptT CLIError IO ()
cliSendFileOpts SendOptions {filePath, outputDir, numRecipients, xftpServers, retryCount, tempPath, verbose} printInfo notifyProgress = do
  let (_, fileName) = splitFileName filePath
  liftIO $ when printInfo $ printNoNewLine "Encrypting file..."
  (encPath, fdRcv, fdSnd, chunkSpecs, encSize) <- encryptFileForUpload fileName
  liftIO $ when printInfo $ printNoNewLine "Uploading file..."
  uploadedChunks <- newTVarIO []
  sentChunks <- uploadFile chunkSpecs uploadedChunks encSize
  whenM (doesFileExist encPath) $ removeFile encPath
  -- TODO if only small chunks, use different default size
  liftIO $ do
    let fdRcvs = createRcvFileDescriptions fdRcv sentChunks
        fdSnd' = createSndFileDescription fdSnd sentChunks
    (fdRcvPaths, fdSndPath) <- writeFileDescriptions fileName fdRcvs fdSnd'
    when printInfo $ do
      printNoNewLine "File uploaded!"
      putStrLn $ "\nSender file description: " <> fdSndPath
      putStrLn "Pass file descriptions to the recipient(s):"
    forM_ fdRcvPaths putStrLn
  where
    encryptFileForUpload :: String -> ExceptT CLIError IO (FilePath, FileDescription 'FRecipient, FileDescription 'FSender, [XFTPChunkSpec], Int64)
    encryptFileForUpload fileName = do
      fileSize <- fromInteger <$> getFileSize filePath
      when (fileSize > maxFileSize) $ throwError $ CLIError $ "Files bigger than " <> maxFileSizeStr <> " are not supported"
      encPath <- getEncPath tempPath "xftp"
      key <- liftIO C.randomSbKey
      nonce <- liftIO C.randomCbNonce
      let fileHdr = smpEncode FileHeader {fileName, fileExtra = Nothing}
          fileSize' = fromIntegral (B.length fileHdr) + fileSize
          chunkSizes = prepareChunkSizes $ fileSize' + fileSizeLen + authTagSize
          defChunkSize = head chunkSizes
          chunkSizes' = map fromIntegral chunkSizes
          encSize = sum chunkSizes'
          srcFile = CF.plain filePath
      withExceptT (CLIError . show) $ encryptFile srcFile fileHdr key nonce fileSize' encSize encPath
      digest <- liftIO $ LC.sha512Hash <$> LB.readFile encPath
      let chunkSpecs = prepareChunkSpecs encPath chunkSizes
          fdRcv = FileDescription {party = SFRecipient, size = FileSize encSize, digest = FileDigest digest, key, nonce, chunkSize = FileSize defChunkSize, chunks = []}
          fdSnd = FileDescription {party = SFSender, size = FileSize encSize, digest = FileDigest digest, key, nonce, chunkSize = FileSize defChunkSize, chunks = []}
      logInfo $ "encrypted file to " <> tshow encPath
      pure (encPath, fdRcv, fdSnd, chunkSpecs, encSize)
    uploadFile :: [XFTPChunkSpec] -> TVar [Int64] -> Int64 -> ExceptT CLIError IO [SentFileChunk]
    uploadFile chunks uploadedChunks encSize = do
      a <- atomically $ newXFTPAgent defaultXFTPClientAgentConfig
      gen <- newTVarIO =<< liftIO newStdGen
      let xftpSrvs = fromMaybe defaultXFTPServers (nonEmpty xftpServers)
      srvs <- liftIO $ replicateM (length chunks) $ getXFTPServer gen xftpSrvs
      let thd3 (_, _, x) = x
          chunks' = groupAllOn thd3 $ zip3 [1 ..] chunks srvs
      -- TODO shuffle/unshuffle chunks
      -- the reason we don't do pooled downloads here within one server is that http2 library doesn't handle cleint concurrency, even though
      -- upload doesn't allow other requests within the same client until complete (but download does allow).
      logInfo $ "uploading " <> tshow (length chunks) <> " chunks..."
      map snd . sortOn fst . concat <$> pooledForConcurrentlyN 16 chunks' (mapM $ uploadFileChunk a)
      where
        uploadFileChunk :: XFTPClientAgent -> (Int, XFTPChunkSpec, XFTPServerWithAuth) -> ExceptT CLIError IO (Int, SentFileChunk)
        uploadFileChunk a (chunkNo, chunkSpec@XFTPChunkSpec {chunkSize}, ProtoServerWithAuth xftpServer auth) = do
          logInfo $ "uploading chunk " <> tshow chunkNo <> " to " <> showServer xftpServer <> "..."
          (sndKey, spKey) <- liftIO $ C.generateSignatureKeyPair C.SEd25519
          rKeys <- liftIO $ L.fromList <$> replicateM numRecipients (C.generateSignatureKeyPair C.SEd25519)
          digest <- liftIO $ getChunkDigest chunkSpec
          let ch = FileInfo {sndKey, size = fromIntegral chunkSize, digest}
          c <- withRetry retryCount $ getXFTPServerClient a xftpServer
          (sndId, rIds) <- withRetry retryCount $ createXFTPChunk c spKey ch (L.map fst rKeys) auth
          withReconnect a xftpServer retryCount $ \c' -> uploadXFTPChunk c' spKey sndId chunkSpec
          logInfo $ "uploaded chunk " <> tshow chunkNo
          uploaded <- atomically . stateTVar uploadedChunks $ \cs ->
            let cs' = fromIntegral chunkSize : cs in (sum cs', cs')
          liftIO $ do
            notifyProgress uploaded encSize
            when verbose $ putStrLn ""
          let recipients = L.toList $ L.map ChunkReplicaId rIds `L.zip` L.map snd rKeys
              replicas = [SentFileChunkReplica {server = xftpServer, recipients}]
          pure (chunkNo, SentFileChunk {chunkNo, sndId, sndPrivateKey = spKey, chunkSize = FileSize $ fromIntegral chunkSize, digest = FileDigest digest, replicas})
        getXFTPServer :: TVar StdGen -> NonEmpty XFTPServerWithAuth -> IO XFTPServerWithAuth
        getXFTPServer gen = \case
          srv :| [] -> pure srv
          servers -> do
            atomically $ (servers L.!!) <$> stateTVar gen (randomR (0, L.length servers - 1))

    -- M chunks, R replicas, N recipients
    -- rcvReplicas: M[SentFileChunk] -> M * R * N [SentRecipientReplica]
    -- rcvChunks: M * R * N [SentRecipientReplica] -> N[ M[FileChunk] ]
    createRcvFileDescriptions :: FileDescription 'FRecipient -> [SentFileChunk] -> [FileDescription 'FRecipient]
    createRcvFileDescriptions fd sentChunks = map (\chunks -> (fd :: (FileDescription 'FRecipient)) {chunks}) rcvChunks
      where
        rcvReplicas :: [SentRecipientReplica]
        rcvReplicas =
          concatMap
            ( \SentFileChunk {chunkNo, digest, chunkSize, replicas} ->
                concatMap
                  ( \SentFileChunkReplica {server, recipients} ->
                      zipWith (\rcvNo (replicaId, replicaKey) -> SentRecipientReplica {chunkNo, server, rcvNo, replicaId, replicaKey, digest, chunkSize}) [1 ..] recipients
                  )
                  replicas
            )
            sentChunks
        rcvChunks :: [[FileChunk]]
        rcvChunks = map (sortChunks . M.elems) $ M.elems $ foldl' addRcvChunk M.empty rcvReplicas
        sortChunks :: [FileChunk] -> [FileChunk]
        sortChunks = map reverseReplicas . sortOn (\FileChunk {chunkNo} -> chunkNo)
        reverseReplicas ch@FileChunk {replicas} = (ch :: FileChunk) {replicas = reverse replicas}
        addRcvChunk :: Map Int (Map Int FileChunk) -> SentRecipientReplica -> Map Int (Map Int FileChunk)
        addRcvChunk m SentRecipientReplica {chunkNo, server, rcvNo, replicaId, replicaKey, digest, chunkSize} =
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
            replica = FileChunkReplica {server, replicaId, replicaKey}
    createSndFileDescription :: FileDescription 'FSender -> [SentFileChunk] -> FileDescription 'FSender
    createSndFileDescription fd sentChunks = fd {chunks = sndChunks}
      where
        sndChunks :: [FileChunk]
        sndChunks =
          map
            ( \SentFileChunk {chunkNo, sndId, sndPrivateKey, chunkSize, digest, replicas} ->
                FileChunk {chunkNo, digest, chunkSize, replicas = sndReplicas replicas (ChunkReplicaId sndId) sndPrivateKey}
            )
            sentChunks
        -- SentFileChunk having sndId and sndPrivateKey represents the current implementation's limitation
        -- that sender uploads each chunk only to one server, so we can use the first replica's server for FileChunkReplica
        sndReplicas :: [SentFileChunkReplica] -> ChunkReplicaId -> C.APrivateSignKey -> [FileChunkReplica]
        sndReplicas [] _ _ = []
        sndReplicas (SentFileChunkReplica {server} : _) replicaId replicaKey = [FileChunkReplica {server, replicaId, replicaKey}]
    writeFileDescriptions :: String -> [FileDescription 'FRecipient] -> FileDescription 'FSender -> IO ([FilePath], FilePath)
    writeFileDescriptions fileName fdRcvs fdSnd = do
      outDir <- uniqueCombine (fromMaybe "." outputDir) (fileName <> ".xftp")
      createDirectoryIfMissing True outDir
      fdRcvPaths <- forM (zip [1 ..] fdRcvs) $ \(i :: Int, fd) -> do
        let fdPath = outDir </> ("rcv" <> show i <> ".xftp")
        B.writeFile fdPath $ strEncode fd
        pure fdPath
      let fdSndPath = outDir </> "snd.xftp.private"
      B.writeFile fdSndPath $ strEncode fdSnd
      pure (fdRcvPaths, fdSndPath)

getChunkDigest :: XFTPChunkSpec -> IO ByteString
getChunkDigest XFTPChunkSpec {filePath = chunkPath, chunkOffset, chunkSize} =
  withFile chunkPath ReadMode $ \h -> do
    hSeek h AbsoluteSeek $ fromIntegral chunkOffset
    LC.sha256Hash <$> LB.hGet h (fromIntegral chunkSize)

cliReceiveFile :: ReceiveOptions -> ExceptT CLIError IO ()
cliReceiveFile ReceiveOptions {fileDescription, filePath, retryCount, tempPath, verbose, yes} =
  getFileDescription' fileDescription >>= receive
  where
    receive :: ValidFileDescription 'FRecipient -> ExceptT CLIError IO ()
    receive (ValidFileDescription FileDescription {size, digest, key, nonce, chunks}) = do
      encPath <- getEncPath tempPath "xftp"
      createDirectory encPath
      a <- atomically $ newXFTPAgent defaultXFTPClientAgentConfig
      liftIO $ printNoNewLine "Downloading file..."
      downloadedChunks <- newTVarIO []
      let srv FileChunk {replicas} = case replicas of
            [] -> error "empty FileChunk.replicas"
            FileChunkReplica {server} : _ -> server
          srvChunks = groupAllOn srv chunks
      chunkPaths <- map snd . sortOn fst . concat <$> pooledForConcurrentlyN 16 srvChunks (mapM $ downloadFileChunk a encPath size downloadedChunks)
      encDigest <- liftIO $ LC.sha512Hash <$> readChunks chunkPaths
      when (encDigest /= unFileDigest digest) $ throwError $ CLIError "File digest mismatch"
      encSize <- liftIO $ foldM (\s path -> (s +) . fromIntegral <$> getFileSize path) 0 chunkPaths
      when (FileSize encSize /= size) $ throwError $ CLIError "File size mismatch"
      liftIO $ printNoNewLine "Decrypting file..."
      CryptoFile path _ <- withExceptT cliCryptoError $ decryptChunks encSize chunkPaths key nonce $ fmap CF.plain . getFilePath
      forM_ chunks $ acknowledgeFileChunk a
      whenM (doesPathExist encPath) $ removeDirectoryRecursive encPath
      liftIO $ do
        printNoNewLine $ "File downloaded: " <> path
        removeFD yes fileDescription
    downloadFileChunk :: XFTPClientAgent -> FilePath -> FileSize Int64 -> TVar [Int64] -> FileChunk -> ExceptT CLIError IO (Int, FilePath)
    downloadFileChunk a encPath (FileSize encSize) downloadedChunks FileChunk {chunkNo, chunkSize, digest, replicas = replica : _} = do
      let FileChunkReplica {server, replicaId, replicaKey} = replica
      logInfo $ "downloading chunk " <> tshow chunkNo <> " from " <> showServer server <> "..."
      chunkPath <- uniqueCombine encPath $ show chunkNo
      let chunkSpec = XFTPRcvChunkSpec chunkPath (unFileSize chunkSize) (unFileDigest digest)
      withReconnect a server retryCount $ \c -> downloadXFTPChunk c replicaKey (unChunkReplicaId replicaId) chunkSpec
      logInfo $ "downloaded chunk " <> tshow chunkNo <> " to " <> T.pack chunkPath
      downloaded <- atomically . stateTVar downloadedChunks $ \cs ->
        let cs' = fromIntegral (unFileSize chunkSize) : cs in (sum cs', cs')
      liftIO $ do
        printProgress "Downloaded" downloaded encSize
        when verbose $ putStrLn ""
      pure (chunkNo, chunkPath)
    downloadFileChunk _ _ _ _ _ = throwError $ CLIError "chunk has no replicas"
    getFilePath :: String -> ExceptT String IO FilePath
    getFilePath name =
      case filePath of
        Just path ->
          ifM (doesDirectoryExist path) (uniqueCombine path name) $
            ifM (doesFileExist path) (throwError "File already exists") (pure path)
        _ -> (`uniqueCombine` name) . (</> "Downloads") =<< getHomeDirectory
    acknowledgeFileChunk :: XFTPClientAgent -> FileChunk -> ExceptT CLIError IO ()
    acknowledgeFileChunk a FileChunk {replicas = replica : _} = do
      let FileChunkReplica {server, replicaId, replicaKey} = replica
      c <- withRetry retryCount $ getXFTPServerClient a server
      withRetry retryCount $ ackXFTPChunk c replicaKey (unChunkReplicaId replicaId)
    acknowledgeFileChunk _ _ = throwError $ CLIError "chunk has no replicas"

printProgress :: String -> Int64 -> Int64 -> IO ()
printProgress s part total = printNoNewLine $ s <> " " <> show ((part * 100) `div` total) <> "%"

printNoNewLine :: String -> IO ()
printNoNewLine s = do
  putStr $ s <> replicate (max 0 $ 25 - length s) ' ' <> "\r"
  hFlush stdout

cliDeleteFile :: DeleteOptions -> ExceptT CLIError IO ()
cliDeleteFile DeleteOptions {fileDescription, retryCount, yes} = do
  getFileDescription' fileDescription >>= deleteFile
  where
    deleteFile :: ValidFileDescription 'FSender -> ExceptT CLIError IO ()
    deleteFile (ValidFileDescription FileDescription {chunks}) = do
      a <- atomically $ newXFTPAgent defaultXFTPClientAgentConfig
      forM_ chunks $ deleteFileChunk a
      liftIO $ do
        printNoNewLine "File deleted!"
        removeFD yes fileDescription
    deleteFileChunk :: XFTPClientAgent -> FileChunk -> ExceptT CLIError IO ()
    deleteFileChunk a FileChunk {chunkNo, replicas = replica : _} = do
      let FileChunkReplica {server, replicaId, replicaKey} = replica
      withReconnect a server retryCount $ \c -> deleteXFTPChunk c replicaKey (unChunkReplicaId replicaId)
      logInfo $ "deleted chunk " <> tshow chunkNo <> " from " <> showServer server
    deleteFileChunk _ _ = throwError $ CLIError "chunk has no replicas"

cliFileDescrInfo :: InfoOptions -> ExceptT CLIError IO ()
cliFileDescrInfo InfoOptions {fileDescription} = do
  getFileDescription fileDescription >>= \case
    AVFD (ValidFileDescription FileDescription {party, size, chunkSize, chunks}) -> do
      let replicas = groupReplicasByServer chunkSize chunks
      liftIO $ do
        printParty
        putStrLn $ "File download size: " <> strEnc size
        putStrLn "File server(s):"
        forM_ replicas $ \srvReplicas@(FileServerReplica {server} :| _) -> do
          let chSizes = fmap (\FileServerReplica {chunkSize = chSize_} -> unFileSize $ fromMaybe chunkSize chSize_) srvReplicas
          putStrLn $ strEnc server <> ": " <> strEnc (FileSize $ sum chSizes)
      where
        printParty :: IO ()
        printParty = case party of
          SFRecipient -> putStrLn "Recipient file description"
          SFSender -> putStrLn "Sender file description"

strEnc :: StrEncoding a => a -> String
strEnc = B.unpack . strEncode

getFileDescription :: FilePath -> ExceptT CLIError IO AValidFileDescription
getFileDescription path =
  ExceptT $ first (CLIError . ("Failed to parse file description: " <>)) . strDecode <$> B.readFile path

getFileDescription' :: FilePartyI p => FilePath -> ExceptT CLIError IO (ValidFileDescription p)
getFileDescription' path =
  getFileDescription path >>= \case
    AVFD fd -> either (throwError . CLIError) pure $ checkParty fd

prepareChunkSizes :: Int64 -> [Word32]
prepareChunkSizes size' = prepareSizes size'
  where
    (smallSize, bigSize)
      | size' > size34 chunkSize3 = (chunkSize2, chunkSize3)
      | otherwise = (chunkSize1, chunkSize2)
    --  | size' > size34 chunkSize2 = (chunkSize1, chunkSize2)
    --  | otherwise = (chunkSize0, chunkSize1)
    size34 sz = (fromIntegral sz * 3) `div` 4
    prepareSizes 0 = []
    prepareSizes size
      | size >= fromIntegral bigSize = replicate (fromIntegral n1) bigSize <> prepareSizes remSz
      | size > size34 bigSize = [bigSize]
      | otherwise = replicate (fromIntegral n2') smallSize
      where
        (n1, remSz) = size `divMod` fromIntegral bigSize
        n2' = let (n2, remSz2) = (size `divMod` fromIntegral smallSize) in if remSz2 == 0 then n2 else n2 + 1

prepareChunkSpecs :: FilePath -> [Word32] -> [XFTPChunkSpec]
prepareChunkSpecs filePath chunkSizes = reverse . snd $ foldl' addSpec (0, []) chunkSizes
  where
    addSpec :: (Int64, [XFTPChunkSpec]) -> Word32 -> (Int64, [XFTPChunkSpec])
    addSpec (chunkOffset, specs) sz =
      let spec = XFTPChunkSpec {filePath, chunkOffset, chunkSize = fromIntegral sz}
       in (chunkOffset + fromIntegral sz, spec : specs)

getEncPath :: MonadIO m => Maybe FilePath -> String -> m FilePath
getEncPath path name = (`uniqueCombine` (name <> ".encrypted")) =<< maybe (liftIO getCanonicalTemporaryDirectory) pure path

withReconnect :: Show e => XFTPClientAgent -> XFTPServer -> Int -> (XFTPClient -> ExceptT e IO a) -> ExceptT CLIError IO a
withReconnect a srv n run = withRetry n $ do
  c <- withRetry n $ getXFTPServerClient a srv
  withExceptT (CLIError . show) (run c) `catchError` \e -> do
    liftIO $ closeXFTPServerClient a srv
    throwError e

withRetry :: Show e => Int -> ExceptT e IO a -> ExceptT CLIError IO a
withRetry retryCount = withRetry' retryCount . withExceptT (CLIError . show)
  where
    withRetry' :: Int -> ExceptT CLIError IO a -> ExceptT CLIError IO a
    withRetry' 0 _ = throwError $ CLIError "internal: no retry attempts"
    withRetry' 1 a = a
    withRetry' n a =
      a `catchError` \e -> do
        logWarn ("retrying: " <> tshow e)
        withRetry' (n - 1) a

removeFD :: Bool -> FilePath -> IO ()
removeFD yes fd
  | yes = do
      removeFile fd
      putStrLn $ "\nFile description " <> fd <> " is deleted."
  | otherwise = do
      y <- liftIO . getConfirmation $ "\nFile description " <> fd <> " can't be used again. Delete it"
      when y $ removeFile fd

getConfirmation :: String -> IO Bool
getConfirmation prompt = do
  putStr $ prompt <> " (Y/n): "
  hFlush stdout
  s <- getLine
  case map toLower s of
    "y" -> pure True
    "" -> pure True
    "n" -> pure False
    _ -> getConfirmation prompt

cliRandomFile :: RandomFileOptions -> IO ()
cliRandomFile RandomFileOptions {filePath, fileSize = FileSize size} = do
  withFile filePath WriteMode (`saveRandomFile` size)
  putStrLn $ "File created: " <> filePath
  where
    saveRandomFile h sz = do
      bytes <- getRandomBytes $ fromIntegral $ min mb' sz
      B.hPut h bytes
      when (sz > mb') $ saveRandomFile h (sz - mb')
    mb' = mb 1
