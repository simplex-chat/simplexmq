{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

module Main where

import Control.Monad.Except
import qualified Data.ByteString.Char8 as B
import Data.Composition ((.:))
import Data.Either (fromRight)
import Data.Ini (Ini, lookupValue, readIniFile)
import qualified Data.Text as T
import Data.X509.Validation (Fingerprint (..))
import Network.Socket (ServiceName)
import Options.Applicative
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Server (runSMPServer)
import Simplex.Messaging.Server.Env.STM
import Simplex.Messaging.Server.StoreLog (StoreLog, openReadStoreLog, storeLogFilePath)
import Simplex.Messaging.Transport (ATransport (..), TLS, Transport (..), loadFingerprint, simplexMQVersion)
import Simplex.Messaging.Transport.WebSockets (WS)
import System.Directory (createDirectoryIfMissing, doesDirectoryExist, doesFileExist, removeDirectoryRecursive)
import System.Exit (exitFailure)
import System.FilePath (combine)
import System.IO (IOMode (..), hGetLine, withFile)
import System.Process (readCreateProcess, shell)

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
  getCliOptions >>= \opts -> case optCommand opts of
    Init initOptions@InitOptions {pubkeyAlgorithm} -> do
      -- TODO check during parsing
      checkPubkeyAlgorithm pubkeyAlgorithm
      doesFileExist iniFile >>= \case
        True -> iniAlreadyExistsErr >> exitFailure
        False -> initializeServer initOptions
    Start -> do
      doesFileExist iniFile >>= \case
        False -> iniDoesNotExistErr >> exitFailure
        True -> readIniFile iniFile >>= either (\e -> putStrLn e >> exitFailure) (runServer . mkIniOptions)
    Delete -> cleanup >> putStrLn "Deleted configuration and log files"
  where
    checkPubkeyAlgorithm alg
      | alg == "ED448" || alg == "ED25519" = pure ()
      | otherwise = putStrLn ("Unsupported public key algorithm " <> alg) >> exitFailure
    iniAlreadyExistsErr = putStrLn $ "Error: server is already initialized (" <> iniFile <> " exists).\nRun `smp-server start`."
    iniDoesNotExistErr = putStrLn $ "Error: server is not initialized (" <> iniFile <> " does not exist).\nRun `smp-server init`."

newtype CliOptions = CliOptions {optCommand :: Command}

data Command
  = Init InitOptions
  | Start
  | Delete

data InitOptions = InitOptions
  { enableStoreLog :: Bool,
    pubkeyAlgorithm :: String
  }

getCliOptions :: IO CliOptions
getCliOptions =
  customExecParser
    (prefs showHelpOnEmpty)
    ( info
        (helper <*> versionOption <*> cliOptionsP)
        (header version <> fullDesc)
    )
  where
    versionOption = infoOption version (long "version" <> short 'v' <> help "Show version")

cliOptionsP :: Parser CliOptions
cliOptionsP =
  CliOptions
    <$> hsubparser
      ( command "init" (info initP (progDesc $ "Initialize server - creates " <> cfgDir <> " and " <> logDir <> " directories and configuration files"))
          <> command "start" (info (pure Start) (progDesc $ "Start server (configuration: " <> iniFile <> ")"))
          <> command "delete" (info (pure Delete) (progDesc "Delete configuration and log files"))
      )
  where
    initP :: Parser Command
    initP =
      Init .: InitOptions
        <$> switch
          ( long "store-log"
              <> short 'l'
              <> help "Enable store log for SMP queues persistence"
          )
        <*> strOption
          ( long "pubkey-algorithm"
              <> short 'a'
              <> help "Public key algorithm used for certificate generation: ED25519, ED448"
              <> value "ED448"
              <> showDefault
              <> metavar "ALG"
          )

initializeServer :: InitOptions -> IO ()
initializeServer InitOptions {enableStoreLog, pubkeyAlgorithm} = do
  cleanup
  createDirectoryIfMissing True cfgDir
  createDirectoryIfMissing True logDir
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
      Fingerprint fp <- loadFingerprint caCrtFile
      withFile fingerprintFile WriteMode (`B.hPutStrLn` strEncode fp)

    createIni = do
      writeFile iniFile $
        "[STORE_LOG]\n\
        \# The server uses STM memory to store SMP queues and messages,\n\
        \# that will be lost on restart (e.g., as with redis).\n\
        \# This option enables saving SMP queues to append only log,\n\
        \# and restoring them when the server is started.\n\
        \# Log is compacted on start (deleted queues are removed).\n\
        \# The messages in the queues are not logged.\n"
          <> ("enable: " <> (if enableStoreLog then "on" else "off # on") <> "\n\n")
          <> "[TRANSPORT]\n\
             \port: 5223\n\
             \websockets: on\n"

data IniOptions = IniOptions
  { enableStoreLog :: Bool,
    port :: ServiceName,
    enableWebsockets :: Bool
  }

-- TODO ? properly parse ini as a whole
mkIniOptions :: Ini -> IniOptions
mkIniOptions ini =
  IniOptions
    { enableStoreLog = (== "on") $ strict "STORE_LOG" "enable",
      port = T.unpack $ strict "TRANSPORT" "port",
      enableWebsockets = (== "on") $ strict "TRANSPORT" "websockets"
    }
  where
    strict :: String -> String -> T.Text
    strict section key =
      fromRight (error ("no key " <> key <> " in section " <> section)) $
        lookupValue (T.pack section) (T.pack key) ini

runServer :: IniOptions -> IO ()
runServer IniOptions {enableStoreLog, port, enableWebsockets} = do
  checkSavedFingerprint
  printServiceInfo
  checkCAPrivateKeyFile
  cfg <- setupServerConfig
  printServerConfig cfg
  runSMPServer cfg
  where
    checkSavedFingerprint = do
      savedFingerprint <- loadSavedFingerprint
      Fingerprint fp <- loadFingerprint caCrtFile
      when (B.pack savedFingerprint /= strEncode fp) $
        putStrLn "Stored fingerprint is invalid." >> exitFailure

    checkCAPrivateKeyFile =
      doesFileExist caKeyFile >>= (`when` (alert >> warnCAPrivateKeyFile))
      where
        alert = putStrLn $ "WARNING: " <> caKeyFile <> " is present on the server!"

    setupServerConfig = do
      storeLog <- openStoreLog
      let transports = (port, transport @TLS) : [("80", transport @WS) | enableWebsockets]
      pure
        ServerConfig
          { tbqSize = 16,
            serverTbqSize = 128,
            msgQueueQuota = 256,
            queueIdBytes = 24,
            msgIdBytes = 24, -- must be at least 24 bytes, it is used as 192-bit nonce for XSalsa20
            caServerIdentity = undefined, -- TODO put it here
            caCertificateFile = caCrtFile,
            privateKeyFile = serverKeyFile,
            certificateFile = serverCrtFile,
            transports,
            storeLog
          }
      where
        openStoreLog :: IO (Maybe (StoreLog 'ReadMode))
        openStoreLog
          | enableStoreLog = Just <$> openReadStoreLog storeLogFile
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
  putStrLn version
  fingerprint <- loadSavedFingerprint
  putStrLn $ "Fingerprint: " <> fingerprint

version :: String
version = "SMP server v" <> simplexMQVersion

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
loadSavedFingerprint = withFile fingerprintFile ReadMode hGetLine
