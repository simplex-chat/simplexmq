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

PRAGMA writable_schema=1;

UPDATE sqlite_master
SET sql = CASE
  WHEN LOWER(SUBSTR(sql, -15)) = ') without rowid' THEN sql || ', STRICT'
  WHEN SUBSTR(sql, -1) = ')' THEN sql || ' STRICT'
  ELSE sql
END
WHERE type = 'table' AND name != 'sqlite_sequence';

UPDATE sqlite_master
SET sql = replace(sql, 'device_token TEXT NOT NULL', 'device_token BLOB NOT NULL')
WHERE type = 'table' AND name = 'ntf_tokens';

PRAGMA writable_schema=0;
|]

down_m20251230_strict_tables :: Query
down_m20251230_strict_tables =
  [sql|
PRAGMA writable_schema=1;

UPDATE sqlite_master
SET sql = CASE
  WHEN LOWER(SUBSTR(sql, -8)) = ', strict' THEN SUBSTR(sql, 1, LENGTH(sql) - 8)
  WHEN LOWER(SUBSTR(sql, -7)) = ' strict' THEN SUBSTR(sql, 1, LENGTH(sql) - 7)
  ELSE sql
END
WHERE type = 'table' AND name != 'sqlite_sequence';

UPDATE sqlite_master
SET sql = replace(sql, 'device_token BLOB NOT NULL', 'device_token TEXT NOT NULL')
WHERE type = 'table' AND name = 'ntf_tokens';

PRAGMA writable_schema=0;

UPDATE ntf_tokens SET ntf_mode = CAST(ntf_mode as BLOB);

UPDATE ntf_subscriptions
SET ntf_sub_action = CAST(ntf_sub_action as BLOB),
    ntf_sub_smp_action = CAST(ntf_sub_smp_action as BLOB);
|]
