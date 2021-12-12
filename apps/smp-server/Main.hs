{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

module Main where

import Control.Monad.Except
import Control.Monad.Trans.Except
import qualified Crypto.Store.PKCS8 as S
import Data.ByteString.Base64 (encode)
import qualified Data.ByteString.Char8 as B
import Data.Char (toLower)
import Data.Ini (Ini, lookupValue, readIniFile)
import Data.Text (Text)
import qualified Data.Text as T
import Data.X509 (PrivKey (PrivKeyRSA))
import Network.Socket (ServiceName)
import Options.Applicative
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Server (runSMPServer)
import Simplex.Messaging.Server.Env.STM
import Simplex.Messaging.Server.StoreLog (StoreLog, openReadStoreLog, storeLogFilePath)
import Simplex.Messaging.Transport (ATransport (..), TCP, Transport (..))
import Simplex.Messaging.Transport.WebSockets (WS)
import System.Directory (createDirectoryIfMissing, doesFileExist, removeFile)
import System.Exit (exitFailure)
import System.FilePath (combine)
import System.IO (IOMode (..), hFlush, stdout)
import Text.Read (readEither)

defaultServerPort :: ServiceName
defaultServerPort = "5223"

defaultBlockSize :: Int
defaultBlockSize = 4096

serverConfig :: ServerConfig
serverConfig =
  ServerConfig
    { tbqSize = 16,
      msgQueueQuota = 256,
      queueIdBytes = 12,
      msgIdBytes = 6,
      trnSignAlg = C.SignAlg C.SEd448,
      -- below parameters are set based on ini file /etc/opt/simplex/smp-server.ini
      transports = undefined,
      storeLog = undefined,
      blockSize = undefined,
      serverPrivateKey = undefined
    }

newKeySize :: Int
newKeySize = 2048 `div` 8

cfgDir :: FilePath
cfgDir = "/etc/opt/simplex"

logDir :: FilePath
logDir = "/var/opt/simplex"

defaultStoreLogFile :: FilePath
defaultStoreLogFile = combine logDir "smp-server-store.log"

iniFile :: FilePath
iniFile = combine cfgDir "smp-server.ini"

defaultKeyFile :: FilePath
defaultKeyFile = combine cfgDir "server_key"

main :: IO ()
main = do
  opts <- getServerOpts
  case serverCommand opts of
    ServerInit ->
      runExceptT (getConfig opts) >>= \case
        Right cfg -> do
          putStrLn "Error: server is already initialized. Start it with `smp-server start` command"
          printConfig cfg
          exitFailure
        Left _ -> do
          cfg <- initializeServer opts
          putStrLn "Server was initialized. Start it with `smp-server start` command"
          printConfig cfg
    ServerStart ->
      runExceptT (getConfig opts) >>= \case
        Right cfg -> runServer cfg
        Left e -> do
          putStrLn $ "Server is not initialized: " <> e
          putStrLn "Initialize server with `smp-server init` command"
          exitFailure
    ServerDelete -> do
      deleteServer
      putStrLn "Server key, config file and store log deleted"

getConfig :: ServerOpts -> ExceptT String IO ServerConfig
getConfig opts = do
  ini <- readIni
  pk <- readKey ini
  storeLog <- liftIO $ openStoreLog opts ini
  pure $ makeConfig ini pk storeLog

makeConfig :: IniOpts -> C.PrivateKey 'C.RSA -> Maybe (StoreLog 'ReadMode) -> ServerConfig
makeConfig IniOpts {serverPort, blockSize, enableWebsockets} pk storeLog =
  let transports = (serverPort, transport @TCP) : [("80", transport @WS) | enableWebsockets]
   in serverConfig {serverPrivateKey = pk, storeLog, blockSize, transports}

printConfig :: ServerConfig -> IO ()
printConfig ServerConfig {serverPrivateKey, storeLog} = do
  B.putStrLn $ "transport key hash: " <> serverKeyHash serverPrivateKey
  putStrLn $ case storeLog of
    Just s -> "store log: " <> storeLogFilePath s
    Nothing -> "store log disabled"

initializeServer :: ServerOpts -> IO ServerConfig
initializeServer opts = do
  createDirectoryIfMissing False cfgDir
  ini <- createIni opts
  pk <- createKey ini
  storeLog <- openStoreLog opts ini
  pure $ makeConfig ini pk storeLog

runServer :: ServerConfig -> IO ()
runServer cfg = do
  printConfig cfg
  forM_ (transports cfg) $ \(port, ATransport t) ->
    putStrLn $ "listening on port " <> port <> " (" <> transportName t <> ")"
  runSMPServer cfg

deleteServer :: IO ()
deleteServer = do
  ini <- runExceptT readIni
  deleteIfExists iniFile
  case ini of
    Right IniOpts {storeLogFile, serverKeyFile} -> do
      deleteIfExists storeLogFile
      deleteIfExists serverKeyFile
    Left _ -> do
      deleteIfExists defaultKeyFile
      deleteIfExists defaultStoreLogFile

data IniOpts = IniOpts
  { enableStoreLog :: Bool,
    storeLogFile :: FilePath,
    serverKeyFile :: FilePath,
    serverPort :: ServiceName,
    blockSize :: Int,
    enableWebsockets :: Bool
  }

