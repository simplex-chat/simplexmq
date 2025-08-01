{-# LANGUAGE ApplicativeDo #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeApplications #-}

module Simplex.Messaging.Server.CLI where

import Control.Logger.Simple (LogLevel (..))
import Control.Monad
import Data.ASN1.Types (asn1CharacterToString)
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.Either (fromRight)
import Data.Ini (Ini, lookupValue)
import Data.List ((\\))
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Encoding (encodeUtf8)
import qualified Data.X509 as X
import qualified Data.X509.File as XF
import Data.X509.Validation (Fingerprint (..))
import Network.Socket (HostName, ServiceName)
import Options.Applicative
import Simplex.Messaging.Agent.Store.Postgres.Options (DBOpts (..))
import Simplex.Messaging.Agent.Store.Shared (MigrationConfirmation (..))
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Protocol (ProtoServerWithAuth (..), ProtocolServer (..), ProtocolTypeI)
import Simplex.Messaging.Server.Env.STM (ServerStoreCfg (..), StartOptions (..), StorePaths (..))
import Simplex.Messaging.Server.QueueStore.Postgres.Config (PostgresStoreCfg (..))
import Simplex.Messaging.Transport (ASrvTransport, ATransport (..), TLS, Transport (..))
import Simplex.Messaging.Transport.Server (AddHTTP, loadFileFingerprint)
import Simplex.Messaging.Transport.WebSockets (WS)
import Simplex.Messaging.Util (eitherToMaybe, whenM)
import System.Directory (doesDirectoryExist, listDirectory, removeDirectoryRecursive, removePathForcibly)
import System.Environment (lookupEnv)
import System.Exit (exitFailure)
import System.FilePath (combine)
import System.IO (IOMode (..), hFlush, hGetLine, stdout, withFile)
import System.Process (readCreateProcess, shell)
import Text.Read (readMaybe)

exitError :: String -> IO a
exitError msg = putStrLn msg >> exitFailure

confirmOrExit :: String -> String -> IO ()
confirmOrExit s no =
  withPrompt (s <> "\nContinue (Y/n): ") $ do
    ok <- getLine
    when (ok /= "Y") $ putStrLn no >> exitFailure

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

createServerX509 :: FilePath -> X509Config -> IO ByteString
createServerX509 = createServerX509_ True

createServerX509_ :: Bool -> FilePath -> X509Config -> IO ByteString
createServerX509_ createCA cfgPath x509cfg = do
  let alg = show $ signAlgorithm (x509cfg :: X509Config)
  -- CA certificate (identity/offline)
  when createCA $ do
    createOpensslCaConf
    run $ "openssl genpkey -algorithm " <> alg <> " -out " <> c caKeyFile
    run $ "openssl req -new -x509 -days 999999 -config " <> c opensslCaConfFile <> " -extensions v3 -key " <> c caKeyFile <> " -out " <> c caCrtFile
  -- server certificate (online)
  createOpensslServerConf
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
      Fingerprint fp <- loadFileFingerprint $ c caCrtFile
      withFile (c fingerprintFile) WriteMode (`B.hPutStrLn` strEncode fp)
      pure fp

data CertOptions = CertOptions
  { signAlgorithm_ :: Maybe SignAlgorithm,
    commonName_ :: Maybe HostName
  }
  deriving (Show)

certOptionsP :: Parser CertOptions
certOptionsP = do
  signAlgorithm_ <-
    optional $
      option
        (maybeReader readMaybe)
        ( long "sign-algorithm"
            <> short 'a'
            <> help "Set new signature algorithm used for TLS certificates: ED25519, ED448"
            <> metavar "ALG"
        )
  commonName_ <-
    optional $
      strOption
        ( long "cn"
            <> help
              "Set new Common Name for TLS online certificate"
            <> metavar "FQDN"
        )
  pure CertOptions {signAlgorithm_, commonName_}

dbOptsP :: DBOpts -> Parser DBOpts
dbOptsP DBOpts {connstr = defDBConnStr, schema = defDBSchema, poolSize = defDBPoolSize} = do
  connstr <-
    strOption
      ( long "database"
          <> short 'd'
          <> metavar "DB_CONN"
          <> help "Database connection string"
          <> value defDBConnStr
          <> showDefault
      )
  schema <-
    strOption
      ( long "schema"
          <> metavar "DB_SCHEMA"
          <> help "Database schema"
          <> value defDBSchema
          <> showDefault
      )
  poolSize <-
    option
      auto
      ( long "pool-size"
          <> metavar "POOL_SIZE"
          <> help "Database pool size"
          <> value defDBPoolSize
          <> showDefault
      )
  pure DBOpts {connstr, schema, poolSize, createSchema = False}

startOptionsP :: Parser StartOptions
startOptionsP = do
  maintenance <-
    switch
      ( long "maintenance"
          <> short 'm'
          <> help "Do not start the server, only perform start and stop tasks"
      )
  compactLog <-
    switch
      ( long "compact-log"
          <> help "Compact store log (always enabled with `memory` storage for queues)"
      )
  logLevel <-
    option
      parseLogLevel
      ( long "log-level"
          <> metavar "LOG_LEVEL"
          <> help "Logging level"
          <> value LogInfo
      )
  skipWarnings <-
    switch
      ( long "skip-warnings"
          <> help "Start the server with non-critical start warnings"
      )
  confirmMigrations <-
    option
      parseConfirmMigrations
      ( long "confirm-migrations"
          <> metavar "CONFIRM_MIGRATIONS"
          <> help "Confirm PostgreSQL database migration: up, down (default is manual confirmation)"
          <> value MCConsole
      )
  pure StartOptions {maintenance, compactLog, logLevel, skipWarnings, confirmMigrations}
    where
      parseConfirmMigrations :: ReadM MigrationConfirmation
      parseConfirmMigrations = eitherReader $ \case
        "up" -> Right MCYesUp
        "down" -> Right MCYesUpDown
        _ -> Left "invalid migration confirmation, pass 'up' or 'down'"

parseLogLevel :: ReadM LogLevel
parseLogLevel = eitherReader $ \case
  "trace" -> Right LogTrace
  "debug" -> Right LogDebug
  "info" -> Right LogInfo
  "note" -> Right LogNote
  "warn" -> Right LogWarn
  "error" -> Right LogError
  _ -> Left "Invalid log level"

genOnline :: FilePath -> CertOptions -> IO ()
genOnline cfgPath CertOptions {signAlgorithm_, commonName_} = do
  (signAlgorithm, commonName) <-
    case (signAlgorithm_, commonName_) of
      (Just alg, Just cn) -> pure (alg, cn)
      _ ->
        XF.readSignedObject certPath >>= \case
          [old] -> either exitError pure . fromX509 . X.signedObject $ X.getSigned old
          [] -> exitError $ "No certificate found at " <> certPath
          _ -> exitError $ "Too many certificates at " <> certPath
  let x509cfg = defaultX509Config {signAlgorithm, commonName}
  void $ createServerX509_ False cfgPath x509cfg
  putStrLn "Generated new server credentials"
  warnCAPrivateKeyFile cfgPath x509cfg
  where
    certPath = combine cfgPath $ serverCrtFile defaultX509Config
    fromX509 X.Certificate {certSignatureAlg, certSubjectDN} = (,) <$> maybe oldAlg Right signAlgorithm_ <*> maybe oldCN Right commonName_
      where
        oldAlg = case certSignatureAlg of
          X.SignatureALG_IntrinsicHash X.PubKeyALG_Ed448 -> Right ED448
          X.SignatureALG_IntrinsicHash X.PubKeyALG_Ed25519 -> Right ED25519
          alg -> Left $ "Unexpected signature algorithm " <> show alg
        oldCN = case X.getDnElement X.DnCommonName certSubjectDN of
          Nothing -> Left "Certificate subject has no CN element"
          Just cn -> maybe (Left "Certificate subject CN decoding failed") Right $ asn1CharacterToString cn

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

readIniDefault :: Read a => a -> Text -> Text -> Ini -> a
readIniDefault def section key = either (const def) (read . T.unpack) . lookupValue section key

iniOnOff :: Text -> Text -> Ini -> Maybe Bool
iniOnOff section name ini = case lookupValue section name ini of
  Right "on" -> Just True
  Right "off" -> Just False
  Right s -> error . T.unpack $ "invalid INI setting " <> name <> ": " <> s
  _ -> Nothing

strDecodeIni :: StrEncoding a => Text -> Text -> Ini -> Maybe (Either String a)
strDecodeIni section name ini = strDecode . encodeUtf8 <$> eitherToMaybe (lookupValue section name ini)

withPrompt :: String -> IO a -> IO a
withPrompt s a = putStr s >> hFlush stdout >> a

onOffPrompt :: String -> Bool -> IO Bool
onOffPrompt prompt def =
  withPrompt (prompt <> if def then " (Yn): " else " (yN): ") $
    getLine >>= \case
      "" -> pure def
      "y" -> pure True
      "Y" -> pure True
      "n" -> pure False
      "N" -> pure False
      _ -> putStrLn "Invalid input, please enter 'y' or 'n'" >> onOffPrompt prompt def

onOff :: Bool -> Text
onOff True = "on"
onOff _ = "off"

settingIsOn :: Text -> Text -> Ini -> Maybe ()
settingIsOn section name ini
  | iniOnOff section name ini == Just True = Just ()
  | otherwise = Nothing

checkSavedFingerprint :: FilePath -> X509Config -> IO ByteString
checkSavedFingerprint cfgPath x509cfg = do
  savedFingerprint <- withFile (c fingerprintFile) ReadMode hGetLine
  Fingerprint fp <- loadFileFingerprint (c caCrtFile)
  when (B.pack savedFingerprint /= strEncode fp) $
    exitError "Stored fingerprint is invalid."
  pure fp
  where
    c = combine cfgPath . ($ x509cfg)

iniTransports :: Ini -> [(ServiceName, ASrvTransport, AddHTTP)]
iniTransports ini =
  let smpPorts = ports $ strictIni "TRANSPORT" "port" ini
      ws = strictIni "TRANSPORT" "websockets" ini
      wsPorts
        | ws == "off" = []
        | ws == "on" = ["80"]
        | otherwise = ports ws \\ smpPorts
   in ts (transport @TLS) smpPorts <> ts (transport @WS) wsPorts
  where
    ts :: ASrvTransport -> [ServiceName] -> [(ServiceName, ASrvTransport, AddHTTP)]
    ts t = map (\port -> (port, t, webPort == Just port))
    webPort = T.unpack <$> eitherToMaybe (lookupValue "WEB" "https" ini)
    ports = map T.unpack . T.splitOn ","

iniDBOptions :: Ini -> DBOpts -> DBOpts
iniDBOptions ini _default@DBOpts {connstr, schema, poolSize} =
  DBOpts
    { connstr = either (const connstr) encodeUtf8 $ lookupValue "STORE_LOG" "db_connection" ini,
      schema = either (const schema) encodeUtf8 $ lookupValue "STORE_LOG" "db_schema" ini,
      poolSize = readIniDefault poolSize "STORE_LOG" "db_pool_size" ini,
      createSchema = False
    }

printServerConfig :: String -> [(ServiceName, ASrvTransport, AddHTTP)] -> Maybe FilePath -> IO ()
printServerConfig protocol transports logFile = do
  putStrLn $ case logFile of
    Just f -> "Store log: " <> f
    _ -> "Store log disabled."
  printServerTransports protocol transports

printServerTransports :: String -> [(ServiceName, ASrvTransport, AddHTTP)] -> IO ()
printServerTransports protocol ts = do
  forM_ ts $ \(p, ATransport t, addHTTP) -> do
    let descr = p <> " (" <> transportName t <> ")..."
    putStrLn $ "Serving " <> protocol <> " protocol on port " <> descr
    when addHTTP $ putStrLn $ "Serving static site on port " <> descr
  unless (any (\(p, _, _) -> p == "443") ts) $
    putStrLn
      "\nWARNING: the clients will use port 443 by default soon.\n\
      \Set `port` in smp-server.ini section [TRANSPORT] to `5223,443`\n"

printSMPServerConfig :: [(ServiceName, ASrvTransport, AddHTTP)] -> ServerStoreCfg s -> IO ()
printSMPServerConfig transports = \case
  SSCMemory sp_ -> printServerConfig "SMP" transports $ (\StorePaths {storeLogFile} -> storeLogFile) <$> sp_
  SSCMemoryJournal {storeLogFile} -> printServerConfig "SMP" transports $ Just storeLogFile
  SSCDatabaseJournal {storeCfg = PostgresStoreCfg {dbOpts = DBOpts {connstr, schema}}} -> do
    B.putStrLn $ "PostgreSQL database: " <> connstr <> ", schema: " <> schema
    printServerTransports "SMP" transports

deleteDirIfExists :: FilePath -> IO ()
deleteDirIfExists path = whenM (doesDirectoryExist path) $ removeDirectoryRecursive path

printServiceInfo :: ProtocolTypeI p => String -> ProtoServerWithAuth p -> IO ()
printServiceInfo serverVersion srv@(ProtoServerWithAuth ProtocolServer {keyHash} _) = do
  putStrLn serverVersion
  B.putStrLn $ "Fingerprint: " <> strEncode keyHash
  B.putStrLn $ "Server address: " <> strEncode srv

clearDirIfExists :: FilePath -> IO ()
clearDirIfExists path = whenM (doesDirectoryExist path) $ listDirectory path >>= mapM_ (removePathForcibly . combine path)

getEnvPath :: String -> FilePath -> IO FilePath
getEnvPath name def = maybe def (\case "" -> def; f -> f) <$> lookupEnv name
