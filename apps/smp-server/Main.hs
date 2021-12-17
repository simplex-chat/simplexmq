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
import Simplex.Messaging.Transport (ATransport (..), TLS, Transport (..))
import Simplex.Messaging.Transport.WebSockets (WS)
import System.Directory (createDirectoryIfMissing, doesFileExist, removeFile)
import System.Exit (exitFailure)
import System.FilePath (combine)
import System.IO (IOMode (..), hFlush, stdout)
import System.Process (readCreateProcess, shell)
import Text.Read (readEither)

defaultServerPort :: ServiceName
defaultServerPort = "5223"

defaultBlockSize :: Int
defaultBlockSize = 4096

serverConfig :: ServerConfig
serverConfig =
  ServerConfig
    { tbqSize = 16,
      serverTbqSize = 128,
      msgQueueQuota = 256,
      queueIdBytes = 24,
      msgIdBytes = 24, -- must be at least 24 bytes, it is used as 192-bit nonce for XSalsa20
      -- below parameters are set based on ini file /etc/opt/simplex/smp-server.ini
      transports = undefined,
      storeLog = undefined,
      blockSize = undefined,
      serverPrivateKey = undefined, -- TODO delete
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

defaultKeyFile :: FilePath
defaultKeyFile = combine cfgDir "server_key"

defaultPrivateKeyFile :: FilePath
defaultPrivateKeyFile = combine cfgDir "server.key"

defaultCertificateFile :: FilePath
defaultCertificateFile = combine cfgDir "server.crt"

main :: IO ()
main = do
  opts <- getServerOpts
  checkPubkeyAlgorihtm $ pubkeyAlgorihtm opts
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
  where
    checkPubkeyAlgorihtm :: String -> IO ()
    checkPubkeyAlgorihtm alg
      | alg == "ED448" || alg == "ED25519" = pure ()
      | otherwise = putStrLn ("unsupported public-key algorithm " <> alg) >> exitFailure

getConfig :: ServerOpts -> ExceptT String IO ServerConfig
getConfig opts = do
  ini <- readIni
  pk <- readKey ini
  storeLog <- liftIO $ openStoreLog opts ini
  pure $ makeConfig ini pk storeLog

makeConfig :: IniOpts -> C.PrivateKey 'C.RSA -> Maybe (StoreLog 'ReadMode) -> ServerConfig
makeConfig IniOpts {serverPort, blockSize, enableWebsockets, serverPrivateKeyFile, serverCertificateFile} pk storeLog =
  let transports = (serverPort, transport @TLS) : [("80", transport @WS) | enableWebsockets]
   in serverConfig {transports, storeLog, blockSize, serverPrivateKey = pk, serverPrivateKeyFile, serverCertificateFile}

printConfig :: ServerConfig -> IO ()
printConfig ServerConfig {serverPrivateKey, storeLog} = do
  B.putStrLn $ "transport key hash: " <> serverKeyHash serverPrivateKey
  putStrLn $ case storeLog of
    Just s -> "store log: " <> storeLogFilePath s
    Nothing -> "store log disabled"

initializeServer :: ServerOpts -> IO ServerConfig
initializeServer opts = do
  createDirectoryIfMissing True cfgDir
  ini <- createIni opts
  pk <- createKey ini
  createKeyAndCertificate ini opts
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
    Right IniOpts {storeLogFile, serverKeyFile, serverPrivateKeyFile, serverCertificateFile} -> do
      deleteIfExists storeLogFile
      deleteIfExists serverKeyFile
      deleteIfExists serverPrivateKeyFile
      deleteIfExists serverCertificateFile
    Left _ -> do
      deleteIfExists defaultStoreLogFile
      deleteIfExists defaultKeyFile
      deleteIfExists defaultPrivateKeyFile
      deleteIfExists defaultCertificateFile

data IniOpts = IniOpts
  { enableStoreLog :: Bool,
    storeLogFile :: FilePath,
    serverPort :: ServiceName,
    blockSize :: Int,
    enableWebsockets :: Bool,
    serverKeyFile :: FilePath,
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
      serverKeyFile = opt defaultKeyFile "TRANSPORT" "key_file" ini
      serverPrivateKeyFile = opt defaultPrivateKeyFile "TRANSPORT" "private_key_file" ini
      serverCertificateFile = opt defaultCertificateFile "TRANSPORT" "certificate_file" ini
  blockSize <- liftEither . readEither $ opt (show defaultBlockSize) "TRANSPORT" "block_size" ini
  pure IniOpts {enableStoreLog, storeLogFile, serverPort, blockSize, enableWebsockets, serverKeyFile, serverPrivateKeyFile, serverCertificateFile}
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
         \# private_key_file: "
      <> defaultPrivateKeyFile
      <> "\n\
         \# certificate_file: "
      <> defaultCertificateFile
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
        serverPort = defaultServerPort,
        blockSize = defaultBlockSize,
        enableWebsockets = True,
        serverKeyFile = defaultKeyFile,
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
