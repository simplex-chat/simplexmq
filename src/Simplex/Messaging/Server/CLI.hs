{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

module Simplex.Messaging.Server.CLI where

import Control.Monad
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
import Simplex.Messaging.Transport (ATransport (..), TLS, Transport (..))
import Simplex.Messaging.Transport.Server (loadFingerprint)
import Simplex.Messaging.Transport.WebSockets (WS)
import System.Directory (createDirectoryIfMissing, doesDirectoryExist, doesFileExist, removeDirectoryRecursive)
import System.Exit (exitFailure)
import System.FilePath (combine)
import System.IO (BufferMode (..), IOMode (..), hGetLine, hSetBuffering, stderr, stdout, withFile)
import System.Process (readCreateProcess, shell)
import Text.Read (readMaybe)

data ServerCLIConfig cfg = ServerCLIConfig
  { cfgDir :: FilePath,
    logDir :: FilePath,
    iniFile :: FilePath,
    storeLogFile :: FilePath,
    caKeyFile :: FilePath,
    caCrtFile :: FilePath,
    serverKeyFile :: FilePath,
    serverCrtFile :: FilePath,
    fingerprintFile :: FilePath,
    defaultServerPort :: ServiceName,
    executableName :: String,
    serverVersion :: String,
    mkIniFile :: Bool -> ServiceName -> String,
    mkServerConfig :: Maybe FilePath -> [(ServiceName, ATransport)] -> Ini -> cfg
  }

protocolServerCLI :: ServerCLIConfig cfg -> (cfg -> IO ()) -> IO ()
protocolServerCLI cliCfg@ServerCLIConfig {iniFile, executableName} server =
  getCliCommand cliCfg >>= \case
    Init opts ->
      doesFileExist iniFile >>= \case
        True -> exitError $ "Error: server is already initialized (" <> iniFile <> " exists).\nRun `" <> executableName <> " start`."
        _ -> initializeServer cliCfg opts
    Start ->
      doesFileExist iniFile >>= \case
        True -> readIniFile iniFile >>= either exitError (runServer cliCfg server)
        _ -> exitError $ "Error: server is not initialized (" <> iniFile <> " does not exist).\nRun `" <> executableName <> " init`."
    Delete -> cleanup cliCfg >> putStrLn "Deleted configuration and log files"

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

getCliCommand :: ServerCLIConfig cfg -> IO CliCommand
getCliCommand cliCfg =
  customExecParser
    (prefs showHelpOnEmpty)
    ( info
        (helper <*> versionOption <*> cliCommandP cliCfg)
        (header version <> fullDesc)
    )
  where
    versionOption = infoOption version (long "version" <> short 'v' <> help "Show version")
    version = serverVersion cliCfg

cliCommandP :: ServerCLIConfig cfg -> Parser CliCommand
cliCommandP ServerCLIConfig {cfgDir, logDir, iniFile} =
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
                      <> help "Enable store log for persistence"
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
                        "Server IP address, used as Common Name for TLS online certificate if FQDN is not supplied"
                      <> value "127.0.0.1"
                      <> showDefault
                      <> metavar "IP"
                  )
                <*> (optional . strOption)
                  ( long "fqdn"
                      <> short 'n'
                      <> help "Server FQDN used as Common Name for TLS online certificate"
                      <> showDefault
                      <> metavar "FQDN"
                  )
            )

initializeServer :: ServerCLIConfig cfg -> InitOptions -> IO ()
initializeServer cliCfg InitOptions {enableStoreLog, signAlgorithm, ip, fqdn} = do
  cleanup cliCfg
  createDirectoryIfMissing True cfgDir
  createDirectoryIfMissing True logDir
  createX509
  fp <- saveFingerprint
  writeFile iniFile $ mkIniFile enableStoreLog defaultServerPort
  putStrLn $ "Server initialized, you can modify configuration in " <> iniFile <> ".\nRun `" <> executableName <> " start` to start server."
  printServiceInfo cliCfg fp
  warnCAPrivateKeyFile
  where
    ServerCLIConfig {cfgDir, logDir, iniFile, executableName, caKeyFile, caCrtFile, serverKeyFile, serverCrtFile, fingerprintFile, defaultServerPort, mkIniFile} = cliCfg
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
        -- IP and FQDN can't both be used as server address interchangeably even if IP is added
        -- as Subject Alternative Name, unless the following validation hook is disabled:
        -- https://hackage.haskell.org/package/x509-validation-1.6.10/docs/src/Data-X509-Validation.html#validateCertificateName
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
                   \extendedKeyUsage = serverAuth\n"
            )
          where
            cn = fromMaybe ip fqdn

    saveFingerprint = do
      Fingerprint fp <- loadFingerprint caCrtFile
      withFile fingerprintFile WriteMode (`B.hPutStrLn` strEncode fp)
      pure fp

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

mkIniOptions :: Ini -> IniOptions
mkIniOptions ini =
  IniOptions
    { enableStoreLog = (== "on") $ strictIni "STORE_LOG" "enable" ini,
      port = T.unpack $ strictIni "TRANSPORT" "port" ini,
      enableWebsockets = (== "on") $ strictIni "TRANSPORT" "websockets" ini
    }

strictIni :: String -> String -> Ini -> T.Text
strictIni section key ini =
  fromRight (error ("no key " <> key <> " in section " <> section)) $
    lookupValue (T.pack section) (T.pack key) ini

readStrictIni :: Read a => String -> String -> Ini -> a
readStrictIni section key = read . T.unpack . strictIni section key

runServer :: ServerCLIConfig cfg -> (cfg -> IO ()) -> Ini -> IO ()
runServer cliCfg server ini = do
  hSetBuffering stdout LineBuffering
  hSetBuffering stderr LineBuffering
  fp <- checkSavedFingerprint
  printServiceInfo cliCfg fp
  let IniOptions {enableStoreLog, port, enableWebsockets} = mkIniOptions ini
      transports = (port, transport @TLS) : [("80", transport @WS) | enableWebsockets]
      logFile = if enableStoreLog then Just storeLogFile else Nothing
      cfg = mkServerConfig logFile transports ini
  printServerConfig logFile transports
  server cfg
  where
    ServerCLIConfig {storeLogFile, caCrtFile, fingerprintFile, mkServerConfig} = cliCfg
    checkSavedFingerprint = do
      savedFingerprint <- withFile fingerprintFile ReadMode hGetLine
      Fingerprint fp <- loadFingerprint caCrtFile
      when (B.pack savedFingerprint /= strEncode fp) $
        exitError "Stored fingerprint is invalid."
      pure fp

    printServerConfig logFile transports = do
      putStrLn $ case logFile of
        Just f -> "Store log: " <> f
        _ -> "Store log disabled."
      forM_ transports $ \(p, ATransport t) ->
        putStrLn $ "Listening on port " <> p <> " (" <> transportName t <> ")..."

cleanup :: ServerCLIConfig cfg -> IO ()
cleanup ServerCLIConfig {cfgDir, logDir} = do
  deleteDirIfExists cfgDir
  deleteDirIfExists logDir
  where
    deleteDirIfExists path = doesDirectoryExist path >>= (`when` removeDirectoryRecursive path)

printServiceInfo :: ServerCLIConfig cfg -> ByteString -> IO ()
printServiceInfo ServerCLIConfig {serverVersion} fpStr = do
  putStrLn serverVersion
  B.putStrLn $ "Fingerprint: " <> strEncode fpStr
