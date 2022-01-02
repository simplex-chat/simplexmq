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
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Server (runSMPServer)
import Simplex.Messaging.Server.Env.STM
import Simplex.Messaging.Server.StoreLog (StoreLog, openReadStoreLog, storeLogFilePath)
import Simplex.Messaging.Transport (ATransport (..), TLS, Transport (..), loadFingerprint, simplexMQVersion)
import Simplex.Messaging.Transport.WebSockets (WS)
import System.Directory (createDirectoryIfMissing, doesDirectoryExist, doesFileExist, removeDirectoryRecursive, removeFile)
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
      -- below parameters are set based on ini file /etc/opt/simplex/smp-server.ini
      transports = undefined,
      storeLog = undefined,
      caServerIdentity = undefined,
      caCertificateFile = undefined,
      serverPrivateKeyFile = undefined,
      serverCertificateFile = undefined
    }

newKeySize :: Int
newKeySize = 2048 `div` 8

cfgDir :: FilePath
cfgDir = "/etc/opt/simplex"

logDir :: FilePath
logDir = "/var/opt/simplex"

-- TODO remove file paths from ini
defaultStoreLogFile :: FilePath
defaultStoreLogFile = combine logDir "smp-server-store.log"

iniFile :: FilePath
iniFile = combine cfgDir "smp-server.ini"

caPrivateKeyFile :: FilePath
caPrivateKeyFile = combine cfgDir "ca.key"

defaultCACertificateFile :: FilePath
defaultCACertificateFile = combine cfgDir "ca.crt"

defaultPrivateKeyFile :: FilePath
defaultPrivateKeyFile = combine cfgDir "server.key"

defaultCertificateFile :: FilePath
defaultCertificateFile = combine cfgDir "server.crt"

fingerprintFile :: FilePath
fingerprintFile = combine cfgDir "fingerprint"

main :: IO ()
main = do
  opts <- getServerOpts
  checkPubkeyAlgorihtm $ pubkeyAlgorihtm opts
  case serverCommand opts of
    ServerInit ->
      runExceptT (getConfig opts) >>= \case
        Right cfg -> do
          putStrLn "Error: server is already initialized. Start it with `smp-server start` command"
          fingerprint <- loadSavedFingerprint
          printConfig cfg fingerprint
          checkCAPrivateKeyFile
          exitFailure
        Left _ -> do
          cfg <- initializeServer opts
          putStrLn "Server was initialized. Start it with `smp-server start` command"
          fingerprint <- loadSavedFingerprint
          printConfig cfg fingerprint
          warnCAPrivateKeyFile
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
makeConfig IniOpts {serverPort, enableWebsockets, caCertificateFile, serverPrivateKeyFile, serverCertificateFile} storeLog =
  let transports = (serverPort, transport @TLS) : [("80", transport @WS) | enableWebsockets]
   in serverConfig {transports, storeLog, caCertificateFile, serverPrivateKeyFile, serverCertificateFile}

printConfig :: ServerConfig -> String -> IO ()
printConfig ServerConfig {storeLog} fingerprint = do
  putStrLn $ "SMP server v" <> simplexMQVersion
  putStrLn $ "fingerprint: " <> fingerprint
  putStrLn $ case storeLog of
    Just s -> "store log: " <> storeLogFilePath s
    Nothing -> "store log disabled"

initializeServer :: ServerOpts -> IO ServerConfig
initializeServer opts = do
  createDirectoryIfMissing True cfgDir
  ini <- createIni opts
  createX509 ini opts
  saveFingerprint $ caCertificateFile (ini :: IniOpts)
  storeLog <- openStoreLog opts ini
  pure $ makeConfig ini storeLog

runServer :: ServerConfig -> IO ()
runServer cfg = do
  savedFingerprint <- loadSavedFingerprint
  checkSavedFingerprint savedFingerprint
  printConfig cfg savedFingerprint
  checkCAPrivateKeyFile
  forM_ (transports cfg) $ \(port, ATransport t) ->
    putStrLn $ "listening on port " <> port <> " (" <> transportName t <> ")"
  runSMPServer cfg
  where
    checkSavedFingerprint :: String -> IO ()
    checkSavedFingerprint savedFingerprint = do
      fingerprint <- loadFingerprint $ caCertificateFile (cfg :: ServerConfig)
      if savedFingerprint == (B.unpack . strEncode) fingerprint
        then putStrLn "stored fingerprint is valid"
        else putStrLn "stored fingerprint is invalid" >> exitFailure

checkCAPrivateKeyFile :: IO ()
checkCAPrivateKeyFile =
  doesFileExist caPrivateKeyFile >>= (`when` (alert >> warnCAPrivateKeyFile))
  where
    alert = putStrLn $ "WARNING: " <> caPrivateKeyFile <> " is present on the server!"

warnCAPrivateKeyFile :: IO ()
warnCAPrivateKeyFile =
  putStrLn $
    "----------\n\
    \We highly recommend to remove CA private key file from the server and keep it securely in place of your choosing.\n\
    \In case server's TLS credential is compromised you will be able to regenerate it using this key,\n\
    \thus keeping server's identity and allowing clients to keep established connections. Key location:\n"
      <> caPrivateKeyFile
      <> "\n----------"

