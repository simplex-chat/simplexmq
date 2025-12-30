{-# LANGUAGE QuasiQuotes #-}

module Simplex.Messaging.Agent.Store.SQLite.Migrations.M20240930_ntf_tokens_to_delete where

import Database.SQLite.Simple (Query)
import Database.SQLite.Simple.QQ (sql)

m20240930_ntf_tokens_to_delete :: Query
m20240930_ntf_tokens_to_delete =
    [sql|
CREATE TABLE ntf_tokens_to_delete (
  ntf_token_to_delete_id INTEGER PRIMARY KEY,
  ntf_host TEXT NOT NULL,
  ntf_port TEXT NOT NULL,
  ntf_key_hash BLOB NOT NULL,
  tkn_id BLOB NOT NULL, -- token ID assigned by notifications server
  tkn_priv_key BLOB NOT NULL, -- client's private key to sign token commands,
  del_failed INTEGER DEFAULT 0,
  created_at TEXT NOT NULL DEFAULT (datetime('now'))
) STRICT;
|]

down_m20240930_ntf_tokens_to_delete :: Query
down_m20240930_ntf_tokens_to_delete =
    [sql|
DROP TABLE ntf_tokens_to_delete;
|]
