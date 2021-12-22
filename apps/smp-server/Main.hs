{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

module Main where

import Control.Monad.Except
import Control.Monad.Trans.Except
import qualified Data.ByteString.Char8 as B
import Data.Char (toLower)
import Data.Ini (Ini, lookupValue, readIniFile)
import Data.List (dropWhileEnd)
import Data.Text (Text)
import qualified Data.Text as T
import Network.Socket (ServiceName)
import Options.Applicative
import Simplex.Messaging.Server (runSMPServer)
import Simplex.Messaging.Server.Env.STM
import Simplex.Messaging.Server.StoreLog (StoreLog, openReadStoreLog, storeLogFilePath)
import Simplex.Messaging.Transport (ATransport (..), TLS, Transport (..), getKeyHash)
import Simplex.Messaging.Transport.WebSockets (WS)
import System.Directory (createDirectoryIfMissing, doesFileExist, removeFile)
import System.Exit (exitFailure)
import System.FilePath (combine)
import System.IO (IOMode (..), hFlush, stdout)
import System.Process (readCreateProcess, shell)

defaultServerPort :: ServiceName
defaultServerPort = "5223"

serverConfig :: ServerConfig
serverConfig =
  ServerConfig
    { tbqSize = 16,
      serverTbqSize = 128,
      msgQueueQuota = 256,
      queueIdBytes = 24,
      msgIdBytes = 24, -- must be at least 24 bytes, it is used as 192-bit nonce for XSalsa20
      blockSize = 16 * 1024, -- TODO move to Protocol
      -- below parameters are set based on ini file /etc/opt/simplex/smp-server.ini
      transports = undefined,
      storeLog = undefined,
      serverPrivateKeyFile = undefined,
      serverCertificateFile = undefined
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

defaultPrivateKeyFile :: FilePath
defaultPrivateKeyFile = combine cfgDir "server.key"

defaultCertificateFile :: FilePath
defaultCertificateFile = combine cfgDir "server.crt"

certificateHashFile :: FilePath
certificateHashFile = combine cfgDir "crt_hash"

main :: IO ()
main = do
  opts <- getServerOpts
  checkPubkeyAlgorihtm $ pubkeyAlgorihtm opts
  case serverCommand opts of
    ServerInit ->
      runExceptT (getConfig opts) >>= \case
        Right cfg -> do
          putStrLn "Error: server is already initialized. Start it with `smp-server start` command"
          certificateHash <- loadCertificateHash
          printConfig cfg certificateHash
          exitFailure
        Left _ -> do
          cfg <- initializeServer opts
          putStrLn "Server was initialized. Start it with `smp-server start` command"
          certificateHash <- loadCertificateHash
          printConfig cfg certificateHash
    ServerStart ->
      runExceptT (getConfig opts) >>= \case
        Right cfg -> runServer cfg
        Left e -> do
          putStrLn $ "Server is not initialized: " <> e
          putStrLn "Initialize server with `smp-server init` command"
          exitFailure
    ServerDelete -> do
      deleteServer
      putStrLn "Server configuration and log files deleted"
  where
    checkPubkeyAlgorihtm :: String -> IO ()
    checkPubkeyAlgorihtm alg
      | alg == "ED448" || alg == "ED25519" = pure ()
      | otherwise = putStrLn ("unsupported public-key algorithm " <> alg) >> exitFailure

getConfig :: ServerOpts -> ExceptT String IO ServerConfig
getConfig opts = do
  ini <- readIni
  storeLog <- liftIO $ openStoreLog opts ini
  pure $ makeConfig ini storeLog

makeConfig :: IniOpts -> Maybe (StoreLog 'ReadMode) -> ServerConfig
makeConfig IniOpts {serverPort, enableWebsockets, serverPrivateKeyFile, serverCertificateFile} storeLog =
  let transports = (serverPort, transport @TLS) : [("80", transport @WS) | enableWebsockets]
   in serverConfig {transports, storeLog, serverPrivateKeyFile, serverCertificateFile}

printConfig :: ServerConfig -> String -> IO ()
printConfig ServerConfig {storeLog} certificateHash = do
  putStrLn $ "certificate hash: " <> certificateHash
  putStrLn $ case storeLog of
    Just s -> "store log: " <> storeLogFilePath s
    Nothing -> "store log disabled"

initializeServer :: ServerOpts -> IO ServerConfig
initializeServer opts = do
  createDirectoryIfMissing True cfgDir
  ini <- createIni opts
  createKeyAndCertificate ini opts
  saveCertificateHash $ serverCertificateFile (ini :: IniOpts)
  storeLog <- openStoreLog opts ini
  pure $ makeConfig ini storeLog

runServer :: ServerConfig -> IO ()
runServer cfg = do
  certificateHash <- loadCertificateHash
  checkStoredHash certificateHash
  printConfig cfg certificateHash
  forM_ (transports cfg) $ \(port, ATransport t) ->
    putStrLn $ "listening on port " <> port <> " (" <> transportName t <> ")"
  runSMPServer cfg
  where
    checkStoredHash :: String -> IO ()
    checkStoredHash storedHash = do
      computedHash <- getKeyHash $ serverCertificateFile (cfg :: ServerConfig)
      if storedHash == B.unpack computedHash
        then putStrLn "stored certificate hash is valid"
        else putStrLn "stored certificate hash is invalid" >> exitFailure

deleteServer :: IO ()
deleteServer = do
  ini <- runExceptT readIni
  deleteIfExists iniFile
  case ini of
    Right IniOpts {storeLogFile, serverPrivateKeyFile, serverCertificateFile} -> do
      deleteIfExists storeLogFile
      deleteIfExists serverPrivateKeyFile
      deleteIfExists serverCertificateFile
      deleteIfExists certificateHashFile
    Left _ -> do
      deleteIfExists defaultStoreLogFile
      deleteIfExists defaultPrivateKeyFile
      deleteIfExists defaultCertificateFile
      deleteIfExists certificateHashFile

data IniOpts = IniOpts
  { enableStoreLog :: Bool,
    storeLogFile :: FilePath,
    serverPort :: ServiceName,
    enableWebsockets :: Bool,
    serverPrivateKeyFile :: FilePath,
    serverCertificateFile :: FilePath
  }

readIni :: ExceptT String IO IniOpts
readIni = do
  fileExists iniFile
  ini <- ExceptT $ readIniFile iniFile
  let enableStoreLog = (== Right "on") $ lookupValue "STORE_LOG" "enable" ini
      storeLogFile = opt defaultStoreLogFile "STORE_LOG" "file" ini
      serverPort = opt defaultServerPort "TRANSPORT" "port" ini
      enableWebsockets = (== Right "on") $ lookupValue "TRANSPORT" "websockets" ini
      serverPrivateKeyFile = opt defaultPrivateKeyFile "TRANSPORT" "private_key_file" ini
      serverCertificateFile = opt defaultCertificateFile "TRANSPORT" "certificate_file" ini
  pure IniOpts {enableStoreLog, storeLogFile, serverPort, enableWebsockets, serverPrivateKeyFile, serverCertificateFile}
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
         \# private_key_file: "
      <> defaultPrivateKeyFile
      <> "\n\
         \# certificate_file: "
      <> defaultCertificateFile
      <> "\n\
         \# port: "
      <> defaultServerPort
      <> "\n\
         \websockets: on\n"
  pure
    IniOpts
      { enableStoreLog,
        storeLogFile = defaultStoreLogFile,
        serverPort = defaultServerPort,
        enableWebsockets = True,
        serverPrivateKeyFile = defaultPrivateKeyFile,
        serverCertificateFile = defaultCertificateFile
      }

-- To generate self-signed certificate:
-- https://blog.pinterjann.is/ed25519-certificates.html

createKeyAndCertificate :: IniOpts -> ServerOpts -> IO ()
createKeyAndCertificate IniOpts {serverPrivateKeyFile, serverCertificateFile} ServerOpts {pubkeyAlgorihtm} = do
  run $ "openssl genpkey -algorithm " <> pubkeyAlgorihtm <> " -out " <> serverPrivateKeyFile
  run $ "openssl req -new -key " <> serverPrivateKeyFile <> " -subj \"/CN=localhost\" -out " <> csrPath
  run $ "openssl x509 -req -days 999999 -in " <> csrPath <> " -signkey " <> serverPrivateKeyFile <> " -out " <> serverCertificateFile
  run $ "rm " <> csrPath
  where
    run :: String -> IO ()
    run cmd = void $ readCreateProcess (shell cmd) ""
    csrPath :: String
    csrPath = combine cfgDir "localhost.csr"

saveCertificateHash :: FilePath -> IO ()
saveCertificateHash serverCertificateFile = do
  certificateHash <- getKeyHash serverCertificateFile
  writeFile certificateHashFile $ B.unpack certificateHash <> "\n"

loadCertificateHash :: IO String
loadCertificateHash = do
  certificateHash <- readFile certificateHashFile
  pure $ dropWhileEnd (== '\n') certificateHash

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

openStoreLog :: ServerOpts -> IniOpts -> IO (Maybe (StoreLog 'ReadMode))
openStoreLog ServerOpts {enableStoreLog = l} IniOpts {enableStoreLog = l', storeLogFile = f}
  | l || l' = do
    createDirectoryIfMissing True logDir
    Just <$> openReadStoreLog f
  | otherwise = pure Nothing

data ServerOpts = ServerOpts
  { serverCommand :: ServerCommand,
    enableStoreLog :: Bool,
    pubkeyAlgorihtm :: String
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
    <*> strOption
      ( long "pubkey-algorithm"
          <> short 'a'
          <> help
            ( "public-key algorithm used for certificate generation,"
                <> "\nsupported algorithms: ED448 (default) and ED25519"
            )
          <> value "ED448"
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
