{-# LANGUAGE ScopedTypeVariables #-}

module CoreTests.UtilTests where

import Control.Exception (Exception, SomeException, throwIO)
import Control.Monad.Except
import Control.Monad.IO.Class
import Data.IORef
import Simplex.Messaging.Client.Agent ()
import Simplex.Messaging.Util
import Test.Hspec
import qualified UnliftIO.Exception as UE

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
      runExceptT (tryAllErrors testErr throwTestError) `shouldReturn` Right (Left (TestError "error"))
    it "should return SomeException as Left" $
      runExceptT (tryAllErrors testErr throwTestException) `shouldReturn` Right (Left (TestException "user error (error)"))
    it "should return no errors as Right" $
      runExceptT (tryAllErrors testErr noErrors) `shouldReturn` Right (Right "no errors")
  describe "tryAllErrors specialized as tryTestError" $ do
    let tryTestError = tryAllErrors testErr
    it "should return ExceptT error as Left" $
      runExceptT (tryTestError throwTestError) `shouldReturn` Right (Left (TestError "error"))
    it "should return SomeException as Left" $
      runExceptT (tryTestError throwTestException) `shouldReturn` Right (Left (TestException "user error (error)"))
    it "should return no errors as Right" $
      runExceptT (tryTestError noErrors) `shouldReturn` Right (Right "no errors")
  describe "catchAllErrors" $ do
    it "should catch ExceptT error" $
      runExceptT (catchAllErrors testErr throwTestError handleCatch) `shouldReturn` Right "caught TestError \"error\""
    it "should catch SomeException" $
      runExceptT (catchAllErrors testErr throwTestException handleCatch) `shouldReturn` Right "caught TestException \"user error (error)\""
    it "should not throw if there are no errors" $
      runExceptT (catchAllErrors testErr noErrors throwError) `shouldReturn` Right "no errors"
  describe "catchAllErrors specialized as catchTestError" $ do
    let catchTestError = catchAllErrors testErr
    it "should catch ExceptT error" $
      runExceptT (throwTestError `catchTestError` handleCatch) `shouldReturn` Right "caught TestError \"error\""
    it "should catch SomeException" $
      runExceptT (throwTestException `catchTestError` handleCatch) `shouldReturn` Right "caught TestException \"user error (error)\""
    it "should not throw if there are no errors" $
      runExceptT (noErrors `catchTestError` throwError) `shouldReturn` Right "no errors"
  describe "catchThrow" $ do
    it "should re-throw ExceptT error" $
      runExceptT (throwTestError `catchThrow` testErr) `shouldReturn` Left (TestError "error")
    it "should catch SomeException and throw as ExceptT error" $
      runExceptT (throwTestException `catchThrow` testErr) `shouldReturn` Left (TestException "user error (error)")
    it "should not throw if there are no exceptions" $
      runExceptT (noErrors `catchThrow` testErr) `shouldReturn` Right "no errors"
  describe "allFinally should run final action" $ do
    it "then throw ExceptT error" $ withFinal $ \final ->
      runExceptT (allFinally testErr throwTestError final) `shouldReturn` Left (TestError "error")
    it "then throw SomeException as ExceptT error" $ withFinal $ \final ->
      runExceptT (allFinally testErr throwTestException final) `shouldReturn` Left (TestException "user error (error)")
    it "and should not throw if there are no exceptions" $ withFinal $ \final ->
      runExceptT (allFinally testErr noErrors final) `shouldReturn` Right "no errors"
  describe "allFinally specialized as testFinally should run final action" $ do
    let testFinally = allFinally testErr
    it "then throw ExceptT error" $ withFinal $ \final ->
      runExceptT (throwTestError `testFinally` final) `shouldReturn` Left (TestError "error")
    it "then throw SomeException as ExceptT error" $ withFinal $ \final ->
      runExceptT (throwTestException `testFinally` final) `shouldReturn` Left (TestException "user error (error)")
    it "and should not throw if there are no exceptions" $ withFinal $ \final ->
      runExceptT (noErrors `testFinally` final) `shouldReturn` Right "no errors"
  where
    throwTestError :: ExceptT TestError IO String
    throwTestError = throwError $ TestError "error"
    throwTestException :: ExceptT TestError IO String
    throwTestException = liftIO $ throwIO $ userError "error"
    noErrors :: ExceptT TestError IO String
    noErrors = pure "no errors"
    testErr :: SomeException -> TestError
    testErr = TestException . show
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