readIni :: ExceptT String IO IniOpts
readIni = do
  fileExists iniFile
  ini <- ExceptT $ readIniFile iniFile
  let enableStoreLog = (== Right "on") $ lookupValue "STORE_LOG" "enable" ini
      storeLogFile = opt defaultStoreLogFile "STORE_LOG" "file" ini
      serverKeyFile = opt defaultKeyFile "TRANSPORT" "key_file" ini
      serverPort = opt defaultServerPort "TRANSPORT" "port" ini
      enableWebsockets = (== Right "on") $ lookupValue "TRANSPORT" "websockets" ini
  blockSize <- liftEither . readEither $ opt (show defaultBlockSize) "TRANSPORT" "block_size" ini
  pure IniOpts {enableStoreLog, storeLogFile, serverKeyFile, serverPort, blockSize, enableWebsockets}
  where
    opt :: String -> Text -> Text -> Ini -> String
    opt def section key ini = either (const def) T.unpack $ lookupValue section key ini

createIni :: ServerOpts -> IO IniOpts
createIni ServerOpts {enableStoreLog} = do
  writeFile iniFile $
    "[STORE_LOG]\n\
    \# The server uses STM memory to store SMP queues and messages,\n\
    \# that will be lost on restart (e.g., as with redis).\n\
    \# This option enables saving SMP queues to append only log,\n\
    \# and restoring them when the server is started.\n\
    \# Log is compacted on start (deleted queues are removed).\n\
    \# The messages in the queues are not logged.\n\n"
      <> (if enableStoreLog then "" else "# ")
      <> "enable: on\n\
         \# file: "
      <> defaultStoreLogFile
      <> "\n\n\
         \[TRANSPORT]\n\n\
         \# key_file: "
      <> defaultKeyFile
      <> "\n\
         \# port: "
      <> defaultServerPort
      <> "\n\
         \# block_size: "
      <> show defaultBlockSize
      <> "\n\
         \websockets: on\n"
  pure
    IniOpts
      { enableStoreLog,
        storeLogFile = defaultStoreLogFile,
        serverKeyFile = defaultKeyFile,
        serverPort = defaultServerPort,
        blockSize = defaultBlockSize,
        enableWebsockets = True
      }

readKey :: IniOpts -> ExceptT String IO (C.PrivateKey 'C.RSA)
readKey IniOpts {serverKeyFile} = do
  fileExists serverKeyFile
  liftIO (S.readKeyFile serverKeyFile) >>= \case
    [S.Unprotected (PrivKeyRSA pk)] -> pure $ C.PrivateKeyRSA pk
    [_] -> err "not RSA key"
    [] -> err "invalid key file format"
    _ -> err "more than one key"
  where
    err :: String -> ExceptT String IO b
    err e = throwE $ e <> ": " <> serverKeyFile

createKey :: IniOpts -> IO (C.PrivateKey 'C.RSA)
createKey IniOpts {serverKeyFile} = do
  (_, pk) <- C.generateKeyPair' newKeySize
  S.writeKeyFile S.TraditionalFormat serverKeyFile [C.privateToX509 pk]
  pure pk

fileExists :: FilePath -> ExceptT String IO ()
fileExists path = do
  exists <- liftIO $ doesFileExist path
  unless exists . throwE $ "file " <> path <> " not found"

deleteIfExists :: FilePath -> IO ()
deleteIfExists path = doesFileExist path >>= (`when` removeFile path)

confirm :: String -> IO ()
confirm msg = do
  putStr $ msg <> " (y/N): "
  hFlush stdout
  ok <- getLine
  when (map toLower ok /= "y") exitFailure

serverKeyHash :: C.PrivateKey 'C.RSA -> B.ByteString
serverKeyHash = encode . C.unKeyHash . C.publicKeyHash . C.publicKey

openStoreLog :: ServerOpts -> IniOpts -> IO (Maybe (StoreLog 'ReadMode))
openStoreLog ServerOpts {enableStoreLog = l} IniOpts {enableStoreLog = l', storeLogFile = f}
  | l || l' = do
    createDirectoryIfMissing True logDir
    Just <$> openReadStoreLog f
  | otherwise = pure Nothing

data ServerOpts = ServerOpts
  { serverCommand :: ServerCommand,
    enableStoreLog :: Bool
  }

data ServerCommand = ServerInit | ServerStart | ServerDelete

serverOpts :: Parser ServerOpts
serverOpts =
  ServerOpts
    <$> subparser
      ( command "init" (info (pure ServerInit) (progDesc "Initialize server: generate server key and ini file"))
          <> command "start" (info (pure ServerStart) (progDesc "Start server (ini: /etc/opt/simplex/smp-server.ini)"))
          <> command "delete" (info (pure ServerDelete) (progDesc "Delete server key, ini file and store log"))
      )
    <*> switch
      ( long "store-log"
          <> short 'l'
          <> help "enable store log for SMP queues persistence"
      )

getServerOpts :: IO ServerOpts
getServerOpts = customExecParser p opts
  where
    p = prefs showHelpOnEmpty
    opts =
      info
        (serverOpts <**> helper)
        ( fullDesc
            <> header "Simplex Messaging Protocol (SMP) Server"
        )
