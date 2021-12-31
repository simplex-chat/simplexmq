{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

module Main where

import Control.Monad.Except
import qualified Data.ByteString.Char8 as B
import Data.Either (fromRight)
import Data.Ini (Ini, lookupValue, readIniFile)
import Data.List (dropWhileEnd)
import qualified Data.Text as T
import Network.Socket (ServiceName)
import Options.Applicative
import Simplex.Messaging.Server (runSMPServer)
import Simplex.Messaging.Server.Env.STM
import Simplex.Messaging.Server.StoreLog (StoreLog, openReadStoreLog, storeLogFilePath)
import Simplex.Messaging.Transport (ATransport (..), TLS, Transport (..), currentSMPVersionStr, encodeFingerprint, loadFingerprint)
import Simplex.Messaging.Transport.WebSockets (WS)
import System.Directory (createDirectoryIfMissing, doesDirectoryExist, doesFileExist, removeDirectoryRecursive)
import System.Exit (exitFailure)
import System.FilePath (combine)
import System.IO (IOMode (..))
import System.Process (readCreateProcess, shell)

serverConfig :: ServerConfig
serverConfig =
  ServerConfig
    { tbqSize = 16,
      serverTbqSize = 128,
      msgQueueQuota = 256,
      queueIdBytes = 24,
      msgIdBytes = 24, -- must be at least 24 bytes, it is used as 192-bit nonce for XSalsa20
      caCertificateFile = caCrtFile,
      privateKeyFile = serverKeyFile,
      certificateFile = serverCrtFile,
      -- below parameters are set based on ini file /etc/opt/simplex/smp-server.ini
      transports = undefined,
      storeLog = undefined
    }

cfgDir :: FilePath
cfgDir = "/etc/opt/simplex"

logDir :: FilePath
logDir = "/var/opt/simplex"

iniFile :: FilePath
iniFile = combine cfgDir "smp-server.ini"

storeLogFile :: FilePath
storeLogFile = combine logDir "smp-server-store.log"

caKeyFile :: FilePath
caKeyFile = combine cfgDir "ca.key"

caCrtFile :: FilePath
caCrtFile = combine cfgDir "ca.crt"

serverKeyFile :: FilePath
serverKeyFile = combine cfgDir "server.key"

serverCrtFile :: FilePath
serverCrtFile = combine cfgDir "server.crt"

fingerprintFile :: FilePath
fingerprintFile = combine cfgDir "fingerprint"

main :: IO ()
main = do
  cliOptions <- getCliOptions
  checkPubkeyAlgorithm cliOptions -- TODO check during parsing
  case serverCommand cliOptions of
    ServerInit ->
      doesFileExist iniFile >>= \case
        True -> iniAlreadyExistsErr >> exitFailure
        False -> initializeServer cliOptions
    ServerStart ->
      doesFileExist iniFile >>= \case
        False -> iniDoesNotExistErr >> exitFailure
        True -> readIniFile iniFile >>= either (\e -> putStrLn e >> exitFailure) (runServer cliOptions . mkIniOptions) -- TODO resolve opts and print ResolvedOpts
    ServerDelete -> cleanup >> putStrLn "Server configuration and log files deleted"
  where
    checkPubkeyAlgorithm CliOptions {pubkeyAlgorithm}
      | pubkeyAlgorithm == "ED448" || pubkeyAlgorithm == "ED25519" = pure ()
      | otherwise = putStrLn ("unsupported public-key algorithm " <> pubkeyAlgorithm) >> exitFailure
    iniAlreadyExistsErr = putStrLn $ "Error: server is already initialized (" <> iniFile <> " exists).\nRun `smp-server start`."
    iniDoesNotExistErr = putStrLn $ "Error: server is not initialized (" <> iniFile <> " does not exist).\nRun `smp-server init`."

data CliOptions = CliOptions
  { serverCommand :: ServerCommand,
    enableStoreLog :: Bool,
    pubkeyAlgorithm :: String
  }

data ServerCommand = ServerInit | ServerStart | ServerDelete

getCliOptions :: IO CliOptions
getCliOptions = customExecParser p opts
  where
    p = prefs showHelpOnEmpty
    opts =
      info
        (cliOptionsP <**> helper)
        ( fullDesc
            <> header "Simplex Messaging Protocol (SMP) Server"
        )

-- TODO parameters should be conditional on command
cliOptionsP :: Parser CliOptions
cliOptionsP =
  CliOptions
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

initializeServer :: CliOptions -> IO ()
initializeServer CliOptions {pubkeyAlgorithm} = do
  cleanup
  createDirectoryIfMissing True cfgDir
  createX509
  saveFingerprint
  createIni
  putStrLn $ "Server initialized, you can modify configuration in " <> iniFile <> ".\nRun `smp-server start` to start server."
  printServiceInfo
  warnCAPrivateKeyFile
  where
    createX509 = do
      createOpensslConf
      -- CA certificate (identity/offline)
      run $ "openssl genpkey -algorithm " <> pubkeyAlgorithm <> " -out " <> caKeyFile
      run $ "openssl req -new -x509 -days 999999 -config " <> opensslCnfFile <> " -extensions v3_ca -key " <> caKeyFile <> " -out " <> caCrtFile
      -- server certificate (online)
      run $ "openssl genpkey -algorithm " <> pubkeyAlgorithm <> " -out " <> serverKeyFile
      run $ "openssl req -new -config " <> opensslCnfFile <> " -reqexts v3_req -key " <> serverKeyFile <> " -out " <> serverCsrFile
      run $ "openssl x509 -req -days 999999 -copy_extensions copy -in " <> serverCsrFile <> " -CA " <> caCrtFile <> " -CAkey " <> caKeyFile <> " -out " <> serverCrtFile
      where
        run cmd = void $ readCreateProcess (shell cmd) ""
        opensslCnfFile = combine cfgDir "openssl.cnf"
        serverCsrFile = combine cfgDir "server.csr"
        createOpensslConf :: IO ()
        createOpensslConf =
          -- TODO revise https://www.rfc-editor.org/rfc/rfc5280#section-4.2.1.3, https://www.rfc-editor.org/rfc/rfc3279#section-2.3.5
          writeFile
            opensslCnfFile
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

    saveFingerprint = do
      fingerprint <- loadFingerprint caCrtFile
      writeFile fingerprintFile $ (B.unpack . encodeFingerprint) fingerprint <> "\n"

    createIni :: IO ()
    createIni = do
      writeFile iniFile $
        "[PERSISTENCE]\n\
        \# The server uses STM memory to store SMP queues and messages,\n\
        \# that will be lost on restart (e.g., as with redis).\n\
        \# This option enables saving SMP queues to append only log,\n\
        \# and restoring them when the server is started.\n\
        \# Log is compacted on start (deleted queues are removed).\n\
        \# The messages in the queues are not logged.\n"
          <> "store_log: on\n\n"
          <> "[TRANSPORT]\n"
          <> "port: 5223\n"
          <> "websockets: on\n"

data IniOptions = IniOptions
  { enableStoreLog :: Bool,
    port :: ServiceName,
    enableWebsockets :: Bool
  }

-- TODO ? properly parse ini as a whole
mkIniOptions :: Ini -> IniOptions
mkIniOptions ini =
  IniOptions
    { enableStoreLog = (== "on") $ strict "PERSISTENCE" "store_log",
      port = T.unpack $ strict "TRANSPORT" "port",
      enableWebsockets = (== "on") $ strict "TRANSPORT" "websockets"
    }
  where
    strict section key = fromRight (error "no key " <> key <> " in section " <> section) $ lookupValue section key ini

runServer :: CliOptions -> IniOptions -> IO () -- TODO should take ResolvedOpts as parameter
runServer cliOptions iniOptions@IniOptions {port, enableWebsockets} = do
  checkSavedFingerprint
  printServiceInfo
  checkCAPrivateKeyFile
  cfg <- setupServerConfig
  printServerConfig cfg
  runSMPServer cfg
  where
    checkSavedFingerprint = do
      savedFingerprint <- loadSavedFingerprint
      fingerprint <- loadFingerprint caCrtFile
      when (savedFingerprint /= (B.unpack . encodeFingerprint) fingerprint) $
        putStrLn "Stored fingerprint is invalid." >> exitFailure

    checkCAPrivateKeyFile =
      doesFileExist caKeyFile >>= (`when` (alert >> warnCAPrivateKeyFile))
      where
        alert = putStrLn $ "WARNING: " <> caKeyFile <> " is present on the server!"

    setupServerConfig = do
      storeLog <- openStoreLog cliOptions iniOptions
      let transports = (port, transport @TLS) : [("80", transport @WS) | enableWebsockets]
      pure serverConfig {transports, storeLog}
      where
        openStoreLog :: CliOptions -> IniOptions -> IO (Maybe (StoreLog 'ReadMode))
        openStoreLog CliOptions {enableStoreLog = l} IniOptions {enableStoreLog = l'}
          -- TODO should be defined by ResolvedOpts instead
          | l || l' = do
            createDirectoryIfMissing True logDir
            Just <$> openReadStoreLog storeLogFile
          | otherwise = pure Nothing

    printServerConfig ServerConfig {storeLog, transports} = do
      putStrLn $ case storeLog of
        Just s -> "Store log: " <> storeLogFilePath s
        Nothing -> "Store log disabled."
      forM_ transports $ \(p, ATransport t) ->
        putStrLn $ "Listening on port " <> p <> " (" <> transportName t <> ")..."

cleanup :: IO ()
cleanup = do
  deleteDirIfExists cfgDir
  deleteDirIfExists logDir
  where
    deleteDirIfExists path = doesDirectoryExist path >>= (`when` removeDirectoryRecursive path)

printServiceInfo :: IO ()
printServiceInfo = do
  putStrLn $ "Server version: " <> B.unpack currentSMPVersionStr
  fingerprint <- loadSavedFingerprint
  putStrLn $ "Fingerprint: " <> fingerprint

warnCAPrivateKeyFile :: IO ()
warnCAPrivateKeyFile =
  putStrLn $
    "----------\n\
    \We highly recommend to remove CA private key file from the server and keep it securely in place of your choosing.\n\
    \In case server's TLS credential is compromised you will be able to regenerate it using this key,\n\
    \thus keeping server's identity and allowing clients to keep established connections. Key location:\n"
      <> caKeyFile
      <> "\n----------"

loadSavedFingerprint :: IO String
loadSavedFingerprint = do
  fingerprint <- readFile fingerprintFile
  pure $ dropWhileEnd (== '\n') fingerprint
