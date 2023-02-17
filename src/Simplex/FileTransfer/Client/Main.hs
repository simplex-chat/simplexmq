{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Simplex.FileTransfer.Client.Main (xftpClientCLI) where

import Control.Concurrent.STM (stateTVar)
import Control.Monad
import Control.Monad.Except
import Crypto.Random (getRandomBytes)
import qualified Data.Attoparsec.ByteString.Char8 as A
import Data.Bifunctor (first)
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import qualified Data.ByteString.Lazy.Char8 as LB
import Data.Int (Int64)
import Data.List (foldl', sortOn)
import Data.List.NonEmpty (NonEmpty (..), nonEmpty)
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
import qualified Simplex.Messaging.Crypto.Lazy as LC
import Simplex.Messaging.Encoding
import Simplex.Messaging.Encoding.String (StrEncoding (..))
import Simplex.Messaging.Parsers (parseAll)
import Simplex.Messaging.Protocol (SenderId, SndPrivateSignKey, SndPublicVerifyKey, XFTPServer)
import Simplex.Messaging.Server.CLI (getCliCommand')
import Simplex.Messaging.Util (ifM, whenM)
import System.Exit (exitFailure)
import System.FilePath (splitExtensions, splitFileName, (</>))
import System.IO.Temp (getCanonicalTemporaryDirectory)
import System.Random (StdGen, newStdGen, randomR)
import UnliftIO
import UnliftIO.Directory

xftpClientVersion :: String
xftpClientVersion = "0.1.0"

defaultChunkSize :: Word32
defaultChunkSize = 8 * mb

smallChunkSize :: Word32
smallChunkSize = 1 * mb

fileSizeLen :: Int64
fileSizeLen = 8

cbAuthTagLen :: Int64
cbAuthTagLen = fromIntegral C.cbAuthTagSize

mb :: Num a => a
mb = 1024 * 1024

newtype CLIError = CLIError String
  deriving (Eq, Show, Exception)

data CliCommand
  = SendFile SendOptions
  | ReceiveFile ReceiveOptions
  | RandomFile RandomFileOptions
  | FileDescrInfo InfoOptions

data SendOptions = SendOptions
  { filePath :: FilePath,
    outputDir :: Maybe FilePath,
    numRecipients :: Int,
    xftpServers :: [XFTPServer],
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

newtype InfoOptions = InfoOptions
  { fileDescription :: FilePath
  }
  deriving (Show)

data RandomFileOptions = RandomFileOptions
  { filePath :: FilePath,
    fileSize :: FileSize Int
  }
  deriving (Show)

defaultRetryCount :: Int
defaultRetryCount = 3

defaultXFTPServers :: NonEmpty XFTPServer
defaultXFTPServers = L.fromList ["xftp://vr0bXzm4iKkLvleRMxLznTS-lHjXEyXunxn_7VJckk4=@localhost:443"]

cliCommandP :: Parser CliCommand
cliCommandP =
  hsubparser
    ( command "send" (info (SendFile <$> sendP) (progDesc "Send file"))
        <> command "recv" (info (ReceiveFile <$> receiveP) (progDesc "Receive file"))
        <> command "info" (info (FileDescrInfo <$> infoP) (progDesc "Show file description"))
        <> command "rand" (info (RandomFile <$> randomP) (progDesc "Generate a random file of a given size"))
    )
  where
    sendP :: Parser SendOptions
    sendP =
      SendOptions
        <$> argument str (metavar "FILE" <> help "File to send")
        <*> optional (argument str $ metavar "DIR" <> help "Directory to save file descriptions (default: current directory)")
        <*> option auto (short 'n' <> metavar "COUNT" <> help "Number of recipients" <> value 1 <> showDefault)
        <*> xftpServers
        <*> retries
        <*> temp
    receiveP :: Parser ReceiveOptions
    receiveP =
      ReceiveOptions
        <$> fileDescrArg
        <*> optional (argument str $ metavar "DIR" <> help "Directory to save file (default: system Downloads directory)")
        <*> retries
        <*> temp
    infoP :: Parser InfoOptions
    infoP = InfoOptions <$> fileDescrArg
    randomP :: Parser RandomFileOptions
    randomP =
      RandomFileOptions
        <$> argument str (metavar "FILE" <> help "Path to save file")
        <*> argument strDec (metavar "SIZE" <> help "File size (bytes/kb/mb)")
    strDec = eitherReader $ strDecode . B.pack
    fileDescrArg = argument str (metavar "FILE" <> help "File description file")
    retries = option auto (long "retry" <> short 'r' <> metavar "RETRY" <> help "Number of network retries" <> value defaultRetryCount <> showDefault)
    temp = optional (strOption $ long "tmp" <> metavar "TMP" <> help "Directory for temporary encrypted file (default: system temp directory)")
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
    FileDescrInfo opts -> runE $ cliFileDescrInfo opts
    RandomFile opts -> cliRandomFile opts
  where
    clientVersion = "SimpleX XFTP client v" <> xftpClientVersion

runE :: ExceptT CLIError IO () -> IO ()
runE a =
  runExceptT a >>= \case
    Left (CLIError e) -> putStrLn e >> exitFailure
    _ -> pure ()

-- fileExtra is added to allow header extension in future versions
data FileHeader = FileHeader
  { fileName :: String,
    fileExtra :: Maybe String
  }
  deriving (Eq, Show)

instance Encoding FileHeader where
  smpEncode FileHeader {fileName, fileExtra} = smpEncode (fileName, fileExtra)
  smpP = do
    (fileName, fileExtra) <- smpP
    pure FileHeader {fileName, fileExtra}

cliSendFile :: SendOptions -> ExceptT CLIError IO ()
cliSendFile SendOptions {filePath, outputDir, numRecipients, xftpServers, retryCount, tempPath} = do
  let (_, fileName) = splitFileName filePath
  (encPath, fd, chunkSpecs) <- encryptFile fileName
  sentChunks <- uploadFile chunkSpecs
  whenM (doesFileExist encPath) $ removeFile encPath
  -- TODO if only small chunks, use different default size
  liftIO $ do
    fds <- writeFileDescriptions fileName $ createFileDescriptions fd sentChunks
    putStrLn "File uploaded!\nPass file descriptions to the recipient(s):"
    forM_ fds putStrLn
  where
    encryptFile :: String -> ExceptT CLIError IO (FilePath, FileDescription, [XFTPChunkSpec])
    encryptFile fileName = do
      encPath <- getEncPath tempPath "xftp"
      key <- liftIO C.randomSbKey
      nonce <- liftIO C.randomCbNonce
      fileSize <- fromInteger <$> getFileSize filePath
      let fileHdr = smpEncode FileHeader {fileName, fileExtra = Nothing}
          fileSize' = fromIntegral (B.length fileHdr) + fileSize
          chunkSizes = prepareChunkSizes $ fileSize' + fileSizeLen + cbAuthTagLen
          paddedSize = fromIntegral $ sum chunkSizes
      encrypt fileHdr key nonce fileSize' paddedSize encPath
      digest <- liftIO $ LC.sha512Hash <$> LB.readFile encPath
      let chunkSpecs = prepareChunkSpecs encPath chunkSizes
          fd = FileDescription {size = FileSize paddedSize, digest = FileDigest digest, key, nonce, chunkSize = FileSize defaultChunkSize, chunks = []}
      pure (encPath, fd, chunkSpecs)
      where
        encrypt :: ByteString -> C.SbKey -> C.CbNonce -> Int64 -> Int64 -> FilePath -> ExceptT CLIError IO ()
        encrypt fileHdr key nonce fileSize' paddedSize encFile = do
          f <- liftIO $ LB.readFile filePath
          let f' = LB.fromStrict fileHdr <> f
          c <- liftEither $ first (CLIError . show) $ LC.sbEncrypt key nonce f' fileSize' $ paddedSize - cbAuthTagLen
          liftIO $ LB.writeFile encFile c
    -- let padSize = paddedSize - fileSize - fromIntegral (B.length fileHdr)
    -- when (padSize > 0) . LB.hPut h $ LB.replicate padSize '#'
    uploadFile :: [XFTPChunkSpec] -> ExceptT CLIError IO [SentFileChunk]
    uploadFile chunks = do
      a <- atomically $ newXFTPAgent defaultXFTPClientAgentConfig
      gen <- newTVarIO =<< liftIO newStdGen
      let xftpSrvs = fromMaybe defaultXFTPServers (nonEmpty xftpServers)
      -- TODO shuffle chunks
      sentChunks <- pooledForConcurrentlyN 32 (zip [1 ..] chunks) $ uploadFileChunk a gen xftpSrvs
      -- TODO unshuffle chunks
      pure $ map snd sentChunks
      where
        retries :: Show e => ExceptT e IO a -> ExceptT CLIError IO a
        retries = withRetry retryCount . withExceptT (CLIError . show)
        uploadFileChunk :: XFTPClientAgent -> TVar StdGen -> NonEmpty XFTPServer -> (Int, XFTPChunkSpec) -> ExceptT CLIError IO (Int, SentFileChunk)
        uploadFileChunk a gen srvs (chunkNo, chunkSpec@XFTPChunkSpec {chunkSize}) = do
          (sndKey, spKey) <- liftIO $ C.generateSignatureKeyPair C.SEd25519
          rKeys <- liftIO $ L.fromList <$> replicateM numRecipients (C.generateSignatureKeyPair C.SEd25519)
          chInfo@FileInfo {digest} <- liftIO $ getChunkInfo sndKey chunkSpec
          xftpServer <- liftIO $ getXFTPServer gen srvs
          c <- retries $ getXFTPServerClient a xftpServer
          (sndId, rIds) <- retries $ createXFTPChunk c spKey chInfo $ L.map fst rKeys
          retries $ uploadXFTPChunk c spKey sndId chunkSpec
          let recipients = L.toList $ L.map ChunkReplicaId rIds `L.zip` L.map snd rKeys
              replicas = [SentFileChunkReplica {server = xftpServer, recipients}]
          pure (chunkNo, SentFileChunk {chunkNo, sndId, sndPrivateKey = spKey, chunkSize = FileSize $ fromIntegral chunkSize, digest = FileDigest digest, replicas})
        getChunkInfo :: SndPublicVerifyKey -> XFTPChunkSpec -> IO FileInfo
        getChunkInfo sndKey XFTPChunkSpec {filePath = chunkPath, chunkOffset, chunkSize} =
          withFile chunkPath ReadMode $ \h -> do
            hSeek h AbsoluteSeek $ fromIntegral chunkOffset
            digest <- LC.sha512Hash <$> LB.hGet h (fromIntegral chunkSize)
            pure FileInfo {sndKey, size = fromIntegral chunkSize, digest}
        getXFTPServer :: TVar StdGen -> NonEmpty XFTPServer -> IO XFTPServer
        getXFTPServer gen = \case
          srv :| [] -> pure srv
          servers -> do
            atomically $ (servers L.!!) <$> stateTVar gen (randomR (0, L.length servers - 1))

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
    writeFileDescriptions :: String -> [FileDescription] -> IO [FilePath]
    writeFileDescriptions fileName fds = do
      outDir <- uniqueCombine (fromMaybe "." outputDir) (fileName <> ".xftp")
      createDirectoryIfMissing True outDir
      forM (zip [1 ..] fds) $ \(i :: Int, fd) -> do
        let fdPath = outDir </> ("rcv" <> show i <> ".xftp")
        B.writeFile fdPath $ strEncode fd
        pure fdPath

cliReceiveFile :: ReceiveOptions -> ExceptT CLIError IO ()
cliReceiveFile ReceiveOptions {fileDescription, filePath, retryCount, tempPath} = do
  ValidFileDescription FileDescription {size, digest, key, nonce, chunks} <- getFileDescription fileDescription
  encPath <- getEncPath tempPath "xftp"
  -- withFile encPath WriteMode $ \h -> do
  --   liftIO $ LB.hPut h $ LB.replicate (unFileSize size) '#'
  a <- atomically $ newXFTPAgent defaultXFTPClientAgentConfig
  writeLock <- atomically createLock
  let chunkSizes = prepareChunkSizes $ unFileSize size
      chunkSpecs = prepareChunkSpecs encPath chunkSizes
  -- chunks have to be ordered because of AppendMode
  forM_ (zip chunkSpecs chunks) $ \(chunkSpec, chunk) -> do
    downloadFileChunk a writeLock chunk chunkSpec
  encDigest <- liftIO $ LC.sha512Hash <$> LB.readFile encPath
  when (encDigest /= unFileDigest digest) $ throwError $ CLIError "File digest mismatch"
  path <- decryptFile encPath key nonce
  whenM (doesFileExist encPath) $ removeFile encPath
  liftIO $ putStrLn $ "File received: " <> path
  where
    retries :: Show e => ExceptT e IO a -> ExceptT CLIError IO a
    retries = withRetry retryCount . withExceptT (CLIError . show)
    downloadFileChunk :: XFTPClientAgent -> Lock -> FileChunk -> XFTPChunkSpec -> ExceptT CLIError IO ()
    downloadFileChunk a writeLock FileChunk {replicas = replica : _} chunkSpec = do
      let FileChunkReplica {server, rcvId, rcvKey} = replica
      c <- retries $ getXFTPServerClient a server
      (rKey, rpKey) <- liftIO C.generateKeyPair'
      (sKey, body) <- retries $ downloadXFTPChunk c rcvKey (unChunkReplicaId rcvId) rKey
      -- download and decrypt (DH) chunk from server using XFTPClient
      -- verify chunk digest - in the client
      -- save to correct location in file - also in the client
      retries $ withLock writeLock "save" $ receiveXFTPChunk body chunkSpec
    downloadFileChunk _ _ _ _ = pure ()
    decryptFile :: FilePath -> C.SbKey -> C.CbNonce -> ExceptT CLIError IO FilePath
    decryptFile encPath key nonce = do
      f <- liftIO $ LB.readFile encPath
      f' <- liftEither $ first (CLIError . show) $ LC.sbDecrypt key nonce f
      let (fileHdr, f'') = LB.splitAt 1024 f'
      -- withFile encPath ReadMode $ \r -> do
      --   fileHdr <- liftIO $ B.hGet r 1024
      case A.parse smpP $ LB.toStrict fileHdr of
        A.Fail _ _ e -> throwError $ CLIError $ "Invalid file header: " <> e
        A.Partial _ -> throwError $ CLIError "Invalid file header"
        A.Done rest FileHeader {fileName} -> do
          path <- getFilePath fileName
          liftIO $ LB.writeFile path $ LB.fromStrict rest <> f''
          pure path
    getFilePath :: String -> ExceptT CLIError IO FilePath
    getFilePath name =
      case filePath of
        Just path ->
          ifM (doesDirectoryExist path) (uniqueCombine path name) $
            ifM (doesFileExist path) (throwError $ CLIError "File already exists") (pure path)
        _ -> (`uniqueCombine` name) . (</> "Downloads") =<< getHomeDirectory

cliFileDescrInfo :: InfoOptions -> ExceptT CLIError IO ()
cliFileDescrInfo InfoOptions {fileDescription} = do
  ValidFileDescription FileDescription {size, chunkSize, chunks} <- getFileDescription fileDescription
  let replicas = groupReplicasByServer chunkSize chunks
  liftIO $ do
    putStrLn $ "File download size: " <> strEnc size
    putStrLn "File server(s):"
    forM_ replicas $ \srvReplicas -> do
      let srv = replicaServer $ head srvReplicas
          chSizes = map (\FileServerReplica {chunkSize = chSize_} -> unFileSize $ fromMaybe chunkSize chSize_) srvReplicas
      putStrLn $ strEnc srv <> ": " <> strEnc (FileSize $ sum chSizes)

strEnc :: StrEncoding a => a -> String
strEnc = B.unpack . strEncode

getFileDescription :: FilePath -> ExceptT CLIError IO ValidFileDescription
getFileDescription path = do
  fd <- ExceptT $ first (CLIError . ("Failed to parse file description: " <>)) . strDecode <$> B.readFile path
  liftEither . first CLIError $ validateFileDescription fd

prepareChunkSizes :: Int64 -> [Word32]
prepareChunkSizes 0 = []
prepareChunkSizes size
  | size >= defSz = replicate (fromIntegral n1) defaultChunkSize <> prepareChunkSizes remSz
  | size > defSz `div` 2 = [defaultChunkSize]
  | otherwise = replicate (fromIntegral n2') smallChunkSize
  where
    (n1, remSz) = size `divMod` defSz
    n2' = let (n2, remSz2) = (size `divMod` fromIntegral smallChunkSize) in if remSz2 == 0 then n2 else n2 + 1
    defSz = fromIntegral defaultChunkSize :: Int64

prepareChunkSpecs :: FilePath -> [Word32] -> [XFTPChunkSpec]
prepareChunkSpecs filePath chunkSizes = reverse . snd $ foldl' addSpec (0, []) chunkSizes
  where
    addSpec :: (Int64, [XFTPChunkSpec]) -> Word32 -> (Int64, [XFTPChunkSpec])
    addSpec (chunkOffset, specs) sz =
      let spec = XFTPChunkSpec {filePath, chunkOffset, chunkSize = fromIntegral sz}
       in (chunkOffset + fromIntegral sz, spec : specs)

getEncPath :: MonadIO m => Maybe FilePath -> String -> m FilePath
getEncPath path name = (`uniqueCombine` (name <> ".encrypted")) =<< maybe (liftIO getCanonicalTemporaryDirectory) pure path

uniqueCombine :: MonadIO m => FilePath -> String -> m FilePath
uniqueCombine filePath fileName = tryCombine (0 :: Int)
  where
    tryCombine n =
      let (name, ext) = splitExtensions fileName
          suffix = if n == 0 then "" else "_" <> show n
          f = filePath </> (name <> suffix <> ext)
       in ifM (doesPathExist f) (tryCombine $ n + 1) (pure f)

withRetry :: Int -> ExceptT CLIError IO a -> ExceptT CLIError IO a
withRetry 0 _ = throwError $ CLIError "internal: no retry attempts"
withRetry 1 a = a
withRetry n a = a `catchError` \_ -> withRetry (n - 1) a

cliRandomFile :: RandomFileOptions -> IO ()
cliRandomFile RandomFileOptions {filePath, fileSize = FileSize size} = do
  withFile filePath WriteMode (`saveRandomFile` size)
  putStrLn $ "File created: " <> filePath
  where
    saveRandomFile h sz = do
      bytes <- getRandomBytes $ min mb sz
      B.hPut h bytes
      when (sz > mb) $ saveRandomFile h (sz - mb)
