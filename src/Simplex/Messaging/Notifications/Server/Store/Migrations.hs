{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE QuasiQuotes #-}

module Simplex.Messaging.Notifications.Server.Store.Migrations where

import Data.List (sortOn)
import Data.Text (Text)
import qualified Data.Text as T
import Simplex.Messaging.Agent.Store.Postgres.Migrations.Util
import Simplex.Messaging.Agent.Store.Shared
import Text.RawString.QQ (r)

ntfServerSchemaMigrations :: [(String, Text, Maybe Text)]
ntfServerSchemaMigrations =
  [ ("20250417_initial", m20250417_initial, Nothing),
    ("20250517_service_cert", m20250517_service_cert, Just down_m20250517_service_cert),
    ("20250830_queue_ids_hash", m20250830_queue_ids_hash, Just down_m20250830_queue_ids_hash)
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
  T.pack
    [r|
ALTER TABLE smp_servers ADD COLUMN ntf_service_id BYTEA;

ALTER TABLE subscriptions ADD COLUMN ntf_service_assoc BOOLEAN NOT NULL DEFAULT FALSE;

DROP INDEX idx_subscriptions_smp_server_id_status;
CREATE INDEX idx_subscriptions_smp_server_id_ntf_service_status ON subscriptions(smp_server_id, ntf_service_assoc, status);
    |]

down_m20250517_service_cert :: Text
down_m20250517_service_cert =
  T.pack
    [r|
DROP INDEX idx_subscriptions_smp_server_id_ntf_service_status;
CREATE INDEX idx_subscriptions_smp_server_id_status ON subscriptions(smp_server_id, status);

ALTER TABLE smp_servers DROP COLUMN ntf_service_id;

ALTER TABLE subscriptions DROP COLUMN ntf_service_assoc;
    |]

m20250830_queue_ids_hash :: Text
m20250830_queue_ids_hash =
  createXorHashFuncs
    <> T.pack
      [r|
ALTER TABLE smp_servers
  ADD COLUMN smp_notifier_count BIGINT NOT NULL DEFAULT 0,
  ADD COLUMN smp_notifier_ids_hash BYTEA NOT NULL DEFAULT '\x00000000000000000000000000000000';

CREATE FUNCTION should_subscribe_status(p_status TEXT) RETURNS BOOLEAN
LANGUAGE plpgsql IMMUTABLE STRICT
AS $$
BEGIN
  RETURN p_status IN ('NEW', 'PENDING', 'ACTIVE', 'INACTIVE');
END;
$$;

CREATE FUNCTION update_all_aggregates() RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
  WITH acc AS (
    SELECT
      s.smp_server_id,
      count(smp_notifier_id) as notifier_count,
      xor_aggregate(public.digest(s.smp_notifier_id, 'md5')) AS notifier_hash
    FROM subscriptions s
    WHERE s.ntf_service_assoc = true AND should_subscribe_status(s.status)
    GROUP BY s.smp_server_id
  )
  UPDATE smp_servers srv
  SET smp_notifier_count = COALESCE(acc.notifier_count, 0),
      smp_notifier_ids_hash = COALESCE(acc.notifier_hash, '\x00000000000000000000000000000000')
  FROM acc
  WHERE srv.smp_server_id = acc.smp_server_id;
END;
$$;

SELECT update_all_aggregates();

CREATE FUNCTION update_aggregates(p_server_id BIGINT, p_change BIGINT, p_notifier_id BYTEA) RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
  UPDATE smp_servers
  SET smp_notifier_count = smp_notifier_count + p_change,
      smp_notifier_ids_hash = xor_combine(smp_notifier_ids_hash, public.digest(p_notifier_id, 'md5'))
  WHERE smp_server_id = p_server_id;
END;
$$;

CREATE FUNCTION on_subscription_insert() RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.ntf_service_assoc = true AND should_subscribe_status(NEW.status) THEN
    PERFORM update_aggregates(NEW.smp_server_id, 1, NEW.smp_notifier_id);
  END IF;
  RETURN NEW;
END;
$$;

CREATE FUNCTION on_subscription_delete() RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF OLD.ntf_service_assoc = true AND should_subscribe_status(OLD.status) THEN
    PERFORM update_aggregates(OLD.smp_server_id, -1, OLD.smp_notifier_id);
  END IF;
  RETURN OLD;
END;
$$;

CREATE FUNCTION on_subscription_update() RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF OLD.ntf_service_assoc = true AND should_subscribe_status(OLD.status) THEN
    IF NOT (NEW.ntf_service_assoc = true AND should_subscribe_status(NEW.status)) THEN
      PERFORM update_aggregates(OLD.smp_server_id, -1, OLD.smp_notifier_id);
    END IF;
  ELSIF NEW.ntf_service_assoc = true AND should_subscribe_status(NEW.status) THEN
    PERFORM update_aggregates(NEW.smp_server_id, 1, NEW.smp_notifier_id);
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER tr_subscriptions_insert
AFTER INSERT ON subscriptions
FOR EACH ROW EXECUTE PROCEDURE on_subscription_insert();

CREATE TRIGGER tr_subscriptions_delete
AFTER DELETE ON subscriptions
FOR EACH ROW EXECUTE PROCEDURE on_subscription_delete();

CREATE TRIGGER tr_subscriptions_update
AFTER UPDATE ON subscriptions
FOR EACH ROW EXECUTE PROCEDURE on_subscription_update();
      |]

down_m20250830_queue_ids_hash :: Text
down_m20250830_queue_ids_hash =
  T.pack
    [r|
DROP TRIGGER tr_subscriptions_insert ON subscriptions;
DROP TRIGGER tr_subscriptions_delete ON subscriptions;
DROP TRIGGER tr_subscriptions_update ON subscriptions;

DROP FUNCTION on_subscription_insert;
DROP FUNCTION on_subscription_delete;
DROP FUNCTION on_subscription_update;

DROP FUNCTION update_aggregates;
DROP FUNCTION update_all_aggregates;

DROP FUNCTION should_subscribe_status;

ALTER TABLE smp_servers
  DROP COLUMN smp_notifier_count,
  DROP COLUMN smp_notifier_ids_hash;
    |]
    <> dropXorHashFuncs
