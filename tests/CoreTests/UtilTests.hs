{-# LANGUAGE ScopedTypeVariables #-}

module CoreTests.UtilTests where

import AgentTests.FunctionalAPITests ()
import Control.Exception (Exception, SomeException, throwIO)
import Control.Monad.Except
import Control.Monad.IO.Class
import Data.IORef
import Simplex.Messaging.Util
import Test.Hspec hiding (fit, it)
import qualified UnliftIO.Exception as UE
import Util

utilTests :: Spec
utilTests = do
  describe "problems of lifted try, catch and finally (don't use them)" $ do
    describe "lifted try" $ do
      it "does not catch errors" $ do
        runExceptT (UE.try throwTestError >>= either handleCatch pure) `shouldReturn` Left (TestError "error")
        runExceptT (UE.try throwTestException >>= either handleCatch pure) `shouldThrow` (\(e :: IOError) -> show e == "user error (error)")
      it "with SomeException catches all errors but wraps ExceptT errors" $ do
        runExceptT (UE.try throwTestError >>= either handleException pure) `shouldReturn` Right "caught InternalException {unInternalException = TestError \"error\"}"
        runExceptT (UE.try throwTestException >>= either handleException pure) `shouldReturn` Right "caught user error (error)"
    describe "lifted catch" $ do
      it "does not catch" $ do
        runExceptT (throwTestError `UE.catch` handleCatch) `shouldReturn` Left (TestError "error")
        runExceptT (throwTestException `UE.catch` handleCatch) `shouldThrow` (\(e :: IOError) -> show e == "user error (error)")
      it "with SomeException catches all errors but wraps ExceptT errors" $ do
        runExceptT (throwTestError `UE.catch` handleException) `shouldReturn` Right "caught InternalException {unInternalException = TestError \"error\"}"
        runExceptT (throwTestException `UE.catch` handleException) `shouldReturn` Right "caught user error (error)"
    describe "lifted finally" $ do
      it "with ExceptT error executes final action and stays in ExceptT monad" $ withFinal $ \final ->
        runExceptT (throwTestError `UE.finally` final) `shouldReturn` Left (TestError "error")
      it "with exception executes final action (not always - race condition?) and throws exception" $ withFinal $ \final ->
        runExceptT (throwTestException `UE.finally` final) `shouldThrow` (\(e :: IOError) -> show e == "user error (error)")
  describe "problems of tryError and catchError (don't use them)" $ do
    describe "tryError" $ do
      it "catches ExceptT errors but not Exceptions" $ do
        runExceptT (tryError throwTestError >>= either handleCatch pure) `shouldReturn` Right "caught TestError \"error\""
        runExceptT (tryError throwTestException >>= either handleCatch pure) `shouldThrow` (\(e :: IOError) -> show e == "user error (error)")
    describe "catchError" $ do
      it "catches ExceptT errors but not Exceptions" $ do
        runExceptT (throwTestError `catchError` handleCatch) `shouldReturn` Right "caught TestError \"error\""
        runExceptT (throwTestException `catchError` handleCatch) `shouldThrow` (\(e :: IOError) -> show e == "user error (error)")
  describe "tryAllErrors" $ do
    it "should return ExceptT error as Left" $
      runExceptT (tryAllErrors throwTestError) `shouldReturn` Right (Left (TestError "error"))
    it "should return SomeException as Left" $
      runExceptT (tryAllErrors throwTestException) `shouldReturn` Right (Left (TestException "user error (error)"))
    it "should return no errors as Right" $
      runExceptT (tryAllErrors noErrors) `shouldReturn` Right (Right "no errors")
  describe "catchAllErrors" $ do
    it "should catch ExceptT error" $
      runExceptT (throwTestError `catchAllErrors` handleCatch) `shouldReturn` Right "caught TestError \"error\""
    it "should catch SomeException" $
      runExceptT (throwTestException `catchAllErrors` handleCatch) `shouldReturn` Right "caught TestException \"user error (error)\""
    it "should not throw if there are no errors" $
      runExceptT (noErrors `catchAllErrors` throwError) `shouldReturn` Right "no errors"
  describe "catchThrow" $ do
    it "should re-throw ExceptT error" $
      runExceptT (throwTestError `catchThrow` fromSomeException) `shouldReturn` Left (TestError "error")
    it "should catch SomeException and throw as ExceptT error" $
      runExceptT (throwTestException `catchThrow` fromSomeException) `shouldReturn` Left (TestException "user error (error)")
    it "should not throw if there are no exceptions" $
      runExceptT (noErrors `catchThrow` fromSomeException) `shouldReturn` Right "no errors"
  describe "allFinally should run final action" $ do
    it "then throw ExceptT error" $ withFinal $ \final ->
      runExceptT (throwTestError `allFinally` final) `shouldReturn` Left (TestError "error")
    it "then throw SomeException as ExceptT error" $ withFinal $ \final ->
      runExceptT (throwTestException `allFinally` final) `shouldReturn` Left (TestException "user error (error)")
    it "and should not throw if there are no exceptions" $ withFinal $ \final ->
      runExceptT (noErrors `allFinally` final) `shouldReturn` Right "no errors"
  where
    throwTestError :: ExceptT TestError IO String
    throwTestError = throwError $ TestError "error"
    throwTestException :: ExceptT TestError IO String
    throwTestException = liftIO $ throwIO $ userError "error"
    noErrors :: ExceptT TestError IO String
    noErrors = pure "no errors"
    handleCatch :: TestError -> ExceptT TestError IO String
    handleCatch e = pure $ "caught " <> show e
    handleException :: SomeException -> ExceptT TestError IO String
    handleException e = pure $ "caught " <> show e
    withFinal :: (ExceptT TestError IO String -> IO ()) -> IO ()
    withFinal test = do
      r <- newIORef False
      let final = liftIO $ writeIORef r True >> pure "final"
      test final
      readIORef r `shouldReturn` True

data TestError = TestError String | TestException String
  deriving (Eq, Show)

instance Exception TestError

instance AnyError TestError where
  fromSomeException = TestException . show
