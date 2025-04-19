{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE QuasiQuotes #-}

module Simplex.Messaging.Notifications.Server.Store.Migrations where

import Data.List (sortOn)
import Data.Text (Text)
import qualified Data.Text as T
import Simplex.Messaging.Agent.Store.Shared
import Text.RawString.QQ (r)

ntfServerSchemaMigrations :: [(String, Text, Maybe Text)]
ntfServerSchemaMigrations =
  [ ("20250417_initial", m20250417_initial, Nothing)
  ]

-- | The list of migrations in ascending order by date
ntfServerMigrations :: [Migration]
ntfServerMigrations = sortOn name $ map migration ntfServerSchemaMigrations
  where
    migration (name, up, down) = Migration {name, up, down = down}

m20250417_initial :: Text
m20250417_initial =
  T.pack
    [r|
CREATE TABLE tokens(
  token_id BYTEA NOT NULL,
  push_provider TEXT NOT NULL,
  push_provider_token BYTEA NOT NULL,
  status BYTEA NOT NULL,
  verify_key BYTEA NOT NULL,
  dh_priv_key BYTEA NOT NULL,
  dh_secret BYTEA NOT NULL,
  reg_code BYTEA NOT NULL,
  cron_interval BIGINT NOT NULL,
  cron_sent_at BIGINT,
  updated_at BIGINT NOT NULL,
  PRIMARY KEY (token_id)
);

CREATE UNIQUE INDEX idx_tokens_push_provider_token ON tokens(push_provider, push_provider_token, verify_key);
CREATE INDEX idx_tokens_cron_sent_at ON tokens((cron_sent_at + cron_interval));

CREATE TABLE smp_servers(
  smp_server_id BIGINT PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
  smp_host TEXT NOT NULL,
  smp_port TEXT NOT NULL,
  smp_keyhash BYTEA NOT NULL
);

CREATE UNIQUE INDEX idx_smp_servers ON smp_servers(smp_host, smp_port, smp_keyhash);

CREATE TABLE subscriptions(
  subscription_id BYTEA NOT NULL,
  token_id BYTEA NOT NULL REFERENCES tokens ON DELETE CASCADE ON UPDATE RESTRICT,
  smp_server_id BIGINT REFERENCES smp_servers ON DELETE RESTRICT ON UPDATE RESTRICT,
  smp_notifier_id BYTEA NOT NULL,
  smp_notifier_key BYTEA NOT NULL,
  status BYTEA NOT NULL,
  PRIMARY KEY (subscription_id)
);

CREATE UNIQUE INDEX idx_subscriptions_smp_notifier ON subscriptions(smp_server_id, smp_notifier_id);
CREATE INDEX idx_subscriptions_token_id ON subscriptions(token_id);

CREATE TABLE last_notifications(
  token_ntf_id BIGINT PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
  token_id BYTEA NOT NULL REFERENCES tokens ON DELETE CASCADE ON UPDATE RESTRICT,
  subscription_id BYTEA NOT NULL REFERENCES subscriptions ON DELETE CASCADE ON UPDATE RESTRICT,
  sent_at BIGINT NOT NULL,
  nmsg_nonce BYTEA NOT NULL,
  nmsg_data BYTEA NOT NULL
);

CREATE INDEX idx_last_notifications_token_id ON last_notifications(token_id);
CREATE INDEX idx_last_notifications_subscription_id ON last_notifications(subscription_id);

CREATE UNIQUE INDEX idx_last_notifications_token_subscription ON last_notifications(token_id, subscription_id);
    |]
