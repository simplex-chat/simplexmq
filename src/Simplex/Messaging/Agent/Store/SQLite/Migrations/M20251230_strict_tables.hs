{-# LANGUAGE QuasiQuotes #-}

module Simplex.Messaging.Agent.Store.SQLite.Migrations.M20251230_strict_tables where

import Database.SQLite.Simple (Query)
import Database.SQLite.Simple.QQ (sql)

m20251230_strict_tables :: Query
m20251230_strict_tables =
  [sql|
UPDATE ntf_tokens SET ntf_mode = CAST(ntf_mode as TEXT);

UPDATE ntf_subscriptions
SET ntf_sub_action = CAST(ntf_sub_action as TEXT),
    ntf_sub_smp_action = CAST(ntf_sub_smp_action as TEXT);
|]

down_m20251230_strict_tables :: Query
down_m20251230_strict_tables =
  [sql|
UPDATE ntf_tokens SET ntf_mode = CAST(ntf_mode as BLOB);

UPDATE ntf_subscriptions
SET ntf_sub_action = CAST(ntf_sub_action as BLOB),
    ntf_sub_smp_action = CAST(ntf_sub_smp_action as BLOB);
|]
