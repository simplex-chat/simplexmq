{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

module CLITests where

import Control.Logger.Simple
import Crypto.PubKey.ECC.Types (CurveName (..))
import qualified Data.ByteString.Lazy as BL
import qualified Data.HashMap.Strict as HM
import Data.Ini (Ini (..), lookupValue, readIniFile, writeIniFile)
import Data.List (isPrefixOf)
import qualified Data.Text as T
import qualified Data.X509 as X
import qualified Data.X509.File as XF
import Data.X509.Validation (Fingerprint (..))
import Network.HTTP.Client as HTTP
import Simplex.FileTransfer.Server.Main (xftpServerCLI)
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Notifications.Server.Main
import Simplex.Messaging.Server.Main
import Simplex.Messaging.Transport (defaultSupportedParams, defaultSupportedParamsHTTPS, simplexMQVersion, tlsALPN, tlsServerCerts)
import Simplex.Messaging.Transport.Client
import Simplex.Messaging.Transport.Server (loadFileFingerprint)
import Simplex.Messaging.Util (catchAll_)
import qualified Static
import System.Directory (doesFileExist)
import System.Environment (withArgs)
import System.FilePath ((</>))
import System.IO.Silently (capture_)
import System.Timeout (timeout)
import Test.Hspec
import Test.Main (withStdin)
import UnliftIO (catchAny)
import UnliftIO.Async (async, cancel)
import UnliftIO.Concurrent (threadDelay)
import UnliftIO.Exception (bracket)

cfgPath :: FilePath
cfgPath = "tests/tmp/cli/etc/opt/simplex"

logPath :: FilePath
logPath = "tests/tmp/cli/etc/var/simplex"

webPath :: FilePath
webPath = "tests/tmp/cli/var/www"

ntfCfgPath :: FilePath
ntfCfgPath = "tests/tmp/cli/etc/opt/simplex-notifications"

ntfLogPath :: FilePath
ntfLogPath = "tests/tmp/cli/etc/var/simplex-notifications"

fileCfgPath :: FilePath
fileCfgPath = "tests/tmp/cli/etc/opt/simplex-files"

fileLogPath :: FilePath
fileLogPath = "tests/tmp/cli/etc/var/simplex-files"

cliTests :: Spec
cliTests = do
  describe "SMP server CLI" $ do
    describe "initialize, start and delete the server" $ do
      it "no store log, random password (default)" $ smpServerTest False True
      it "with store log, random password (default)" $ smpServerTest True True
      it "no store log, no password" $ smpServerTest False False
      it "with store log, no password" $ smpServerTest True False
      fit "static files" smpServerTestStatic
  describe "Ntf server CLI" $ do
    it "should initialize, start and delete the server (no store log)" $ ntfServerTest False
    it "should initialize, start and delete the server (with store log)" $ ntfServerTest True
  describe "XFTP server CLI" $ do
    it "should initialize, start and delete the server (no store log)" $ xftpServerTest False
    it "should initialize, start and delete the server (with store log)" $ xftpServerTest True

smpServerTest :: Bool -> Bool -> IO ()
smpServerTest storeLog basicAuth = do
  -- init
  capture_ (withArgs (["init", "-y"] <> ["-l" | storeLog] <> ["--no-password" | not basicAuth]) $ smpServerCLI cfgPath logPath)
    >>= (`shouldSatisfy` (("Server initialized, please provide additional server information in " <> cfgPath <> "/smp-server.ini") `isPrefixOf`))
  Right ini <- readIniFile $ cfgPath <> "/smp-server.ini"
  lookupValue "STORE_LOG" "enable" ini `shouldBe` Right (if storeLog then "on" else "off")
  lookupValue "STORE_LOG" "log_stats" ini `shouldBe` Right "off"
  lookupValue "TRANSPORT" "port" ini `shouldBe` Right "5223"
  lookupValue "TRANSPORT" "websockets" ini `shouldBe` Right "off"
  lookupValue "AUTH" "new_queues" ini `shouldBe` Right "on"
  lookupValue "INACTIVE_CLIENTS" "disconnect" ini `shouldBe` Right "off"
  doesFileExist (cfgPath <> "/ca.key") `shouldReturn` True
  -- start
  r <- lines <$> capture_ (withArgs ["start"] $ (100000 `timeout` smpServerCLI cfgPath logPath) `catchAll_` pure (Just ()))
  r `shouldContain` ["SMP server v" <> simplexMQVersion]
  r `shouldContain` (if storeLog then ["Store log: " <> logPath <> "/smp-server-store.log"] else ["Store log disabled."])
  r `shouldContain` ["Listening on port 5223 (TLS)..."]
  r `shouldContain` ["not expiring inactive clients"]
  r `shouldContain` (if basicAuth then ["creating new queues requires password"] else ["creating new queues allowed"])
  -- cert
  let certPath = cfgPath </> "server.crt"
  oldCrt@X.Certificate {} <-
    XF.readSignedObject certPath >>= \case
      [cert'] -> pure . X.signedObject $ X.getSigned cert'
      _ -> error "bad crt format"
  r' <- lines <$> capture_ (withArgs ["cert"] $ (100000 `timeout` smpServerCLI cfgPath logPath) `catchAll_` pure (Just ()))
  r' `shouldContain` ["Generated new server credentials"]
  newCrt <-
    XF.readSignedObject certPath >>= \case
      [cert'] -> pure . X.signedObject $ X.getSigned cert'
      _ -> error "bad crt format after cert"
  X.certSignatureAlg oldCrt `shouldBe` X.certSignatureAlg newCrt
  X.certSubjectDN oldCrt `shouldBe` X.certSubjectDN newCrt
  X.certSerial oldCrt `shouldNotBe` X.certSerial newCrt
  X.certPubKey oldCrt `shouldNotBe` X.certPubKey newCrt
  -- delete
  capture_ (withStdin "Y" . withArgs ["delete"] $ smpServerCLI cfgPath logPath)
    >>= (`shouldSatisfy` ("WARNING: deleting the server will make all queues inaccessible" `isPrefixOf`))
  doesFileExist (cfgPath <> "/ca.key") `shouldReturn` False

smpServerTestStatic :: HasCallStack => IO ()
smpServerTestStatic = do
  setLogLevel LogDebug
  let iniFile = cfgPath <> "/smp-server.ini"
  capture_ (withArgs ["init", "-y", "--no-password", "--web-path", webPath] $ smpServerCLI cfgPath logPath)
    >>= (`shouldSatisfy` (("Server initialized, please provide additional server information in " <> iniFile) `isPrefixOf`))
  doesFileExist (cfgPath <> "/ca.key") `shouldReturn` True
  Right ini <- readIniFile iniFile
  lookupValue "WEB" "static_path" ini `shouldBe` Right (T.pack webPath)
  let web = [("https", "5223"), ("cert", "tests/fixtures/web.pem"), ("key", "tests/fixtures/web.key")]
      ini' = ini {iniSections = HM.adjust (<> web) "WEB" (iniSections ini)}
  writeIniFile iniFile ini'

  Right ini_ <- readIniFile iniFile
  lookupValue "WEB" "https" ini_ `shouldBe` Right "5223"

  let smpServerCLI' = smpServerCLI_ Static.generateSite Static.serveStaticFiles Static.attachStaticFiles
  let server = capture_ (withArgs ["start"] $ smpServerCLI' cfgPath logPath `catchAny` print)
  bracket (async server) cancel $ \_t -> do
    threadDelay 1000000
    html <- BL.readFile $ webPath <> "/index.html"

    Fingerprint fp <- loadFileFingerprint "tests/fixtures/ca.crt"
    let ca = C.KeyHash fp
    manager <- newManager defaultManagerSettings
    HTTP.responseBody <$> HTTP.httpLbs "http://127.0.0.1:8000" manager `shouldReturn` html
    logDebug "Static site works"

    let cfgHttp = defaultTransportClientConfig {alpn = Just ["http/1.1"], useSNI = True}
    let getCerts tls =
          let X.CertificateChain cc = tlsServerCerts tls
           in map (X.signedObject . X.getSigned) cc
    runTLSTransportClient defaultSupportedParamsHTTPS Nothing cfgHttp Nothing "localhost" "5223" (Just ca) $ \tls -> do
      tlsALPN tls `shouldBe` Just "http/1.1"
      case getCerts tls of
        X.Certificate {X.certPubKey = X.PubKeyEC (X.PubKeyEC_Named {X.pubkeyEC_name})} : _ca -> pubkeyEC_name `shouldBe` SEC_p256r1
        leaf : _ -> error $ "Unexpected leaf cert: " <> show leaf
        [] -> error "Empty chain"
    -- HTTP.responseBody <$> HTTP.httpLbs "https://localhost:5223" manager `shouldReturn` html -- "certificate has unknown CA"
    logDebug "HTTPS works"

    let cfgSmp = defaultTransportClientConfig {alpn = Just ["smp/1"], useSNI = False}
    runTLSTransportClient defaultSupportedParams Nothing cfgSmp Nothing "localhost" "5223" Nothing $ \tls -> do
      tlsALPN tls `shouldBe` Just "smp/1"
      case getCerts tls of
        X.Certificate {X.certPubKey = X.PubKeyEd25519 _k} : _ca -> pure ()
        leaf : _ -> error $ "Unexpected leaf cert: " <> show leaf
        [] -> error "Empty chain"
    -- runExceptT (smpClientHandshake tls Nothing ca supportedClientSMPRelayVRange) >>= \case
    --   Right _th -> pure ()
    --   Left te -> error (show te)
    logDebug "SMP works"

ntfServerTest :: Bool -> IO ()
ntfServerTest storeLog = do
  capture_ (withArgs (["init"] <> ["-l" | storeLog]) $ ntfServerCLI ntfCfgPath ntfLogPath)
    >>= (`shouldSatisfy` (("Server initialized, you can modify configuration in " <> ntfCfgPath <> "/ntf-server.ini") `isPrefixOf`))
  Right ini <- readIniFile $ ntfCfgPath <> "/ntf-server.ini"
  lookupValue "STORE_LOG" "enable" ini `shouldBe` Right (if storeLog then "on" else "off")
  lookupValue "STORE_LOG" "log_stats" ini `shouldBe` Right "off"
  lookupValue "TRANSPORT" "port" ini `shouldBe` Right "443"
  lookupValue "TRANSPORT" "websockets" ini `shouldBe` Right "off"
  doesFileExist (ntfCfgPath <> "/ca.key") `shouldReturn` True
  r <- lines <$> capture_ (withArgs ["start"] $ (100000 `timeout` ntfServerCLI ntfCfgPath ntfLogPath) `catchAll_` pure (Just ()))
  r `shouldContain` ["SMP notifications server v" <> simplexMQVersion]
  r `shouldContain` (if storeLog then ["Store log: " <> ntfLogPath <> "/ntf-server-store.log"] else ["Store log disabled."])
  r `shouldContain` ["Listening on port 443 (TLS)..."]
  capture_ (withStdin "Y" . withArgs ["delete"] $ ntfServerCLI ntfCfgPath ntfLogPath)
    >>= (`shouldSatisfy` ("WARNING: deleting the server will make all queues inaccessible" `isPrefixOf`))
  doesFileExist (cfgPath <> "/ca.key") `shouldReturn` False

xftpServerTest :: Bool -> IO ()
xftpServerTest storeLog = do
  capture_ (withArgs (["init", "-p", "tests/tmp", "-q", "10gb"] <> ["-l" | storeLog]) $ xftpServerCLI fileCfgPath fileLogPath)
    >>= (`shouldSatisfy` (("Server initialized, you can modify configuration in " <> fileCfgPath <> "/file-server.ini") `isPrefixOf`))
  Right ini <- readIniFile $ fileCfgPath <> "/file-server.ini"
  lookupValue "STORE_LOG" "enable" ini `shouldBe` Right (if storeLog then "on" else "off")
  lookupValue "STORE_LOG" "log_stats" ini `shouldBe` Right "off"
  lookupValue "TRANSPORT" "port" ini `shouldBe` Right "443"
  doesFileExist (fileCfgPath <> "/ca.key") `shouldReturn` True
  r <- lines <$> capture_ (withArgs ["start"] $ (100000 `timeout` xftpServerCLI fileCfgPath fileLogPath) `catchAll_` pure (Just ()))
  r `shouldContain` ["SimpleX XFTP server v" <> simplexMQVersion]
  r `shouldContain` (if storeLog then ["Store log: " <> fileLogPath <> "/file-server-store.log"] else ["Store log disabled."])
  r `shouldContain` ["Listening on port 443..."]
  capture_ (withStdin "Y" . withArgs ["delete"] $ xftpServerCLI fileCfgPath fileLogPath)
    >>= (`shouldSatisfy` ("WARNING: deleting the server will make all queues inaccessible" `isPrefixOf`))
  doesFileExist (cfgPath <> "/ca.key") `shouldReturn` False
