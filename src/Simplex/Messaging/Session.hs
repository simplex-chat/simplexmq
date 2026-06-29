{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Simplex.Messaging.Session
  ( SessionVar (..),
    getSessVar,
    removeSessVar,
    withGetSessVar,
    withGetSessVar',
    tryReadSessVar,
  ) where

import Control.Concurrent.STM
import Control.Monad.Except (ExceptT (..), runExceptT)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.IO.Unlift (MonadUnliftIO)
import Data.Time (UTCTime)
import Simplex.Messaging.TMap (TMap)
import qualified Simplex.Messaging.TMap as TM
import Simplex.Messaging.Util (whenM, ($>>=))
import UnliftIO.Exception (bracketOnError)

data SessionVar a = SessionVar
  { sessionVar :: TMVar a,
    sessionVarId :: Int,
    sessionVarTs :: UTCTime
  }

getSessVar :: forall k a. Ord k => TVar Int -> k -> TMap k (SessionVar a) -> UTCTime -> STM (Either (SessionVar a) (SessionVar a))
getSessVar sessSeq sessKey vs sessionVarTs = maybe (Left <$> newSessionVar) (pure . Right) =<< TM.lookup sessKey vs
  where
    newSessionVar :: STM (SessionVar a)
    newSessionVar = do
      sessionVar <- newEmptyTMVar
      sessionVarId <- stateTVar sessSeq $ \next -> (next, next + 1)
      let v = SessionVar {sessionVar, sessionVarId, sessionVarTs}
      TM.insert sessKey v vs
      pure v

removeSessVar :: Ord k => SessionVar a -> k -> TMap k (SessionVar a) -> STM ()
removeSessVar v sessKey vs =
  TM.lookup sessKey vs >>= \case
    Just v' | sessionVarId v == sessionVarId v' -> TM.delete sessKey vs
    _ -> pure ()

-- | Get or create a session var and route to onNew (newly created) or onExisting. The new-var
-- branch is bracketed from the point of creation: if it is interrupted before filling the var
-- (e.g. an async exception during connect), the still-empty var is dropped from the map so the
-- next request creates a fresh session instead of blocking on a var that will never be filled.
-- A thrown ExceptT error is a normal result (the var keeps the error it was filled with) - only
-- an interrupting exception drops the empty var.
withGetSessVar ::
  (Ord k, MonadUnliftIO m) =>
  TVar Int -> k -> TMap k (SessionVar a) -> UTCTime ->
  (SessionVar a -> ExceptT e m b) -> (SessionVar a -> ExceptT e m b) -> ExceptT e m b
withGetSessVar sessSeq sessKey vs ts onNew onExisting =
  ExceptT $ withGetSessVar' sessSeq sessKey vs ts (runExceptT . onNew) (runExceptT . onExisting)

-- | withGetSessVar for actions in the underlying monad (without ExceptT).
withGetSessVar' ::
  (Ord k, MonadUnliftIO m) =>
  TVar Int -> k -> TMap k (SessionVar a) -> UTCTime ->
  (SessionVar a -> m b) -> (SessionVar a -> m b) -> m b
withGetSessVar' sessSeq sessKey vs ts onNew onExisting =
  bracketOnError
    (liftIO $ atomically $ getSessVar sessSeq sessKey vs ts)
    (either (liftIO . atomically . dropEmptySessVar) (\_ -> pure ()))
    (either onNew onExisting)
  where
    dropEmptySessVar v = whenM (isEmptyTMVar $ sessionVar v) $ removeSessVar v sessKey vs

tryReadSessVar :: Ord k => k -> TMap k (SessionVar a) -> STM (Maybe a)
tryReadSessVar sessKey vs = TM.lookup sessKey vs $>>= (tryReadTMVar . sessionVar)
