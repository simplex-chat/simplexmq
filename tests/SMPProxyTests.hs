module SMPProxyTests where

import SMPClient (proxyCfg)
import Test.Hspec

smpProxyTests :: Spec
smpProxyTests = focus $ do
  describe "server configuration" $ do
    it "refuses proxy handshake unless enabled" todo
    it "checks basic auth in server requests" todo
  describe "proxy requests" $ do
    describe "bad relay URIs" $ do
      it "host not resolved" todo
      it "when SMP port blackholed" todo
      it "no SMP service at host/port" todo
      it "bad SMP fingerprint" todo
    it "batching proxy requests" todo
  describe "forwarding requests" $ do
    it "sender-proxy-relay-recipient works" todo
    it "similar timing for proxied and direct sends" todo

todo :: IO ()
todo = do
  fail "TODO"
