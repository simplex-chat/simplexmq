{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}
{-# OPTIONS_GHC -fno-warn-ambiguous-fields #-}

module CoreTests.SOCKSSettings where

import Simplex.Messaging.Client
import Simplex.Messaging.Protocol (ErrorType)
import Simplex.Messaging.Transport.Client
import Test.Hspec

socksSettingsTests :: Spec
socksSettingsTests = do
  describe "hostMode and requiredHostMode settings" testHostMode
  describe "socksMode setting, independent of hostMode setting" testSocksMode

testPublicHost :: TransportHost
testPublicHost = "smp.example.com"

testOnionHost :: TransportHost
testOnionHost = "abcdefghijklmnopqrstuvwxyz0123456789abcdefghijklmnopqrst.onion"

testSocksProxy :: SocksProxyWithAuth
testSocksProxy = SocksProxyWithAuth SocksIsolateByAuth defaultSocksProxy

testHostMode :: Spec
testHostMode = do
  describe "requiredHostMode = False (default)" $ do
    it "without socks proxy, should choose onion host only with HMOnion" $ do
      chooseTransportHost @ErrorType defaultNetworkConfig [testPublicHost, testOnionHost] `shouldBe` Right testPublicHost
      chooseHost HMOnionViaSocks Nothing [testPublicHost, testOnionHost] `shouldBe` Right testPublicHost
      chooseHost HMOnion Nothing [testPublicHost, testOnionHost] `shouldBe` Right testOnionHost
      chooseHost HMPublic Nothing [testPublicHost, testOnionHost] `shouldBe` Right testPublicHost
    it "with socks proxy, should choose onion host with HMOnionViaSocks (default) and HMOnion" $ do
      chooseTransportHost @ErrorType defaultNetworkConfig {socksProxy = Just testSocksProxy} [testPublicHost, testOnionHost] `shouldBe` Right testOnionHost
      chooseHost HMOnionViaSocks (Just testSocksProxy) [testPublicHost, testOnionHost] `shouldBe` Right testOnionHost
      chooseHost HMOnion (Just testSocksProxy) [testPublicHost, testOnionHost] `shouldBe` Right testOnionHost
      chooseHost HMPublic (Just testSocksProxy) [testPublicHost, testOnionHost] `shouldBe` Right testPublicHost
    it "should choose any available host, if preferred not available" $ do
      chooseHost HMOnionViaSocks Nothing [testOnionHost] `shouldBe` Right testOnionHost
      chooseHost HMOnion Nothing [testPublicHost] `shouldBe` Right testPublicHost
      chooseHost HMPublic Nothing [testOnionHost] `shouldBe` Right testOnionHost
      chooseHost HMOnionViaSocks (Just testSocksProxy) [testPublicHost] `shouldBe` Right testPublicHost
      chooseHost HMOnion (Just testSocksProxy) [testPublicHost] `shouldBe` Right testPublicHost
      chooseHost HMPublic (Just testSocksProxy) [testOnionHost] `shouldBe` Right testOnionHost
  describe "requiredHostMode = True" $ do
    it "should fail, if preferred host not available" $ do
      testOnionHost `incompatible` (HMOnionViaSocks, Nothing)
      testPublicHost `incompatible` (HMOnion, Nothing)
      testOnionHost `incompatible` (HMPublic, Nothing)
      testPublicHost `incompatible` (HMOnionViaSocks, Just testSocksProxy)
      testPublicHost `incompatible` (HMOnion, Just testSocksProxy)
      testOnionHost `incompatible` (HMPublic, Just testSocksProxy)
    it "should choose preferred host, if available" $ do
      testPublicHost `compatible` (HMOnionViaSocks, Nothing)
      testOnionHost `compatible` (HMOnion, Nothing)
      testPublicHost `compatible` (HMPublic, Nothing)
      testOnionHost `compatible` (HMOnionViaSocks, Just testSocksProxy)
      testOnionHost `compatible` (HMOnion, Just testSocksProxy)
      testPublicHost `compatible` (HMPublic, Just testSocksProxy)
  where
    chooseHost = chooseHostCfg defaultNetworkConfig
    host `incompatible` (hostMode, socksProxy) =
      chooseHostCfg defaultNetworkConfig {requiredHostMode = True} hostMode socksProxy [host] `shouldBe` Left PCEIncompatibleHost
    host `compatible` (hostMode, socksProxy) = do
      chooseHostCfg defaultNetworkConfig {requiredHostMode = True} hostMode socksProxy [host] `shouldBe` Right host
      chooseHostCfg defaultNetworkConfig {requiredHostMode = True} hostMode socksProxy [host, testPublicHost, testOnionHost] `shouldBe` Right host
    chooseHostCfg cfg hostMode socksProxy =
      chooseTransportHost @ErrorType cfg {hostMode, socksProxy}

testSocksMode :: Spec
testSocksMode = do
  it "should not use SOCKS proxy if not specified" $ do
    transportSocksCfg defaultNetworkConfig testPublicHost `shouldBe` Nothing
    transportSocksCfg defaultNetworkConfig testOnionHost `shouldBe` Nothing
    transportSocks Nothing SMAlways testPublicHost `shouldBe` Nothing
    transportSocks Nothing SMAlways testOnionHost `shouldBe` Nothing
    transportSocks Nothing SMOnion testPublicHost `shouldBe` Nothing
    transportSocks Nothing SMOnion testOnionHost `shouldBe` Nothing
  it "should always use SOCKS proxy if specified and (socksMode = SMAlways or (socksMode = SMOnion and onion host))" $ do
    transportSocksCfg defaultNetworkConfig {socksProxy = Just testSocksProxy} testPublicHost `shouldBe` Just defaultSocksProxy
    transportSocksCfg defaultNetworkConfig {socksProxy = Just testSocksProxy} testOnionHost `shouldBe` Just defaultSocksProxy
    transportSocks (Just testSocksProxy) SMAlways testPublicHost `shouldBe` Just defaultSocksProxy
    transportSocks (Just testSocksProxy) SMAlways testOnionHost `shouldBe` Just defaultSocksProxy
    transportSocks (Just testSocksProxy) SMOnion testPublicHost `shouldBe` Nothing
    transportSocks (Just testSocksProxy) SMOnion testOnionHost `shouldBe` Just defaultSocksProxy
  where
    transportSocks proxy socksMode = transportSocksCfg defaultNetworkConfig {socksProxy = proxy, socksMode}
    transportSocksCfg cfg host =
      let TransportClientConfig {socksProxy} = transportClientConfig cfg host
       in socksProxy
