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
    ("20260402_file_size_check", m20260402_file_size_check, Just down_m20260402_file_size_check)
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
  file_size INT4 NOT NULL,
  file_digest BYTEA NOT NULL,
  sender_key BYTEA NOT NULL,
  file_path TEXT,
  created_at INT8 NOT NULL,
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

m20260402_file_size_check :: Text
m20260402_file_size_check =
  [r|
ALTER TABLE files ADD CONSTRAINT check_file_size_positive CHECK (file_size > 0);
|]

down_m20260402_file_size_check :: Text
down_m20260402_file_size_check =
  [r|
ALTER TABLE files DROP CONSTRAINT check_file_size_positive;
|]
