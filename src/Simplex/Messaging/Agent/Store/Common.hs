{-# LANGUAGE CPP #-}

module Simplex.Messaging.Agent.Store.Common
#if defined(dbPostgres)
  ( module Simplex.Messaging.Agent.Store.Postgres.Common,
  )
  where
import Simplex.Messaging.Agent.Store.Postgres.Common
#else
  ( module Simplex.Messaging.Agent.Store.SQLite.Common,
  )
  where
import Simplex.Messaging.Agent.Store.SQLite.Common
#endif
