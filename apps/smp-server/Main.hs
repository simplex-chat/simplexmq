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
import Data.Ini (lookupValue, readIniFile)
import qualified Data.Text as T
import Data.X509 (PrivKey (PrivKeyRSA))
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

serverConfig :: ServerConfig
serverConfig =
  ServerConfig
    { transports = [("5223", transport @TCP), ("80", transport @WS)],
      tbqSize = 16,
      queueIdBytes = 12,
      msgIdBytes = 6,
      storeLog = Nothing,
      -- key is loaded from the file server_key in /etc/opt/simplex directory
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

keyFile :: FilePath
keyFile = combine cfgDir "server_key"

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
  pk <- readKey
  ini <- readIni
  storeLog <- liftIO $ openStoreLog opts ini
  pure serverConfig {serverPrivateKey = pk, storeLog}

printConfig :: ServerConfig -> IO ()
printConfig ServerConfig {serverPrivateKey, storeLog} = do
  B.putStrLn $ "transport key hash: " <> serverKeyHash serverPrivateKey
  putStrLn $ case storeLog of
    Just s -> "store log: " <> storeLogFilePath s
    Nothing -> "store log disabled"

initializeServer :: ServerOpts -> IO ServerConfig
initializeServer opts = do
  pk <- createKey
  ini <- createIni opts
  storeLog <- openStoreLog opts ini
  pure serverConfig {serverPrivateKey = pk, storeLog}

runServer :: ServerConfig -> IO ()
runServer cfg = do
  printConfig cfg
  forM_ (transports cfg) $ \(port, ATransport t) ->
    putStrLn $ "listening on port " <> port <> " (" <> transportName t <> ")"
  runSMPServer cfg

deleteServer :: IO ()
deleteServer = do
  ini <- runExceptT $ readIni
  deleteIfExists iniFile
  deleteIfExists keyFile
  deleteIfExists defaultStoreLogFile
  case ini of
    Right IniOpts {storeLogFile} -> deleteIfExists storeLogFile
    Left _ -> pure ()

data IniOpts = IniOpts
  { enableStoreLog :: Bool,
    storeLogFile :: FilePath
  }

readIni :: ExceptT String IO IniOpts
readIni = do
  fileExists iniFile
  ini <- ExceptT $ readIniFile iniFile
  let enableStoreLog = (== Right "on") $ lookupValue "STORE_LOG" "enable" ini
      storeLogFile = either (const defaultStoreLogFile) T.unpack $ lookupValue "STORE_LOG" "file" ini
  pure IniOpts {enableStoreLog, storeLogFile}

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
      <> "enable: on\n"
      <> "# file: "
      <> defaultStoreLogFile
      <> "\n"
  pure IniOpts {enableStoreLog, storeLogFile = defaultStoreLogFile}

readKey :: ExceptT String IO C.FullPrivateKey
readKey = do
  fileExists keyFile
  liftIO (S.readKeyFile keyFile) >>= \case
    [S.Unprotected (PrivKeyRSA pk)] -> pure $ C.FullPrivateKey pk
    [_] -> err "not RSA key"
    [] -> err "invalid key file format"
    _ -> err "more than one key"
  where
    err :: String -> ExceptT String IO b
    err e = throwE $ e <> ": " <> keyFile

createKey :: IO C.FullPrivateKey
createKey = do
  createDirectoryIfMissing True cfgDir
  (_, pk) <- C.generateKeyPair newKeySize
  S.writeKeyFile S.TraditionalFormat keyFile [PrivKeyRSA $ C.rsaPrivateKey pk]
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

serverKeyHash :: C.FullPrivateKey -> B.ByteString
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
          <> command "start" (info (pure ServerStart) (progDesc "Start server with config file INI_FILE"))
          <> command "delete" (info (pure ServerDelete) (progDesc "Delete server key, config file and store log"))
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
