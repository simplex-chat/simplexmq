{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

module Main where

import Control.Monad.Except
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.Either (fromRight)
import Data.Ini (Ini, lookupValue, readIniFile)
import Data.Maybe (fromMaybe)
import qualified Data.Text as T
import Data.X509.Validation (Fingerprint (..))
import Network.Socket (HostName, ServiceName)
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
import Text.Read (readMaybe)

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
  getCliCommand >>= \case
    Init opts ->
      doesFileExist iniFile >>= \case
        True -> exitError $ "Error: server is already initialized (" <> iniFile <> " exists).\nRun `smp-server start`."
        _ -> initializeServer opts
    Start ->
      doesFileExist iniFile >>= \case
        True -> readIniFile iniFile >>= either exitError (runServer . mkIniOptions)
        _ -> exitError $ "Error: server is not initialized (" <> iniFile <> " does not exist).\nRun `smp-server init`."
    Delete -> cleanup >> putStrLn "Deleted configuration and log files"

exitError :: String -> IO ()
exitError msg = putStrLn msg >> exitFailure

data CliCommand
  = Init InitOptions
  | Start
  | Delete

data InitOptions = InitOptions
  { enableStoreLog :: Bool,
    signAlgorithm :: SignAlgorithm,
    ip :: HostName,
    fqdn :: Maybe HostName
  }
  deriving (Show)

data SignAlgorithm = ED448 | ED25519
  deriving (Read, Show)

getCliCommand :: IO CliCommand
getCliCommand =
  customExecParser
    (prefs showHelpOnEmpty)
    ( info
        (helper <*> versionOption <*> cliCommandP)
        (header version <> fullDesc)
    )
  where
    versionOption = infoOption version (long "version" <> short 'v' <> help "Show version")

cliCommandP :: Parser CliCommand
cliCommandP =
  hsubparser
    ( command "init" (info initP (progDesc $ "Initialize server - creates " <> cfgDir <> " and " <> logDir <> " directories and configuration files"))
        <> command "start" (info (pure Start) (progDesc $ "Start server (configuration: " <> iniFile <> ")"))
        <> command "delete" (info (pure Delete) (progDesc "Delete configuration and log files"))
    )
  where
    initP :: Parser CliCommand
    initP =
      Init
        <$> ( InitOptions
                <$> switch
                  ( long "store-log"
                      <> short 'l'
                      <> help "Enable store log for SMP queues persistence"
                  )
                <*> option
                  (maybeReader readMaybe)
                  ( long "sign-algorithm"
                      <> short 'a'
                      <> help "Signature algorithm used for TLS certificates: ED25519, ED448"
                      <> value ED448
                      <> showDefault
                      <> metavar "ALG"
                  )
                <*> strOption
                  ( long "ip"
                      <> help
                        "Server IP address used as Subject Alternative Name for TLS online certificate, \
                        \also used as Common Name if FQDN is not supplied"
                      <> value "127.0.0.1"
                      <> showDefault
                      <> metavar "IP"
                  )
                <*> (optional . strOption)
                  ( long "fqdn"
                      <> short 'n'
                      <> help "Server FQDN used as Common Name and Subject Alternative Name for TLS online certificate"
                      <> showDefault
                      <> metavar "FQDN"
                  )
            )

initializeServer :: InitOptions -> IO ()
initializeServer InitOptions {enableStoreLog, signAlgorithm, ip, fqdn} = do
  cleanup
  createDirectoryIfMissing True cfgDir
  createDirectoryIfMissing True logDir
  createX509
  fp <- saveFingerprint
  createIni
  putStrLn $ "Server initialized, you can modify configuration in " <> iniFile <> ".\nRun `smp-server start` to start server."
  printServiceInfo fp
  warnCAPrivateKeyFile
  where
    createX509 = do
      createOpensslCaConf
      createOpensslServerConf
      -- CA certificate (identity/offline)
      run $ "openssl genpkey -algorithm " <> show signAlgorithm <> " -out " <> caKeyFile
      run $ "openssl req -new -x509 -days 999999 -config " <> opensslCaConfFile <> " -extensions v3 -key " <> caKeyFile <> " -out " <> caCrtFile
      -- server certificate (online)
      run $ "openssl genpkey -algorithm " <> show signAlgorithm <> " -out " <> serverKeyFile
      run $ "openssl req -new -config " <> opensslServerConfFile <> " -reqexts v3 -key " <> serverKeyFile <> " -out " <> serverCsrFile
      run $ "openssl x509 -req -days 999999 -extfile " <> opensslServerConfFile <> " -extensions v3 -in " <> serverCsrFile <> " -CA " <> caCrtFile <> " -CAkey " <> caKeyFile <> " -CAcreateserial -out " <> serverCrtFile
      where
        run cmd = void $ readCreateProcess (shell cmd) ""
        opensslCaConfFile = combine cfgDir "openssl_ca.conf"
        opensslServerConfFile = combine cfgDir "openssl_server.conf"
        serverCsrFile = combine cfgDir "server.csr"
        createOpensslCaConf =
          writeFile
            opensslCaConfFile
            "[req]\n\
            \distinguished_name = req_distinguished_name\n\
            \prompt = no\n\n\
            \[req_distinguished_name]\n\
            \CN = SMP server CA\n\
            \O = SimpleX\n\n\
            \[v3]\n\
            \subjectKeyIdentifier = hash\n\
            \authorityKeyIdentifier = keyid:always\n\
            \basicConstraints = critical,CA:true\n"
        -- TODO revise https://www.rfc-editor.org/rfc/rfc5280#section-4.2.1.3, https://www.rfc-editor.org/rfc/rfc3279#section-2.3.5
        createOpensslServerConf =
          writeFile
            opensslServerConfFile
            ( "[req]\n\
              \distinguished_name = req_distinguished_name\n\
              \prompt = no\n\n\
              \[req_distinguished_name]\n"
                <> ("CN = " <> cn <> "\n\n")
                <> "[v3]\n\
                   \basicConstraints = CA:FALSE\n\
                   \keyUsage = digitalSignature, nonRepudiation, keyAgreement\n\
                   \extendedKeyUsage = serverAuth\n\
                   \subjectAltName = @alt_names\n\n\
                   \[alt_names]\n"
                <> optionalDns1
                <> ("IP.1 = " <> ip <> "\n")
            )
          where
            cn = fromMaybe ip fqdn
            optionalDns1 = case fqdn of
              Nothing -> ""
              Just n -> "DNS.1 = " <> n <> "\n"

    saveFingerprint = do
      Fingerprint fp <- loadFingerprint caCrtFile
      withFile fingerprintFile WriteMode (`B.hPutStrLn` strEncode fp)
      pure fp

    createIni = do
      writeFile iniFile $
        "[STORE_LOG]\n\
        \# The server uses STM memory to store SMP queues and messages,\n\
        \# that will be lost on restart (e.g., as with redis).\n\
        \# This option enables saving SMP queues to append only log,\n\
        \# and restoring them when the server is started.\n\
        \# Log is compacted on start (deleted queues are removed).\n\
        \# The messages in the queues are not logged.\n"
          <> ("enable: " <> (if enableStoreLog then "on" else "off  # on") <> "\n\n")
          <> "[TRANSPORT]\n\
             \port: 5223\n\
             \websockets: off\n"

    warnCAPrivateKeyFile =
      putStrLn $
        "----------\n\
        \You should store CA private key securely and delete it from the server.\n\
        \If server TLS credential is compromised this key can be used to sign a new one, \
        \keeping the same server identity and established connections.\n\
        \CA private key location:\n"
          <> caKeyFile
          <> "\n----------"

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
  fp <- checkSavedFingerprint
  printServiceInfo fp
  storeLog <- openStoreLog
  let cfg = mkServerConfig storeLog
  printServerConfig cfg
  runSMPServer cfg
  where
    checkSavedFingerprint = do
      savedFingerprint <- loadSavedFingerprint
      Fingerprint fp <- loadFingerprint caCrtFile
      when (B.pack savedFingerprint /= strEncode fp) $
        exitError "Stored fingerprint is invalid."
      pure fp

    mkServerConfig storeLog =
      ServerConfig
        { transports = (port, transport @TLS) : [("80", transport @WS) | enableWebsockets],
          tbqSize = 16,
          serverTbqSize = 128,
          msgQueueQuota = 256,
          queueIdBytes = 24,
          msgIdBytes = 24, -- must be at least 24 bytes, it is used as 192-bit nonce for XSalsa20
          caCertificateFile = caCrtFile,
          privateKeyFile = serverKeyFile,
          certificateFile = serverCrtFile,
          storeLog
        }

    openStoreLog :: IO (Maybe (StoreLog 'ReadMode))
    openStoreLog =
      if enableStoreLog
        then Just <$> openReadStoreLog storeLogFile
        else pure Nothing

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

printServiceInfo :: ByteString -> IO ()
printServiceInfo fpStr = do
  putStrLn version
  B.putStrLn $ "Fingerprint: " <> strEncode fpStr

version :: String
version = "SMP server v" <> simplexMQVersion

loadSavedFingerprint :: IO String
loadSavedFingerprint = withFile fingerprintFile ReadMode hGetLine
