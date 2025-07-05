{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}
{-# OPTIONS_GHC -fno-warn-ambiguous-fields #-}

module CoreTests.SOCKSSettings where

import Network.Socket (SockAddr (..), tupleToHostAddress)
import Simplex.Messaging.Client
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Protocol (ErrorType)
import Simplex.Messaging.Transport.Client
import Test.Hspec hiding (fit, it)
import Util

socksSettingsTests :: Spec
socksSettingsTests = do
  describe "hostMode and requiredHostMode settings" testHostMode
  describe "socksMode setting, independent of hostMode setting" testSocksMode
  describe "socks proxy address encoding" testSocksProxyEncoding

testPublicHost :: TransportHost
testPublicHost = "smp.example.com"

testOnionHost :: TransportHost
testOnionHost = "abcdefghijklmnopqrstuvwxyz0123456789abcdefghijklmnopqrst.onion"

testHostMode :: Spec
testHostMode = do
  describe "requiredHostMode = False (default)" $ do
    it "without socks proxy, should choose onion host only with HMOnion" $ do
      chooseTransportHost @ErrorType defaultNetworkConfig [testPublicHost, testOnionHost] `shouldBe` Right testPublicHost
      chooseHost HMOnionViaSocks Nothing [testPublicHost, testOnionHost] `shouldBe` Right testPublicHost
      chooseHost HMOnion Nothing [testPublicHost, testOnionHost] `shouldBe` Right testOnionHost
      chooseHost HMPublic Nothing [testPublicHost, testOnionHost] `shouldBe` Right testPublicHost
    it "with socks proxy, should choose onion host with HMOnionViaSocks (default) and HMOnion" $ do
      chooseTransportHost @ErrorType defaultNetworkConfig {socksProxy = Just defaultSocksProxyWithAuth} [testPublicHost, testOnionHost] `shouldBe` Right testOnionHost
      chooseHost HMOnionViaSocks (Just defaultSocksProxyWithAuth) [testPublicHost, testOnionHost] `shouldBe` Right testOnionHost
      chooseHost HMOnion (Just defaultSocksProxyWithAuth) [testPublicHost, testOnionHost] `shouldBe` Right testOnionHost
      chooseHost HMPublic (Just defaultSocksProxyWithAuth) [testPublicHost, testOnionHost] `shouldBe` Right testPublicHost
    it "should choose any available host, if preferred not available" $ do
      chooseHost HMOnionViaSocks Nothing [testOnionHost] `shouldBe` Right testOnionHost
      chooseHost HMOnion Nothing [testPublicHost] `shouldBe` Right testPublicHost
      chooseHost HMPublic Nothing [testOnionHost] `shouldBe` Right testOnionHost
      chooseHost HMOnionViaSocks (Just defaultSocksProxyWithAuth) [testPublicHost] `shouldBe` Right testPublicHost
      chooseHost HMOnion (Just defaultSocksProxyWithAuth) [testPublicHost] `shouldBe` Right testPublicHost
      chooseHost HMPublic (Just defaultSocksProxyWithAuth) [testOnionHost] `shouldBe` Right testOnionHost
  describe "requiredHostMode = True" $ do
    it "should fail, if preferred host not available" $ do
      testOnionHost `incompatible` (HMOnionViaSocks, Nothing)
      testPublicHost `incompatible` (HMOnion, Nothing)
      testOnionHost `incompatible` (HMPublic, Nothing)
      testPublicHost `incompatible` (HMOnionViaSocks, Just defaultSocksProxyWithAuth)
      testPublicHost `incompatible` (HMOnion, Just defaultSocksProxyWithAuth)
      testOnionHost `incompatible` (HMPublic, Just defaultSocksProxyWithAuth)
    it "should choose preferred host, if available" $ do
      testPublicHost `compatible` (HMOnionViaSocks, Nothing)
      testOnionHost `compatible` (HMOnion, Nothing)
      testPublicHost `compatible` (HMPublic, Nothing)
      testOnionHost `compatible` (HMOnionViaSocks, Just defaultSocksProxyWithAuth)
      testOnionHost `compatible` (HMOnion, Just defaultSocksProxyWithAuth)
      testPublicHost `compatible` (HMPublic, Just defaultSocksProxyWithAuth)
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
    transportSocksCfg defaultNetworkConfig {socksProxy = Just defaultSocksProxyWithAuth} testPublicHost `shouldBe` Just defaultSocksProxy
    transportSocksCfg defaultNetworkConfig {socksProxy = Just defaultSocksProxyWithAuth} testOnionHost `shouldBe` Just defaultSocksProxy
    transportSocks (Just defaultSocksProxyWithAuth) SMAlways testPublicHost `shouldBe` Just defaultSocksProxy
    transportSocks (Just defaultSocksProxyWithAuth) SMAlways testOnionHost `shouldBe` Just defaultSocksProxy
    transportSocks (Just defaultSocksProxyWithAuth) SMOnion testPublicHost `shouldBe` Nothing
    transportSocks (Just defaultSocksProxyWithAuth) SMOnion testOnionHost `shouldBe` Just defaultSocksProxy
  where
    transportSocks proxy socksMode = transportSocksCfg defaultNetworkConfig {socksProxy = proxy, socksMode}
    transportSocksCfg cfg host =
      let TransportClientConfig {socksProxy} = transportClientConfig cfg NRMInteractive host False Nothing
       in socksProxy

testSocksProxyEncoding :: Spec
testSocksProxyEncoding = do
  it "should decode SOCKS proxy with isolate-by-auth mode" $ do
    let authIsolate proxy = Right $ SocksProxyWithAuth SocksIsolateByAuth proxy
    strDecode "" `shouldBe` authIsolate defaultSocksProxy
    strDecode ":9050" `shouldBe` authIsolate defaultSocksProxy
    strDecode ":8080" `shouldBe` authIsolate (SocksProxy $ SockAddrInet 8080 $ tupleToHostAddress defaultSocksHost)
    strDecode "127.0.0.1" `shouldBe` authIsolate defaultSocksProxy
    strDecode "1.1.1.1" `shouldBe` authIsolate (SocksProxy $ SockAddrInet 9050 $ tupleToHostAddress (1, 1, 1, 1))
    strDecode "::1" `shouldBe` authIsolate (SocksProxy $ SockAddrInet6 9050 0 (0, 0, 0, 1) 0)
    strDecode "[fd12:3456:789a:1::1]" `shouldBe` authIsolate (SocksProxy $ SockAddrInet6 9050 0 (0xfd123456, 0x789a0001, 0, 1) 0)
    strDecode "127.0.0.1:9050" `shouldBe` authIsolate defaultSocksProxy
    strDecode "127.0.0.1:8080" `shouldBe` authIsolate (SocksProxy $ SockAddrInet 8080 $ tupleToHostAddress defaultSocksHost)
    strDecode "[::1]:9050" `shouldBe` authIsolate (SocksProxy $ SockAddrInet6 9050 0 (0, 0, 0, 1) 0)
    strDecode "[::1]:8080" `shouldBe` authIsolate (SocksProxy $ SockAddrInet6 8080 0 (0, 0, 0, 1) 0)
    strDecode "[fd12:3456:789a:1::1]:8080" `shouldBe` authIsolate (SocksProxy $ SockAddrInet6 8080 0 (0xfd123456, 0x789a0001, 0, 1) 0)
    strEncode (SocksProxyWithAuth SocksIsolateByAuth defaultSocksProxy) `shouldBe` "127.0.0.1:9050"
    strEncode (SocksProxyWithAuth SocksIsolateByAuth (SocksProxy $ SockAddrInet6 9050 0 (0, 0, 0, 1) 0)) `shouldBe` "[::1]:9050"
    strEncode (SocksProxyWithAuth SocksIsolateByAuth (SocksProxy $ SockAddrInet6 8080 0 (0xfd123456, 0x789a0001, 0, 1) 0)) `shouldBe` "[fd12:3456:789a:1::1]:8080"
  it "should decode SOCKS proxy without credentials" $ do
    let authNull proxy = Right $ SocksProxyWithAuth SocksAuthNull proxy
    strDecode "@" `shouldBe` authNull defaultSocksProxy
    strDecode "@:9050" `shouldBe` authNull defaultSocksProxy
    strDecode "@127.0.0.1" `shouldBe` authNull defaultSocksProxy
    strDecode "@1.1.1.1" `shouldBe` authNull (SocksProxy $ SockAddrInet 9050 $ tupleToHostAddress (1, 1, 1, 1))
    strDecode "@127.0.0.1:9050" `shouldBe` authNull defaultSocksProxy
    strDecode "@[fd12:3456:789a:1::1]:8080" `shouldBe` authNull (SocksProxy $ SockAddrInet6 8080 0 (0xfd123456, 0x789a0001, 0, 1) 0)
    strEncode (SocksProxyWithAuth SocksAuthNull defaultSocksProxy) `shouldBe` "@127.0.0.1:9050"
    strEncode (SocksProxyWithAuth SocksAuthNull (SocksProxy $ SockAddrInet6 9050 0 (0, 0, 0, 1) 0)) `shouldBe` "@[::1]:9050"
    strEncode (SocksProxyWithAuth SocksAuthNull (SocksProxy $ SockAddrInet6 8080 0 (0xfd123456, 0x789a0001, 0, 1) 0)) `shouldBe` "@[fd12:3456:789a:1::1]:8080"
  it "should decode SOCKS proxy with credentials" $ do
    let auth = SocksAuthUsername {username = "user", password = "pass"}
        authUser proxy = Right $ SocksProxyWithAuth auth proxy
    strDecode "user:pass@" `shouldBe` authUser defaultSocksProxy
    strDecode "user:pass@:9050" `shouldBe` authUser defaultSocksProxy
    strDecode "user:pass@127.0.0.1" `shouldBe` authUser defaultSocksProxy
    strDecode "user:pass@127.0.0.1:9050" `shouldBe` authUser defaultSocksProxy
    strDecode "user:pass@fd12:3456:789a:1::1" `shouldBe` authUser (SocksProxy $ SockAddrInet6 9050 0 (0xfd123456, 0x789a0001, 0, 1) 0)
    strDecode "user:pass@[fd12:3456:789a:1::1]:8080" `shouldBe` authUser (SocksProxy $ SockAddrInet6 8080 0 (0xfd123456, 0x789a0001, 0, 1) 0)
    strEncode (SocksProxyWithAuth auth defaultSocksProxy) `shouldBe` "user:pass@127.0.0.1:9050"
    strEncode (SocksProxyWithAuth auth (SocksProxy $ SockAddrInet6 9050 0 (0, 0, 0, 1) 0)) `shouldBe` "user:pass@[::1]:9050"
    strEncode (SocksProxyWithAuth auth (SocksProxy $ SockAddrInet6 8080 0 (0xfd123456, 0x789a0001, 0, 1) 0)) `shouldBe` "user:pass@[fd12:3456:789a:1::1]:8080"
