{-# LANGUAGE CPP #-}

module Simplex.Messaging.Agent.Store.Migrations.App
#if defined(dbPostgres)
  ( module Simplex.Messaging.Agent.Store.Postgres.Migrations.App,
  )
  where
import Simplex.Messaging.Agent.Store.Postgres.Migrations.App
#else
  ( module Simplex.Messaging.Agent.Store.SQLite.Migrations.App,
  )
  where
import Simplex.Messaging.Agent.Store.SQLite.Migrations.App
#endif
