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
import Data.Ini (Ini, lookupValue)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Encoding (encodeUtf8)
import Data.X509.Validation (Fingerprint (..))
import Network.Socket (HostName, ServiceName)
import Options.Applicative
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Protocol (ProtoServerWithAuth (..), ProtocolServer (..), ProtocolTypeI)
import Simplex.Messaging.Transport (ATransport (..), TLS, Transport (..))
import Simplex.Messaging.Transport.Server (loadFingerprint)
import Simplex.Messaging.Transport.WebSockets (WS)
import Simplex.Messaging.Util (eitherToMaybe, whenM)
import System.Directory (doesDirectoryExist, listDirectory, removeDirectoryRecursive, removePathForcibly)
import System.Exit (exitFailure)
import System.FilePath (combine)
import System.IO (IOMode (..), hFlush, hGetLine, stdout, withFile)
import System.Process (readCreateProcess, shell)

exitError :: String -> IO ()
exitError msg = putStrLn msg >> exitFailure

confirmOrExit :: String -> IO ()
confirmOrExit s =
  withPrompt (s <> "\nContinue (Y/n): ") $ do
    ok <- getLine
    when (ok /= "Y") $ putStrLn "Server NOT deleted" >> exitFailure

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

onOff :: Bool -> String
onOff True = "on"
onOff _ = "off"

settingIsOn :: Text -> Text -> Ini -> Maybe ()
settingIsOn section name ini
  | iniOnOff section name ini == Just True = Just ()
  | otherwise = Nothing

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

deleteDirIfExists :: FilePath -> IO ()
deleteDirIfExists path = whenM (doesDirectoryExist path) $ removeDirectoryRecursive path

printServiceInfo :: ProtocolTypeI p => String -> ProtoServerWithAuth p -> IO ()
printServiceInfo serverVersion srv@(ProtoServerWithAuth ProtocolServer {keyHash} _) = do
  putStrLn serverVersion
  B.putStrLn $ "Fingerprint: " <> strEncode keyHash
  B.putStrLn $ "Server address: " <> strEncode srv

clearDirIfExists :: FilePath -> IO ()
clearDirIfExists path = whenM (doesDirectoryExist path) $ listDirectory path >>= mapM_ (removePathForcibly . combine path)
