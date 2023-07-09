{-# LANGUAGE ScopedTypeVariables #-}

module CoreTests.UtilTests where

import Control.Exception (Exception, SomeException, throwIO)
import Control.Monad.Except
import Data.IORef
import Simplex.Messaging.Util
import Simplex.Messaging.Client.Agent ()
import Test.Hspec

utilTests :: Spec
utilTests = do
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
      runExceptT (allFinally testErr noErrors final) `shouldReturn` Right "final"
  describe "allFinally specialized as testFinally should run final action" $ do
    let testFinally = allFinally testErr
    it "then throw ExceptT error" $ withFinal $ \final ->
      runExceptT (throwTestError `testFinally` final) `shouldReturn` Left (TestError "error")
    it "then throw SomeException as ExceptT error" $ withFinal $ \final ->
      runExceptT (throwTestException `testFinally` final) `shouldReturn` Left (TestException "user error (error)")
    it "and should not throw if there are no exceptions" $ withFinal $ \final ->
      runExceptT (noErrors `testFinally` final) `shouldReturn` Right "final"
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
    withFinal :: (ExceptT TestError IO String -> IO ()) -> IO ()
    withFinal test = do
      r <- newIORef False
      let final = liftIO $ writeIORef r True >> pure "final"
      test final
      readIORef r `shouldReturn` True

data TestError = TestError String | TestException String
  deriving (Eq, Show)

instance Exception TestError
