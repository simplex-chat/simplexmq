{-# LANGUAGE CPP #-}

module Simplex.Messaging.Agent.Store.Interface
#if defined(dbPostgres)
  ( module Simplex.Messaging.Agent.Store.Postgres,
  )
  where
import Simplex.Messaging.Agent.Store.Postgres
#else
  ( module Simplex.Messaging.Agent.Store.SQLite,
  )
  where
import Simplex.Messaging.Agent.Store.SQLite
#endif
