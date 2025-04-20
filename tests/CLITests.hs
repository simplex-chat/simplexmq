{-# LANGUAGE CPP #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

module CLITests where

import AgentTests.FunctionalAPITests (runRight_)
import Control.Logger.Simple
import Control.Monad
import qualified Crypto.PubKey.RSA as RSA
import qualified Data.ByteString.Lazy as BL
import qualified Data.HashMap.Strict as HM
import Data.Ini (Ini (..), lookupValue, readIniFile, writeIniFile)
import Data.List (isPrefixOf)
import qualified Data.Text as T
import qualified Data.X509 as X
import qualified Data.X509.File as XF
import Data.X509.Validation (Fingerprint (..))
import qualified Network.HTTP.Client as H1
import qualified Network.HTTP2.Client as H2
import Simplex.FileTransfer.Server.Main (xftpServerCLI)
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Server.Main (smpServerCLI, smpServerCLI_)
import Simplex.Messaging.Transport (TLS (..), defaultSupportedParams, defaultSupportedParamsHTTPS, simplexMQVersion, supportedClientSMPRelayVRange)
import Simplex.Messaging.Transport.Client (TransportClientConfig (..), defaultTransportClientConfig, runTLSTransportClient, smpClientHandshake)
import Simplex.Messaging.Transport.HTTP2 (HTTP2Body (..))
import qualified Simplex.Messaging.Transport.HTTP2.Client as HC
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

#if defined(dbServerPostgres)
import Simplex.Messaging.Notifications.Server.Main
#endif

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
      it "static files" smpServerTestStatic
#if defined(dbServerPostgres)
  -- TODO [ntfdb] fix
  xdescribe "Ntf server CLI" $ do
    it "should initialize, start and delete the server (no store log)" $ ntfServerTest False
    it "should initialize, start and delete the server (with store log)" $ ntfServerTest True
#endif
  describe "XFTP server CLI" $ do
    it "should initialize, start and delete the server (no store log)" $ xftpServerTest False
    it "should initialize, start and delete the server (with store log)" $ xftpServerTest True

smpServerTest :: Bool -> Bool -> IO ()
smpServerTest storeLog basicAuth = do
  -- init
  capture_ (withArgs (["init", "-y"] <> ["--disable-store-log" | not storeLog] <> ["--no-password" | not basicAuth]) $ smpServerCLI cfgPath logPath)
    >>= (`shouldSatisfy` (("Server initialized, please provide additional server information in " <> cfgPath <> "/smp-server.ini") `isPrefixOf`))
  Right ini <- readIniFile $ cfgPath <> "/smp-server.ini"
  lookupValue "STORE_LOG" "enable" ini `shouldBe` Right (if storeLog then "on" else "off")
  lookupValue "STORE_LOG" "log_stats" ini `shouldBe` Right "off"
  lookupValue "TRANSPORT" "port" ini `shouldBe` Right "5223,443"
  lookupValue "TRANSPORT" "websockets" ini `shouldBe` Right "off"
  lookupValue "AUTH" "new_queues" ini `shouldBe` Right "on"
  lookupValue "INACTIVE_CLIENTS" "disconnect" ini `shouldBe` Right "on"
  doesFileExist (cfgPath <> "/ca.key") `shouldReturn` True
  -- start
  r <- lines <$> capture_ (withArgs ["start"] $ (100000 `timeout` smpServerCLI cfgPath logPath) `catchAll_` pure (Just ()))
  r `shouldContain` ["SMP server v" <> simplexMQVersion]
  r `shouldContain` (if storeLog then ["Store log: " <> logPath <> "/smp-server-store.log"] else ["Store log disabled."])
  r `shouldContain` ["Serving SMP protocol on port 5223 (TLS)...", "Serving SMP protocol on port 443 (TLS)...", "Serving static site on port 443 (TLS)..."]
  r `shouldContain` ["expiring clients inactive for 21600 seconds every 3600 seconds"]
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
  let iniFile = cfgPath <> "/smp-server.ini"
  capture_ (withArgs ["init", "-y", "--no-password", "--web-path", webPath] $ smpServerCLI cfgPath logPath)
    >>= (`shouldSatisfy` (("Server initialized, please provide additional server information in " <> iniFile) `isPrefixOf`))
  doesFileExist (cfgPath <> "/ca.key") `shouldReturn` True
  Right ini <- readIniFile iniFile
  lookupValue "WEB" "static_path" ini `shouldBe` Right (T.pack webPath)
  let transport = [("host", "localhost"), ("port", "5223"), ("log_tls_errors", "off"), ("websockets", "off")]
      web = [("http", "8000"), ("https", "5223"), ("cert", "tests/fixtures/web.crt"), ("key", "tests/fixtures/web.key"), ("static_path", T.pack webPath)]
      ini' = ini {iniSections = HM.insert "TRANSPORT" transport $ HM.insert "WEB" web (iniSections ini)}
  writeIniFile iniFile ini'

  Right ini_ <- readIniFile iniFile
  lookupValue "WEB" "https" ini_ `shouldBe` Right "5223"

  let smpServerCLI' = smpServerCLI_ Static.generateSite Static.serveStaticFiles Static.attachStaticFiles
  let server = capture_ (withArgs ["start"] $ smpServerCLI' cfgPath logPath `catchAny` print)
  bracket (async server) cancel $ \_t -> do
    threadDelay 1000000
    html <- BL.readFile $ webPath <> "/index.html"

    -- "external" CA signing HTTP credentials
    Fingerprint fpHTTP <- loadFileFingerprint "tests/fixtures/ca.crt"
    let caHTTP = C.KeyHash fpHTTP
    manager <- H1.newManager H1.defaultManagerSettings
    H1.responseBody <$> H1.httpLbs "http://127.0.0.1:8000" manager `shouldReturn` html
    logDebug "Plain HTTP works"

    threadDelay 2000000

    let cfgHttp = defaultTransportClientConfig {alpn = Just ["h2"], useSNI = True}
    runTLSTransportClient defaultSupportedParamsHTTPS Nothing cfgHttp Nothing "localhost" "5223" (Just caHTTP) $ \tls -> do
      tlsALPN tls `shouldBe` Just "h2"
      case getCerts tls of
        X.Certificate {X.certPubKey = X.PubKeyRSA rsa} : _ca -> RSA.public_size rsa `shouldBe` 512
        leaf : _ -> error $ "Unexpected leaf cert: " <> show leaf
        [] -> error "Empty chain"

      let h2cfg = HC.defaultHTTP2ClientConfig {HC.bodyHeadSize = 1024 * 1024}
      h2 <- either (error . show) pure =<< HC.attachHTTP2Client h2cfg "localhost" "5223" mempty 65536 tls
      let req = H2.requestNoBody "GET" "/" []
      HC.HTTP2Response {HC.respBody = HTTP2Body {bodyHead = shsBody}} <- either (error . show) pure =<< HC.sendRequest h2 req (Just 1000000)
      BL.fromStrict shsBody `shouldBe` html
    logDebug "Combined HTTPS works"

    -- "local" CA signing SMP credentials
    Fingerprint fpSMP <- loadFileFingerprint (cfgPath <> "/ca.crt")
    let caSMP = C.KeyHash fpSMP
    let cfgSmp = defaultTransportClientConfig {alpn = Just ["smp/1"], useSNI = False}
    runTLSTransportClient defaultSupportedParams Nothing cfgSmp Nothing "localhost" "5223" (Just caSMP) $ \tls -> do
      tlsALPN tls `shouldBe` Just "smp/1"
      case getCerts tls of
        X.Certificate {X.certPubKey = X.PubKeyEd25519 _k} : _ca -> print _ca -- pure ()
        leaf : _ -> error $ "Unexpected leaf cert: " <> show leaf
        [] -> error "Empty chain"
      runRight_ . void $ smpClientHandshake tls Nothing caSMP supportedClientSMPRelayVRange False
    logDebug "Combined SMP works"
  where
    getCerts :: TLS -> [X.Certificate]
    getCerts tls =
      let X.CertificateChain cc = tlsServerCerts tls
       in map (X.signedObject . X.getSigned) cc

#if defined(dbServerPostgres)
ntfServerTest :: Bool -> IO ()
ntfServerTest storeLog = do
  capture_ (withArgs (["init"] <> ["--disable-store-log" | not storeLog]) $ ntfServerCLI ntfCfgPath ntfLogPath)
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
  r `shouldContain` ["Serving SMP protocol on port 443 (TLS)..."]
  capture_ (withStdin "Y" . withArgs ["delete"] $ ntfServerCLI ntfCfgPath ntfLogPath)
    >>= (`shouldSatisfy` ("WARNING: deleting the server will make all queues inaccessible" `isPrefixOf`))
  doesFileExist (cfgPath <> "/ca.key") `shouldReturn` False
#endif

xftpServerTest :: Bool -> IO ()
xftpServerTest storeLog = do
  capture_ (withArgs (["init", "-p", "tests/tmp", "-q", "10gb"] <> ["--disable-store-log" | not storeLog]) $ xftpServerCLI fileCfgPath fileLogPath)
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
