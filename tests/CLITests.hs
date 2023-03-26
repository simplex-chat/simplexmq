{-# LANGUAGE OverloadedStrings #-}

module CLITests where

import Data.Ini (lookupValue, readIniFile)
import Data.List (isPrefixOf)
import Simplex.FileTransfer.Server.Main (xftpServerCLI, xftpServerVersion)
import Simplex.Messaging.Notifications.Server.Main
import Simplex.Messaging.Server.Main
import Simplex.Messaging.Transport (simplexMQVersion)
import Simplex.Messaging.Util (catchAll_)
import System.Directory (doesFileExist)
import System.Environment (withArgs)
import System.IO.Silently (capture_)
import System.Timeout (timeout)
import Test.Hspec
import Test.Main (withStdin)

cfgPath :: FilePath
cfgPath = "tests/tmp/cli/etc/opt/simplex"

logPath :: FilePath
logPath = "tests/tmp/cli/etc/var/simplex"

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
  describe "Ntf server CLI" $ do
    it "should initialize, start and delete the server (no store log)" $ ntfServerTest False
    it "should initialize, start and delete the server (with store log)" $ ntfServerTest True
  describe "XFTP server CLI" $ do
    it "should initialize, start and delete the server (no store log)" $ xftpServerTest False
    it "should initialize, start and delete the server (with store log)" $ xftpServerTest True

smpServerTest :: Bool -> Bool -> IO ()
smpServerTest storeLog basicAuth = do
  capture_ (withArgs (["init", "-y"] <> ["-l" | storeLog] <> ["--no-password" | not basicAuth]) $ smpServerCLI cfgPath logPath)
    >>= (`shouldSatisfy` (("Server initialized, you can modify configuration in " <> cfgPath <> "/smp-server.ini") `isPrefixOf`))
  Right ini <- readIniFile $ cfgPath <> "/smp-server.ini"
  lookupValue "STORE_LOG" "enable" ini `shouldBe` Right (if storeLog then "on" else "off")
  lookupValue "STORE_LOG" "log_stats" ini `shouldBe` Right "off"
  lookupValue "TRANSPORT" "port" ini `shouldBe` Right "5223"
  lookupValue "TRANSPORT" "websockets" ini `shouldBe` Right "off"
  lookupValue "AUTH" "new_queues" ini `shouldBe` Right "on"
  lookupValue "INACTIVE_CLIENTS" "disconnect" ini `shouldBe` Right "off"
  doesFileExist (cfgPath <> "/ca.key") `shouldReturn` True
  r <- lines <$> capture_ (withArgs ["start"] $ (100000 `timeout` smpServerCLI cfgPath logPath) `catchAll_` pure (Just ()))
  r `shouldContain` ["SMP server v" <> simplexMQVersion]
  r `shouldContain` (if storeLog then ["Store log: " <> logPath <> "/smp-server-store.log"] else ["Store log disabled."])
  r `shouldContain` ["Listening on port 5223 (TLS)..."]
  r `shouldContain` ["not expiring inactive clients"]
  r `shouldContain` (if basicAuth then ["creating new queues requires password"] else ["creating new queues allowed"])
  capture_ (withStdin "Y" . withArgs ["delete"] $ smpServerCLI cfgPath logPath)
    >>= (`shouldSatisfy` ("WARNING: deleting the server will make all queues inaccessible" `isPrefixOf`))
  doesFileExist (cfgPath <> "/ca.key") `shouldReturn` False

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
  r `shouldContain` ["SMP notifications server v" <> ntfServerVersion]
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
  r `shouldContain` ["SimpleX XFTP server v" <> xftpServerVersion]
  r `shouldContain` (if storeLog then ["Store log: " <> fileLogPath <> "/file-server-store.log"] else ["Store log disabled."])
  r `shouldContain` ["Listening on port 443..."]
  capture_ (withStdin "Y" . withArgs ["delete"] $ xftpServerCLI fileCfgPath fileLogPath)
    >>= (`shouldSatisfy` ("WARNING: deleting the server will make all queues inaccessible" `isPrefixOf`))
  doesFileExist (cfgPath <> "/ca.key") `shouldReturn` False
