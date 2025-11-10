{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}

module Simplex.Messaging.Notifications.Server.Store.Migrations where

import Data.List (sortOn)
import Data.Text (Text)
import Simplex.Messaging.Agent.Store.Shared
import Text.RawString.QQ (r)

ntfServerSchemaMigrations :: [(String, Text, Maybe Text)]
ntfServerSchemaMigrations =
  [ ("20250417_initial", m20250417_initial, Nothing),
    ("20250517_service_cert", m20250517_service_cert, Just down_m20250517_service_cert),
    ("20250916_webpush", m20250916_webpush, Just down_m20250916_webpush)
  ]

-- | The list of migrations in ascending order by date
ntfServerMigrations :: [Migration]
ntfServerMigrations = sortOn name $ map migration ntfServerSchemaMigrations
  where
    migration (name, up, down) = Migration {name, up, down = down}

m20250417_initial :: Text
m20250417_initial =
  [r|
CREATE TABLE tokens(
  token_id BYTEA NOT NULL,
  push_provider TEXT NOT NULL,
  push_provider_token BYTEA NOT NULL,
  status TEXT NOT NULL,
  verify_key BYTEA NOT NULL,
  dh_priv_key BYTEA NOT NULL,
  dh_secret BYTEA NOT NULL,
  reg_code BYTEA NOT NULL,
  cron_interval BIGINT NOT NULL, -- minutes
  cron_sent_at BIGINT, -- seconds
  updated_at BIGINT,
  PRIMARY KEY (token_id)
);

CREATE UNIQUE INDEX idx_tokens_push_provider_token ON tokens(push_provider, push_provider_token, verify_key);
CREATE INDEX idx_tokens_status_cron_interval_sent_at ON tokens(status, cron_interval, (cron_sent_at + cron_interval * 60));

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
  status TEXT NOT NULL,
  PRIMARY KEY (subscription_id)
);

CREATE UNIQUE INDEX idx_subscriptions_smp_server_id_notifier_id ON subscriptions(smp_server_id, smp_notifier_id);
CREATE INDEX idx_subscriptions_smp_server_id_status ON subscriptions(smp_server_id, status);
CREATE INDEX idx_subscriptions_token_id ON subscriptions(token_id);

CREATE TABLE last_notifications(
  token_ntf_id BIGINT PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
  token_id BYTEA NOT NULL REFERENCES tokens ON DELETE CASCADE ON UPDATE RESTRICT,
  subscription_id BYTEA NOT NULL REFERENCES subscriptions ON DELETE CASCADE ON UPDATE RESTRICT,
  sent_at TIMESTAMPTZ NOT NULL,
  nmsg_nonce BYTEA NOT NULL,
  nmsg_data BYTEA NOT NULL
);

CREATE INDEX idx_last_notifications_token_id_sent_at ON last_notifications(token_id, sent_at);
CREATE INDEX idx_last_notifications_subscription_id ON last_notifications(subscription_id);

CREATE UNIQUE INDEX idx_last_notifications_token_subscription ON last_notifications(token_id, subscription_id);
    |]

m20250517_service_cert :: Text
m20250517_service_cert =
  [r|
ALTER TABLE smp_servers ADD COLUMN ntf_service_id BYTEA;

ALTER TABLE subscriptions ADD COLUMN ntf_service_assoc BOOLEAN NOT NULL DEFAULT FALSE;

DROP INDEX idx_subscriptions_smp_server_id_status;
CREATE INDEX idx_subscriptions_smp_server_id_ntf_service_status ON subscriptions(smp_server_id, ntf_service_assoc, status);
    |]

down_m20250517_service_cert :: Text
down_m20250517_service_cert =
  [r|
DROP INDEX idx_subscriptions_smp_server_id_ntf_service_status;
CREATE INDEX idx_subscriptions_smp_server_id_status ON subscriptions(smp_server_id, status);

ALTER TABLE smp_servers DROP COLUMN ntf_service_id;

ALTER TABLE subscriptions DROP COLUMN ntf_service_assoc;
    |]

m20250916_webpush :: Text
m20250916_webpush =
  T.pack
    [r|
CREATE TABLE webpush_servers(
  wp_server_id BIGINT PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
  wp_host TEXT NOT NULL,
  wp_port TEXT NOT NULL,
  wp_keyhash BYTEA NOT NULL
);

ALTER TABLE tokens
  ADD COLUMN wp_server_id BIGINT REFERENCES webpush_servers ON DELETE RESTRICT ON UPDATE RESTRICT,
  ADD COLUMN wp_path TEXT,
  ADD COLUMN wp_auth BYTEA,
  ADD COLUMN wp_key BYTEA;
    |]

down_m20250916_webpush :: Text
down_m20250916_webpush =
  T.pack
    [r|
ALTER TABLE tokens
  DROP COLUMN wp_server_id,
  DROP COLUMN wp_path,
  DROP COLUMN wp_auth,
  DROP COLUMN wp_key;

DROP TABLE webpush_servers;
    |]
