{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module RemoteControl where

import AgentTests.FunctionalAPITests (runRight)
import Control.Logger.Simple
import Crypto.Random (drgNew)
import qualified Data.Aeson as J
import qualified Simplex.RemoteControl.Client as RC
import Test.Hspec
import UnliftIO
import UnliftIO.Concurrent

remoteControlTests :: Spec
remoteControlTests = do
  describe "New controller/host pairing" $ do
    it "should connect to new pairing" testNewPairing
    it "should connect to existing pairing" testExistingPairing

testNewPairing :: IO ()
testNewPairing = do
  drg <- drgNew >>= newTVarIO
  hp <- RC.newRCHostPairing
  invVar <- newEmptyMVar
  ctrlSessId <- async . runRight $ do
    logNote "c 1"
    (inv, hc, r) <- RC.connectRCHost drg hp (J.String "app")
    logNote "c 2"
    putMVar invVar (inv, hc)
    logNote "c 3"
    Right (sessId, _tls, r') <- atomically $ takeTMVar r
    logNote "c 4"
    Right (_rcHostSession, _rcHelloBody, _hp') <- atomically $ takeTMVar r'
    logNote "c 5"
    threadDelay 250000
    logNote "ctrl: ciao"
    liftIO $ RC.cancelHostClient hc
    pure sessId

  (inv, hc) <- takeMVar invVar
  -- logNote $ decodeUtf8 $ strEncode inv

  hostSessId <- async . runRight $ do
    logNote "h 1"
    (rcCtrlClient, r) <- RC.connectRCCtrlURI drg inv Nothing (J.String "app")
    logNote "h 2"
    Right (sessId', _tls, r') <- atomically $ takeTMVar r
    logNote "h 3"
    liftIO $ RC.confirmCtrlSession rcCtrlClient True
    logNote "h 4"
    Right (_rcCtrlSession, _rcCtrlPairing) <- atomically $ takeTMVar r'
    logNote "h 5"
    threadDelay 250000
    logNote "ctrl: adios"
    pure sessId'

  waitCatch hc.action >>= \case
    Left err -> fromException err `shouldBe` Just AsyncCancelled
    Right () -> fail "Unexpected controller finish"

  timeout 5000000 (waitBoth ctrlSessId hostSessId) >>= \case
    Just (sessId, sessId') -> sessId `shouldBe` sessId'
    _ -> fail "timeout"

testExistingPairing :: IO ()
testExistingPairing = do
  drg <- drgNew >>= newTVarIO
  invVar <- newEmptyMVar
  hp <- liftIO $ RC.newRCHostPairing
  ctrl <- runCtrl drg hp invVar
  inv <- takeMVar invVar
  let cp_ = Nothing
  host <- runHost drg cp_ inv
  timeout 5000000 (waitBoth ctrl host) >>= \case
    Nothing -> fail "timeout"
    Just (hp', cp') -> do
      ctrl' <- runCtrl drg hp' invVar
      inv' <- takeMVar invVar
      host' <- runHost drg (Just cp') inv'
      timeout 5000000 (waitBoth ctrl' host') >>= \case
        Nothing -> fail "timeout"
        Just (_hp2, cp2) -> do
          ctrl2 <- runCtrl drg hp' invVar -- old host pairing used to test controller not updating state
          inv2 <- takeMVar invVar
          host2 <- runHost drg (Just cp2) inv2
          timeout 5000000 (waitBoth ctrl2 host2) >>= \case
            Nothing -> fail "timeout"
            Just (hp3, cp3) -> do
              ctrl3 <- runCtrl drg hp3 invVar
              inv3 <- takeMVar invVar
              host3 <- runHost drg (Just cp3) inv3
              timeout 5000000 (waitBoth ctrl3 host3) >>= \case
                Nothing -> fail "timeout"
                Just _ -> pure ()
  where
    runCtrl drg hp invVar = async . runRight $ do
      (inv, hc, r) <- RC.connectRCHost drg hp (J.String "app")
      putMVar invVar inv
      Right (_sessId, _tls, r') <- atomically $ takeTMVar r
      Right (_rcHostSession, _rcHelloBody, hp') <- atomically $ takeTMVar r'
      threadDelay 250000
      liftIO $ RC.cancelHostClient hc
      pure hp'
    runHost drg cp_ inv = async . runRight $ do
      (rcCtrlClient, r) <- RC.connectRCCtrlURI drg inv cp_ (J.String "app")
      Right (_sessId', _tls, r') <- atomically $ takeTMVar r
      liftIO $ RC.confirmCtrlSession rcCtrlClient True
      Right (_rcCtrlSession, cp') <- atomically $ takeTMVar r'
      threadDelay 250000
      pure cp'
