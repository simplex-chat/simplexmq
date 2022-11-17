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
import Data.Text (Text)
import qualified Data.Text as T
import Data.X509.Validation (Fingerprint (..))
import Network.Socket (HostName, ServiceName)
import Options.Applicative
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Transport (ATransport (..), TLS, Transport (..))
import Simplex.Messaging.Transport.Server (loadFingerprint)
import Simplex.Messaging.Transport.WebSockets (WS)
import Simplex.Messaging.Util (whenM)
import System.Directory (createDirectoryIfMissing, doesDirectoryExist, doesFileExist, listDirectory, removeDirectoryRecursive, removePathForcibly)
import System.Exit (exitFailure)
import System.FilePath (combine)
import System.IO (BufferMode (..), IOMode (..), hFlush, hGetLine, hSetBuffering, stderr, stdout, withFile)
import System.Process (readCreateProcess, shell)
import Text.Read (readMaybe)

data ServerCLIConfig cfg = ServerCLIConfig
  { cfgDir :: FilePath,
    logDir :: FilePath,
    iniFile :: FilePath,
    storeLogFile :: FilePath,
    x509cfg :: X509Config,
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
    Delete -> do
      confirmOrExit "WARNING: deleting the server will make all queues inaccessible, because the server identity (certificate fingerprint) will change.\nTHIS CANNOT BE UNDONE!"
      cleanup cliCfg
      putStrLn "Deleted configuration and log files"

exitError :: String -> IO ()
exitError msg = putStrLn msg >> exitFailure

confirmOrExit :: String -> IO ()
confirmOrExit s = do
  putStrLn s
  putStr "Continue (Y/n): "
  hFlush stdout
  ok <- getLine
  when (ok /= "Y") exitFailure

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

data X509Config = X509Config
  { commonName :: HostName,
    signAlgorithm :: SignAlgorithm,
    caKeyFile :: FilePath,
    caCrtFile :: FilePath,
    serverKeyFile :: FilePath,
    serverCrtFile :: FilePath,
    fingerprintFile :: FilePath,
    opensslCaConfFile :: FilePath,
    opensslServerConfFile :: FilePath,
    serverCsrFile :: FilePath
  }

defaultX509Config :: X509Config
defaultX509Config =
  X509Config
    { commonName = "127.0.0.1",
      signAlgorithm = ED448,
      caKeyFile = "ca.key",
      caCrtFile = "ca.crt",
      serverKeyFile = "server.key",
      serverCrtFile = "server.crt",
      fingerprintFile = "fingerprint",
      opensslCaConfFile = "openssl_ca.conf",
      opensslServerConfFile = "openssl_server.conf",
      serverCsrFile = "server.csr"
    }

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

getCliCommand' :: Parser cmd -> String -> IO cmd
getCliCommand' cmdP version =
  customExecParser
    (prefs showHelpOnEmpty)
    ( info
        (helper <*> versionOption <*> cmdP)
        (header version <> fullDesc)
    )
  where
    versionOption = infoOption version (long "version" <> short 'v' <> help "Show version")

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
  deleteDirIfExists cfgDir
  deleteDirIfExists logDir
  createDirectoryIfMissing True cfgDir
  createDirectoryIfMissing True logDir
  let x509cfg' = x509cfg {commonName = fromMaybe ip fqdn, signAlgorithm}
  fp <- createServerX509 cfgDir x509cfg'
  writeFile iniFile $ mkIniFile enableStoreLog defaultServerPort
  putStrLn $ "Server initialized, you can modify configuration in " <> iniFile <> ".\nRun `" <> executableName <> " start` to start server."
  printServiceInfo (serverVersion cliCfg) fp
  warnCAPrivateKeyFile cfgDir x509cfg'
  where
    ServerCLIConfig {cfgDir, logDir, iniFile, x509cfg, executableName, defaultServerPort, mkIniFile} = cliCfg

createServerX509 :: FilePath -> X509Config -> IO ByteString
createServerX509 cfgPath x509cfg = do
  createOpensslCaConf
  createOpensslServerConf
  let alg = show $ signAlgorithm (x509cfg :: X509Config)
  -- CA certificate (identity/offline)
  run $ "openssl genpkey -algorithm " <> alg <> " -out " <> c caKeyFile
  run $ "openssl req -new -x509 -days 999999 -config " <> c opensslCaConfFile <> " -extensions v3 -key " <> c caKeyFile <> " -out " <> c caCrtFile
  -- server certificate (online)
  run $ "openssl genpkey -algorithm " <> alg <> " -out " <> c serverKeyFile
  run $ "openssl req -new -config " <> c opensslServerConfFile <> " -reqexts v3 -key " <> c serverKeyFile <> " -out " <> c serverCsrFile
  run $ "openssl x509 -req -days 999999 -extfile " <> c opensslServerConfFile <> " -extensions v3 -in " <> c serverCsrFile <> " -CA " <> c caCrtFile <> " -CAkey " <> c caKeyFile <> " -CAcreateserial -out " <> c serverCrtFile
  saveFingerprint
  where
    run cmd = void $ readCreateProcess (shell cmd) ""
    c = combine cfgPath . ($ x509cfg)
    createOpensslCaConf =
      writeFile
        (c opensslCaConfFile)
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
        (c opensslServerConfFile)
        ( "[req]\n\
          \distinguished_name = req_distinguished_name\n\
          \prompt = no\n\n\
          \[req_distinguished_name]\n"
            <> ("CN = " <> commonName x509cfg <> "\n\n")
            <> "[v3]\n\
               \basicConstraints = CA:FALSE\n\
               \keyUsage = digitalSignature, nonRepudiation, keyAgreement\n\
               \extendedKeyUsage = serverAuth\n"
        )

    saveFingerprint = do
      Fingerprint fp <- loadFingerprint $ c caCrtFile
      withFile (c fingerprintFile) WriteMode (`B.hPutStrLn` strEncode fp)
      pure fp

warnCAPrivateKeyFile :: FilePath -> X509Config -> IO ()
warnCAPrivateKeyFile cfgPath X509Config {caKeyFile} =
  putStrLn $
    "----------\n\
    \You should store CA private key securely and delete it from the server.\n\
    \If server TLS credential is compromised this key can be used to sign a new one, \
    \keeping the same server identity and established connections.\n\
    \CA private key location:\n"
      <> combine cfgPath caKeyFile
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

strictIni :: Text -> Text -> Ini -> Text
strictIni section key ini =
  fromRight (error . T.unpack $ "no key " <> key <> " in section " <> section) $
    lookupValue section key ini

readStrictIni :: Read a => Text -> Text -> Ini -> a
readStrictIni section key = read . T.unpack . strictIni section key

runServer :: ServerCLIConfig cfg -> (cfg -> IO ()) -> Ini -> IO ()
runServer cliCfg server ini = do
  hSetBuffering stdout LineBuffering
  hSetBuffering stderr LineBuffering
  fp <- checkSavedFingerprint cfgDir x509cfg
  printServiceInfo (serverVersion cliCfg) fp
  let IniOptions {enableStoreLog, port, enableWebsockets} = mkIniOptions ini
      transports = (port, transport @TLS) : [("80", transport @WS) | enableWebsockets]
      logFile = if enableStoreLog then Just storeLogFile else Nothing
      cfg = mkServerConfig logFile transports ini
  printServerConfig transports logFile
  server cfg
  where
    ServerCLIConfig {cfgDir, storeLogFile, x509cfg, mkServerConfig} = cliCfg

runServer' :: FilePath -> X509Config -> ([(ServiceName, ATransport)] -> Ini -> cfg) -> String -> (cfg -> IO ()) -> Ini -> IO ()
runServer' cfgPath x509cfg mkServerConfig serverVersion server ini = do
  hSetBuffering stdout LineBuffering
  hSetBuffering stderr LineBuffering
  fp <- checkSavedFingerprint cfgPath x509cfg
  printServiceInfo serverVersion fp
  server $ mkServerConfig (iniTransports ini) ini

checkSavedFingerprint :: FilePath -> X509Config -> IO ByteString
checkSavedFingerprint cfgPath x509cfg = do
  savedFingerprint <- withFile (c fingerprintFile) ReadMode hGetLine
  Fingerprint fp <- loadFingerprint (c caCrtFile)
  when (B.pack savedFingerprint /= strEncode fp) $
    exitError "Stored fingerprint is invalid."
  pure fp
  where
    c = combine cfgPath . ($ x509cfg)

iniTransports :: Ini -> [(String, ATransport)]
iniTransports ini =
  let port = T.unpack $ strictIni "TRANSPORT" "port" ini
      enableWebsockets = (== "on") $ strictIni "TRANSPORT" "websockets" ini
   in (port, transport @TLS) : [("80", transport @WS) | enableWebsockets]

printServerConfig :: [(ServiceName, ATransport)] -> Maybe FilePath -> IO ()
printServerConfig transports logFile = do
  putStrLn $ case logFile of
    Just f -> "Store log: " <> f
    _ -> "Store log disabled."
  forM_ transports $ \(p, ATransport t) ->
    putStrLn $ "Listening on port " <> p <> " (" <> transportName t <> ")..."

cleanup :: ServerCLIConfig cfg -> IO ()
cleanup ServerCLIConfig {cfgDir, logDir} = do
  deleteDirIfExists cfgDir
  deleteDirIfExists logDir

deleteDirIfExists :: FilePath -> IO ()
deleteDirIfExists path = whenM (doesDirectoryExist path) $ removeDirectoryRecursive path

clearDirs :: ServerCLIConfig cfg -> IO ()
clearDirs ServerCLIConfig {cfgDir, logDir} = do
  clearDirIfExists cfgDir
  clearDirIfExists logDir
  where
    clearDirIfExists path = whenM (doesDirectoryExist path) $ listDirectory path >>= mapM_ (removePathForcibly . combine path)

printServiceInfo :: String -> ByteString -> IO ()
printServiceInfo serverVersion fpStr = do
  putStrLn serverVersion
  B.putStrLn $ "Fingerprint: " <> strEncode fpStr
