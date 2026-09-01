{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}

module Simplex.FileTransfer.Server.Store.Postgres.Migrations
  ( xftpServerMigrations,
  )
where

import Data.List (sortOn)
import Data.Text (Text)
import Simplex.Messaging.Agent.Store.Shared
import Text.RawString.QQ (r)

xftpSchemaMigrations :: [(String, Text, Maybe Text)]
xftpSchemaMigrations =
  [ ("20260325_initial", m20260325_initial, Nothing),
    ("20260823_file_expiration", m20260823_file_expiration, Just down_m20260823_file_expiration)
  ]

-- | The list of migrations in ascending order by date
xftpServerMigrations :: [Migration]
xftpServerMigrations = sortOn name $ map migration xftpSchemaMigrations
  where
    migration (name, up, down) = Migration {name, up, down = down}

m20260325_initial :: Text
m20260325_initial =
  [r|
CREATE TABLE files (
  sender_id BYTEA NOT NULL PRIMARY KEY,
  file_size INTEGER NOT NULL,
  file_digest BYTEA NOT NULL,
  sender_key BYTEA NOT NULL,
  file_path TEXT,
  created_at BIGINT NOT NULL,
  status TEXT NOT NULL DEFAULT 'active'
);

CREATE TABLE recipients (
  recipient_id BYTEA NOT NULL PRIMARY KEY,
  sender_id BYTEA NOT NULL REFERENCES files ON DELETE CASCADE,
  recipient_key BYTEA NOT NULL
);

CREATE INDEX idx_recipients_sender_id ON recipients (sender_id);
CREATE INDEX idx_files_created_at ON files (created_at);
|]

m20260823_file_expiration :: Text
m20260823_file_expiration =
  [r|
ALTER TABLE files ADD COLUMN expires_at BIGINT;
CREATE INDEX idx_files_expiry ON files (expires_at, created_at);
|]

down_m20260823_file_expiration :: Text
down_m20260823_file_expiration =
  [r|
DROP INDEX idx_files_expiry;
ALTER TABLE files DROP COLUMN expires_at;
|]
