{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module RemoteControl where

import Control.Logger.Simple
import Control.Monad.Except (runExceptT)
import Crypto.Random (drgNew)
import qualified Data.Aeson as J
import qualified Simplex.RemoteControl.Client as RC
import Simplex.Messaging.Util
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
  ctrl <- async . runExceptT $ do
    logNote "c 1"
    (inv, hc, var) <- RC.connectRCHost drg hp (J.String "app")
    logNote "c 2"
    putMVar invVar (inv, hc)
    logNote "c 3"
    (_sessId, vars') <- atomically $ takeTMVar var
    logNote "c 4"
    (_rcHostSession, rcHelloBody, _hp') <- atomically $ takeTMVar vars'
    logNote "c 5"
    threadDelay 1000000
    logNote $ tshow rcHelloBody
    logNote "ctrl: ciao"
    liftIO $ RC.cancelHostClient hc

  (inv, hc) <- takeMVar invVar
  -- logNote $ decodeUtf8 $ strEncode inv

  host <- async . runExceptT $ do
    logNote "h 1"
    (rcCtrlClient, var) <- RC.connectRCCtrlURI drg inv Nothing (J.String "app")
    logNote "h 2"
    (_rcCtrlSession, _rcCtrlPairing) <- atomically $ takeTMVar var
    logNote "h 3"
    liftIO $ RC.confirmCtrlSession rcCtrlClient True
    logNote "h 4"
    threadDelay 1000000
    logNote "ctrl: adios"

  timeout 10000000 (waitCatch ctrl) >>= \case
    Just (Right (Right ())) -> pure ()
    err -> fail $ "Unexpected controller result: " <> show err

  waitCatch hc.action >>= \case
    Left err -> fromException err `shouldBe` Just AsyncCancelled
    Right () -> fail "Unexpected controller finish"

  timeout 10000000 (waitCatch host) >>= \case
    Just (Right (Right ())) -> pure ()
    err -> fail $ "Unexpected host result: " <> show err
