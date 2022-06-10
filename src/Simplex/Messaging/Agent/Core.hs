{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RankNTypes #-}

module Simplex.Messaging.Agent.Core
  ( AgentMonad,
    withStore,
  )
where

import Control.Monad.Except
import Control.Monad.IO.Unlift
import Control.Monad.Reader
import Database.SQLite.Simple (SQLError)
import Simplex.Messaging.Agent.Env.SQLite
import Simplex.Messaging.Agent.Protocol
import Simplex.Messaging.Agent.Store (ConnType (..), StoreError (..))
import Simplex.Messaging.Agent.Store.SQLite (AgentStoreMonad, SQLiteStore)
import Simplex.Messaging.Client.Agent ()
import Simplex.Messaging.Util (bshow)
import qualified UnliftIO.Exception as E

-- | Agent monad with MonadReader Env and MonadError AgentErrorType
type AgentMonad m = (MonadUnliftIO m, MonadReader Env m, MonadError AgentErrorType m)

withStore :: AgentMonad m => (forall m'. AgentStoreMonad m' => SQLiteStore -> m' a) -> m a
withStore action = do
  st <- asks store
  runExceptT (action st `E.catch` handleInternal) >>= \case
    Right c -> return c
    Left e -> throwError $ storeError e
  where
    -- TODO when parsing exception happens in store, the agent hangs;
    -- changing SQLError to SomeException does not help
    handleInternal :: (MonadError StoreError m') => SQLError -> m' a
    handleInternal e = throwError . SEInternal $ bshow e
    storeError :: StoreError -> AgentErrorType
    storeError = \case
      SEConnNotFound -> CONN NOT_FOUND
      SEConnDuplicate -> CONN DUPLICATE
      SEBadConnType CRcv -> CONN SIMPLEX
      SEBadConnType CSnd -> CONN SIMPLEX
      SEInvitationNotFound -> CMD PROHIBITED
      -- this error is never reported as store error,
      -- it is used to wrap agent operations when "transaction-like" store access is needed
      -- NOTE: network IO should NOT be used inside AgentStoreMonad
      SEAgentError e -> e
      e -> INTERNAL $ show e
