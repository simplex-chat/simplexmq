{-# LANGUAGE OverloadedStrings #-}

module CLITests where

import Data.Ini (lookupValue, readIniFile)
import Data.List (isPrefixOf)
import Simplex.Messaging.Notifications.Server.Main
import Simplex.Messaging.Server.Main
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

cliTests :: Spec
cliTests = do
  describe "SMP server CLI" $ do
    it "should initialize, start and delete the server (no store log)" $ smpServerTest False
    it "should initialize, start and delete the server (with store log)" $ smpServerTest True
  describe "Ntf server CLI" $ do
    it "should initialize, start and delete the server (no store log)" $ ntfServerTest False
    it "should initialize, start and delete the server (with store log)" $ ntfServerTest True

smpServerTest :: Bool -> IO ()
smpServerTest enableStoreLog = do
  capture_ (withArgs (["init"] <> ["-l" | enableStoreLog]) $ smpServerCLI cfgPath logPath)
    >>= (`shouldSatisfy` (("Server initialized, you can modify configuration in " <> cfgPath <> "/smp-server.ini") `isPrefixOf`))
  Right ini <- readIniFile $ cfgPath <> "/smp-server.ini"
  lookupValue "STORE_LOG" "enable" ini `shouldBe` Right (if enableStoreLog then "on" else "off")
  lookupValue "STORE_LOG" "log_stats" ini `shouldBe` Right "off"
  lookupValue "TRANSPORT" "port" ini `shouldBe` Right "5223"
  lookupValue "TRANSPORT" "websockets" ini `shouldBe` Right "off"
  lookupValue "AUTH" "new_queues" ini `shouldBe` Right "on"
  lookupValue "INACTIVE_CLIENTS" "disconnect" ini `shouldBe` Right "off"
  doesFileExist (cfgPath <> "/ca.key") `shouldReturn` True
  r <- lines <$> capture_ (withArgs ["start"] $ (100000 `timeout` smpServerCLI cfgPath logPath) `catchAll_` pure (Just ()))
  r `shouldContain` ["SMP server v3.4.0"]
  r `shouldContain` (if enableStoreLog then ["Store log: " <> logPath <> "/smp-server-store.log"] else ["Store log disabled."])
  r `shouldContain` ["Listening on port 5223 (TLS)..."]
  r `shouldContain` ["not expiring inactive clients"]
  r `shouldContain` ["creating new queues allowed"]
  capture_ (withStdin "Y" . withArgs ["delete"] $ smpServerCLI cfgPath logPath)
    >>= (`shouldSatisfy` ("WARNING: deleting the server will make all queues inaccessible" `isPrefixOf`))
  doesFileExist (cfgPath <> "/ca.key") `shouldReturn` False

ntfServerTest :: Bool -> IO ()
ntfServerTest enableStoreLog = do
  capture_ (withArgs (["init"] <> ["-l" | enableStoreLog]) $ ntfServerCLI ntfCfgPath ntfLogPath)
    >>= (`shouldSatisfy` (("Server initialized, you can modify configuration in " <> ntfCfgPath <> "/ntf-server.ini") `isPrefixOf`))
  Right ini <- readIniFile $ ntfCfgPath <> "/ntf-server.ini"
  lookupValue "STORE_LOG" "enable" ini `shouldBe` Right (if enableStoreLog then "on" else "off")
  lookupValue "STORE_LOG" "log_stats" ini `shouldBe` Right "off"
  lookupValue "TRANSPORT" "port" ini `shouldBe` Right "443"
  lookupValue "TRANSPORT" "websockets" ini `shouldBe` Right "off"
  doesFileExist (ntfCfgPath <> "/ca.key") `shouldReturn` True
  r <- lines <$> capture_ (withArgs ["start"] $ (100000 `timeout` ntfServerCLI ntfCfgPath ntfLogPath) `catchAll_` pure (Just ()))
  r `shouldContain` ["SMP notifications server v1.2.0"]
  r `shouldContain` (if enableStoreLog then ["Store log: " <> ntfLogPath <> "/ntf-server-store.log"] else ["Store log disabled."])
  r `shouldContain` ["Listening on port 443 (TLS)..."]
  capture_ (withStdin "Y" . withArgs ["delete"] $ ntfServerCLI ntfCfgPath ntfLogPath)
    >>= (`shouldSatisfy` ("WARNING: deleting the server will make all queues inaccessible" `isPrefixOf`))
  doesFileExist (cfgPath <> "/ca.key") `shouldReturn` False
