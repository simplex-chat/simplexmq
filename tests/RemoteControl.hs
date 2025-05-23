{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

module RemoteControl where

import AgentTests.FunctionalAPITests (runRight)
import Control.Logger.Simple
import Crypto.Random (ChaChaDRG)
import qualified Data.Aeson as J
import Data.ByteString.Lazy.Char8 as LB
import Data.List.NonEmpty (NonEmpty (..))
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Encoding.String (StrEncoding (..))
import Simplex.Messaging.Transport (TSbChainKeys (..))
import qualified Simplex.RemoteControl.Client as HC (RCHostClient (action))
import qualified Simplex.RemoteControl.Client as RC
import Simplex.RemoteControl.Discovery (mkLastLocalHost, preferAddress)
import Simplex.RemoteControl.Invitation (RCSignedInvitation, verifySignedInvitation)
import Simplex.RemoteControl.Types
import Test.Hspec hiding (fit, it)
import UnliftIO
import UnliftIO.Concurrent
import Util

remoteControlTests :: Spec
remoteControlTests = do
  describe "preferred bindings should go first" testPreferAddress
  describe "New controller/host pairing" $ do
    it "should connect to new pairing" testNewPairing
    it "should connect to existing pairing" testExistingPairing
  describe "Multicast discovery" $ do
    it "should find paired host and connect" testMulticast

testPreferAddress :: Spec
testPreferAddress = do
  it "suppresses localhost" $
    mkLastLocalHost addrs
      `shouldBe` [ "10.20.30.40" `on` "eth0",
                   "10.20.30.42" `on` "wlan0",
                   "127.0.0.1" `on` "lo"
                 ]
  it "finds by address" $ do
    preferAddress ("127.0.0.1" `on` "lo23") addrs' `shouldBe` addrs -- localhost is back on top
    preferAddress ("10.20.30.42" `on` "wlp2s0") addrs'
      `shouldBe` [ "10.20.30.42" `on` "wlan0",
                   "10.20.30.40" `on` "eth0",
                   "127.0.0.1" `on` "lo"
                 ]
  it "finds by interface" $ do
    preferAddress ("127.1.2.3" `on` "lo") addrs' `shouldBe` addrs
    preferAddress ("0.0.0.0" `on` "eth0") addrs' `shouldBe` addrs'
  it "survives duplicates" $ do
    preferAddress ("0.0.0.0" `on` "eth1") addrsDups `shouldBe` addrsDups
    preferAddress ("0.0.0.0" `on` "eth0") ifaceDups `shouldBe` ifaceDups
  where
    on th interface = RCCtrlAddress {address = either error id $ strDecode th, interface}
    addrs =
      [ "127.0.0.1" `on` "lo", -- localhost may go first and break things
        "10.20.30.40" `on` "eth0",
        "10.20.30.42" `on` "wlan0"
      ]
    addrs' = mkLastLocalHost addrs
    addrsDups = "10.20.30.40" `on` "eth1" : addrs'
    ifaceDups = "10.20.30.41" `on` "eth0" : addrs'

testNewPairing :: IO ()
testNewPairing = do
  drg <- C.newRandom
  hp <- RC.newRCHostPairing drg
  invVar <- newEmptyMVar
  ctrlSessId <- async . runRight $ do
    logNote "c 1"
    (_found, inv, hc, r) <- RC.connectRCHost drg hp (J.String "app") False Nothing Nothing
    logNote "c 2"
    putMVar invVar (inv, hc)
    logNote "c 3"
    Right (sessId, _tls, r') <- atomically $ takeTMVar r
    logNote "c 4"
    Right (rcHostSession, _rcHelloBody, _hp') <- atomically $ takeTMVar r'
    let RCHostSession {tls, sessionKeys = HostSessKeys {chainKeys}} = rcHostSession
        TSbChainKeys {rcvKey, sndKey} = chainKeys
    sndKeyNonce <- atomically $ stateTVar sndKey C.sbcHkdf
    encCmd <- RC.rcEncryptBody sndKeyNonce "command message"
    RC.sendRCPacket tls $ LB.toStrict encCmd
    encResp <- RC.receiveRCPacket tls
    rcvKeyNonce <- atomically $ stateTVar rcvKey C.sbcHkdf
    resp <- RC.rcDecryptBody rcvKeyNonce $ LB.fromStrict encResp
    liftIO $ resp `shouldBe` "response message"
    logNote "c 5"
    threadDelay 250000
    logNote "ctrl: ciao"
    liftIO $ RC.cancelHostClient hc
    pure sessId

  (signedInv, hc) <- takeMVar invVar
  -- logNote $ decodeUtf8 $ strEncode inv
  inv <- maybe (fail "bad invite") pure $ verifySignedInvitation signedInv

  hostSessId <- async . runRight $ do
    logNote "h 1"
    (rcCtrlClient, r) <- RC.connectRCCtrl drg inv Nothing (J.String "app")
    logNote "h 2"
    Right (sessId', _tls, r') <- atomically $ takeTMVar r
    logNote "h 3"
    liftIO $ RC.confirmCtrlSession rcCtrlClient True
    logNote "h 4"
    Right (rcCtrlSession, _rcCtrlPairing) <- atomically $ takeTMVar r'
    let RCCtrlSession {tls, sessionKeys = CtrlSessKeys {chainKeys}} = rcCtrlSession
        TSbChainKeys {rcvKey, sndKey} = chainKeys
    encCmd <- RC.receiveRCPacket tls
    rcvKeyNonce <- atomically $ stateTVar rcvKey C.sbcHkdf
    cmd <- RC.rcDecryptBody rcvKeyNonce $ LB.fromStrict encCmd
    liftIO $ cmd `shouldBe` "command message"
    sndKeyNonce <- atomically $ stateTVar sndKey C.sbcHkdf
    encResp <- RC.rcEncryptBody sndKeyNonce "response message"
    RC.sendRCPacket tls $ LB.toStrict encResp
    logNote "h 5"
    threadDelay 250000
    logNote "ctrl: adios"
    pure sessId'

  waitCatch (HC.action hc) >>= \case
    Left err -> fromException err `shouldBe` Just AsyncCancelled
    Right () -> fail "Unexpected controller finish"

  timeout 5000000 (waitBoth ctrlSessId hostSessId) >>= \case
    Just (sessId, sessId') -> sessId `shouldBe` sessId'
    _ -> fail "timeout"

testExistingPairing :: IO ()
testExistingPairing = do
  drg <- C.newRandom
  invVar <- newEmptyMVar
  hp <- RC.newRCHostPairing drg
  ctrl <- runCtrl drg False hp invVar
  inv <- takeMVar invVar
  let cp_ = Nothing
  host <- runHostURI drg cp_ inv
  timeout 5000000 (waitBoth ctrl host) >>= \case
    Nothing -> fail "timeout"
    Just (hp', cp') -> do
      ctrl' <- runCtrl drg False hp' invVar
      inv' <- takeMVar invVar
      host' <- runHostURI drg (Just cp') inv'
      timeout 5000000 (waitBoth ctrl' host') >>= \case
        Nothing -> fail "timeout"
        Just (_hp2, cp2) -> do
          ctrl2 <- runCtrl drg False hp' invVar -- old host pairing used to test controller not updating state
          inv2 <- takeMVar invVar
          host2 <- runHostURI drg (Just cp2) inv2
          timeout 5000000 (waitBoth ctrl2 host2) >>= \case
            Nothing -> fail "timeout"
            Just (hp3, cp3) -> do
              ctrl3 <- runCtrl drg False hp3 invVar
              inv3 <- takeMVar invVar
              host3 <- runHostURI drg (Just cp3) inv3
              timeout 5000000 (waitBoth ctrl3 host3) >>= \case
                Nothing -> fail "timeout"
                Just _ -> pure ()

testMulticast :: IO ()
testMulticast = do
  drg <- C.newRandom
  subscribers <- newTMVarIO 0
  invVar <- newEmptyMVar
  hp <- RC.newRCHostPairing drg
  ctrl <- runCtrl drg False hp invVar
  inv <- takeMVar invVar
  let cp_ = Nothing
  host <- runHostURI drg cp_ inv
  timeout 5000000 (waitBoth ctrl host) >>= \case
    Nothing -> fail "timeout"
    Just (hp', cp') -> do
      ctrl' <- runCtrl drg True hp' invVar
      _inv <- takeMVar invVar
      host' <- runHostMulticast drg subscribers cp'
      timeout 5000000 (waitBoth ctrl' host') >>= \case
        Nothing -> fail "timeout"
        Just _ -> pure ()

runCtrl :: TVar ChaChaDRG -> Bool -> RCHostPairing -> MVar RCSignedInvitation -> IO (Async RCHostPairing)
runCtrl drg multicast hp invVar = async . runRight $ do
  (_found, inv, hc, r) <- RC.connectRCHost drg hp (J.String "app") multicast Nothing Nothing
  putMVar invVar inv
  Right (_sessId, _tls, r') <- atomically $ takeTMVar r
  Right (_rcHostSession, _rcHelloBody, hp') <- atomically $ takeTMVar r'
  threadDelay 250000
  liftIO $ RC.cancelHostClient hc
  pure hp'

runHostURI :: TVar ChaChaDRG -> Maybe RCCtrlPairing -> RCSignedInvitation -> IO (Async RCCtrlPairing)
runHostURI drg cp_ signedInv = async . runRight $ do
  inv <- maybe (fail "bad invite") pure $ verifySignedInvitation signedInv
  (rcCtrlClient, r) <- RC.connectRCCtrl drg inv cp_ (J.String "app")
  Right (_sessId', _tls, r') <- atomically $ takeTMVar r
  liftIO $ RC.confirmCtrlSession rcCtrlClient True
  Right (_rcCtrlSession, cp') <- atomically $ takeTMVar r'
  threadDelay 250000
  pure cp'

runHostMulticast :: TVar ChaChaDRG -> TMVar Int -> RCCtrlPairing -> IO (Async RCCtrlPairing)
runHostMulticast drg subscribers cp = async . runRight $ do
  (pairing, inv) <- RC.discoverRCCtrl subscribers (cp :| [])
  (rcCtrlClient, r) <- RC.connectRCCtrl drg inv (Just pairing) (J.String "app")
  Right (_sessId', _tls, r') <- atomically $ takeTMVar r
  liftIO $ RC.confirmCtrlSession rcCtrlClient True
  Right (_rcCtrlSession, cp') <- atomically $ takeTMVar r'
  threadDelay 250000
  pure cp'
