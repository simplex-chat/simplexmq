{-# LANGUAGE QuasiQuotes #-}

module Simplex.Messaging.Agent.Store.SQLite.Migrations.M20220817_connection_ntfs where

import Database.SQLite.Simple (Query)
import Database.SQLite.Simple.QQ (sql)

m20220817_connection_ntfs :: Query
m20220817_connection_ntfs =
  [sql|
ALTER TABLE connections ADD COLUMN enable_ntfs INTEGER;
|]
