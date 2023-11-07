{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module RemoteControl where

import AgentTests.FunctionalAPITests (runRight_)
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
    it "should connect" testNewPairing

testNewPairing :: IO ()
testNewPairing = do
  drg <- drgNew >>= newTVarIO
  hp <- RC.newRCHostPairing
  invVar <- newEmptyMVar
  ctrl <- async . runRight_ $ do
    logNote "c 1"
    (inv, hc, r) <- RC.connectRCHost drg hp (J.String "app")
    logNote "c 2"
    putMVar invVar (inv, hc)
    logNote "c 3"
    Right (_sessId, r') <- atomically $ takeTMVar r
    logNote "c 4"
    Right (_rcHostSession, _rcHelloBody, _hp') <- atomically $ takeTMVar r'
    logNote "c 5"
    threadDelay 1000000
    logNote "ctrl: ciao"
    liftIO $ RC.cancelHostClient hc

  (inv, hc) <- takeMVar invVar
  -- logNote $ decodeUtf8 $ strEncode inv

  host <- async . runRight_ $ do
    logNote "h 1"
    (rcCtrlClient, r) <- RC.connectRCCtrlURI drg inv Nothing (J.String "app")
    logNote "h 2"
    Right (_sessId', r') <- atomically $ takeTMVar r
    logNote "h 3"
    liftIO $ RC.confirmCtrlSession rcCtrlClient True
    logNote "h 4"
    Right (_rcCtrlSession, _rcCtrlPairing) <- atomically $ takeTMVar r'
    logNote "h 5"
    threadDelay 1000000
    logNote "ctrl: adios"

  timeout 10000000 (waitCatch ctrl) >>= \case
    Just (Right ()) -> pure ()
    err -> fail $ "Unexpected controller result: " <> show err

  waitCatch hc.action >>= \case
    Left err -> fromException err `shouldBe` Just AsyncCancelled
    Right () -> fail "Unexpected controller finish"

  timeout 10000000 (waitCatch host) >>= \case
    Just (Right ()) -> pure ()
    err -> fail $ "Unexpected host result: " <> show err