deleteServer :: IO ()
deleteServer = do
  ini <- runExceptT readIni
  deleteIfExists iniFile
  case ini of
    -- TODO delete only cfgDir and logDir once file paths are removed from ini
    Right IniOpts {storeLogFile, caCertificateFile, serverPrivateKeyFile, serverCertificateFile} -> do
      deleteDirIfExists cfgDir
      deleteIfExists storeLogFile
      deleteIfExists caCertificateFile
      deleteIfExists serverPrivateKeyFile
      deleteIfExists serverCertificateFile
    Left _ -> do
      deleteDirIfExists cfgDir
      deleteIfExists defaultStoreLogFile
      deleteIfExists defaultCACertificateFile
      deleteIfExists defaultPrivateKeyFile
      deleteIfExists defaultCertificateFile

data IniOpts = IniOpts
  { enableStoreLog :: Bool,
    storeLogFile :: FilePath,
    serverPort :: ServiceName,
    enableWebsockets :: Bool,
    caCertificateFile :: FilePath,
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
      caCertificateFile = opt defaultCACertificateFile "TRANSPORT" "ca_certificate_file" ini
      serverPrivateKeyFile = opt defaultPrivateKeyFile "TRANSPORT" "private_key_file" ini
      serverCertificateFile = opt defaultCertificateFile "TRANSPORT" "certificate_file" ini
  pure IniOpts {enableStoreLog, storeLogFile, serverPort, enableWebsockets, caCertificateFile, serverPrivateKeyFile, serverCertificateFile}
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
         \# ca_certificate_file: "
      <> defaultCACertificateFile
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
         \websockets: on\n"
  pure
    IniOpts
      { enableStoreLog,
        storeLogFile = defaultStoreLogFile,
        serverPort = defaultServerPort,
        enableWebsockets = True,
        caCertificateFile = defaultCACertificateFile,
        serverPrivateKeyFile = defaultPrivateKeyFile,
        serverCertificateFile = defaultCertificateFile
      }

createX509 :: IniOpts -> ServerOpts -> IO ()
createX509 IniOpts {caCertificateFile, serverPrivateKeyFile, serverCertificateFile} ServerOpts {pubkeyAlgorihtm} = do
  createOpensslConf
  -- CA certificate (identity/offline)
  run $ "openssl genpkey -algorithm " <> pubkeyAlgorihtm <> " -out " <> caPrivateKeyFile
  run $ "openssl req -new -x509 -days 999999 -config " <> opensslConfFile <> " -extensions v3_ca -key " <> caPrivateKeyFile <> " -out " <> caCertificateFile
  -- server certificate (online)
  run $ "openssl genpkey -algorithm " <> pubkeyAlgorihtm <> " -out " <> serverPrivateKeyFile
  run $ "openssl req -new -config " <> opensslConfFile <> " -reqexts v3_req -key " <> serverPrivateKeyFile <> " -out " <> serverCsrFile
  run $ "openssl x509 -req -days 999999 -copy_extensions copy -in " <> serverCsrFile <> " -CA " <> caCertificateFile <> " -CAkey " <> caPrivateKeyFile <> " -out " <> serverCertificateFile
  where
    run cmd = void $ readCreateProcess (shell cmd) ""
    opensslConfFile = combine cfgDir "openssl.cnf"
    serverCsrFile = combine cfgDir "server.csr"
    createOpensslConf :: IO ()
    createOpensslConf =
      -- TODO revise https://www.rfc-editor.org/rfc/rfc5280#section-4.2.1.3, https://www.rfc-editor.org/rfc/rfc3279#section-2.3.5
      writeFile
        opensslConfFile
        "[req]\n\
        \distinguished_name = req_distinguished_name\n\
        \prompt = no\n\n\
        \[req_distinguished_name]\n\
        \CN = localhost\n\n\
        \[v3_ca]\n\
        \subjectKeyIdentifier = hash\n\
        \authorityKeyIdentifier = keyid:always\n\
        \basicConstraints = critical,CA:true\n\n\
        \[v3_req]\n\
        \basicConstraints = CA:FALSE\n\
        \keyUsage = digitalSignature, nonRepudiation, keyAgreement\n\
        \extendedKeyUsage = serverAuth\n"

saveFingerprint :: FilePath -> IO ()
saveFingerprint caCertificateFile = do
  fingerprint <- loadFingerprint caCertificateFile
  writeFile fingerprintFile $ (B.unpack . strEncode) fingerprint <> "\n"

loadSavedFingerprint :: IO String
loadSavedFingerprint = do
  fingerpint <- readFile fingerprintFile
  pure $ dropWhileEnd (== '\n') fingerpint

fileExists :: FilePath -> ExceptT String IO ()
fileExists path = do
  exists <- liftIO $ doesFileExist path
  unless exists . throwE $ "file " <> path <> " not found"

deleteIfExists :: FilePath -> IO ()
deleteIfExists path = doesFileExist path >>= (`when` removeFile path)

deleteDirIfExists :: FilePath -> IO ()
deleteDirIfExists path = doesDirectoryExist path >>= (`when` removeDirectoryRecursive path)

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
