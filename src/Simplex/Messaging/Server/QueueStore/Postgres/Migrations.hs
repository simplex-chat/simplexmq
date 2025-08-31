{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE QuasiQuotes #-}

module Simplex.Messaging.Server.QueueStore.Postgres.Migrations where

import Data.List (sortOn)
import Data.Text (Text)
import qualified Data.Text as T
import Simplex.Messaging.Agent.Store.Shared
import Text.RawString.QQ (r)

serverSchemaMigrations :: [(String, Text, Maybe Text)]
serverSchemaMigrations =
  [ ("20250207_initial", m20250207_initial, Nothing),
    ("20250319_updated_index", m20250319_updated_index, Just down_m20250319_updated_index),
    ("20250320_short_links", m20250320_short_links, Just down_m20250320_short_links),
    ("20250514_service_certs", m20250514_service_certs, Just down_m20250514_service_certs),
    ("20250830_queue_ids_hash", m20250830_queue_ids_hash, Just down_m20250830_queue_ids_hash)
  ]

-- | The list of migrations in ascending order by date
serverMigrations :: [Migration]
serverMigrations = sortOn name $ map migration serverSchemaMigrations
  where
    migration (name, up, down) = Migration {name, up, down = down}

m20250207_initial :: Text
m20250207_initial =
  T.pack
    [r|
CREATE TABLE msg_queues(
  recipient_id BYTEA NOT NULL,
  recipient_key BYTEA NOT NULL,
  rcv_dh_secret BYTEA NOT NULL,
  sender_id BYTEA NOT NULL,
  sender_key BYTEA,
  snd_secure BOOLEAN NOT NULL,
  notifier_id BYTEA,
  notifier_key BYTEA,
  rcv_ntf_dh_secret BYTEA,
  status TEXT NOT NULL,
  updated_at BIGINT,
  deleted_at BIGINT,
  PRIMARY KEY (recipient_id)
);

CREATE UNIQUE INDEX idx_msg_queues_sender_id ON msg_queues(sender_id);
CREATE UNIQUE INDEX idx_msg_queues_notifier_id ON msg_queues(notifier_id);
CREATE INDEX idx_msg_queues_deleted_at ON msg_queues (deleted_at);
    |]

m20250319_updated_index :: Text
m20250319_updated_index =
  T.pack
    [r|
DROP INDEX idx_msg_queues_deleted_at;
CREATE INDEX idx_msg_queues_updated_at ON msg_queues (deleted_at, updated_at);
    |]

down_m20250319_updated_index :: Text
down_m20250319_updated_index =
  T.pack
    [r|
DROP INDEX idx_msg_queues_updated_at;
CREATE INDEX idx_msg_queues_deleted_at ON msg_queues (deleted_at);
    |]

m20250320_short_links :: Text
m20250320_short_links =
  T.pack
    [r|
ALTER TABLE msg_queues
  ADD COLUMN queue_mode TEXT,
  ADD COLUMN link_id BYTEA,
  ADD COLUMN fixed_data BYTEA,
  ADD COLUMN user_data BYTEA;

UPDATE msg_queues SET queue_mode = 'M' WHERE snd_secure IS TRUE;

ALTER TABLE msg_queues DROP COLUMN snd_secure;

UPDATE msg_queues SET recipient_key = ('\x01'::BYTEA || chr(length(recipient_key))::BYTEA || recipient_key);

ALTER TABLE msg_queues RENAME COLUMN recipient_key TO recipient_keys;

CREATE UNIQUE INDEX idx_msg_queues_link_id ON msg_queues(link_id);
    |]

down_m20250320_short_links :: Text
down_m20250320_short_links =
  T.pack
    [r|
ALTER TABLE msg_queues ADD COLUMN snd_secure BOOLEAN NOT NULL DEFAULT FALSE;

UPDATE msg_queues SET snd_secure = TRUE WHERE queue_mode = 'M';

DROP INDEX idx_msg_queues_link_id;

ALTER TABLE msg_queues
  DROP COLUMN queue_mode,
  DROP COLUMN link_id,
  DROP COLUMN fixed_data,
  DROP COLUMN user_data;

DO $$
  DECLARE bad_id BYTEA;
  BEGIN
    SELECT recipient_id INTO bad_id
    FROM msg_queues
    WHERE get_byte(recipient_keys, 0) != 1
      OR get_byte(recipient_keys, 1) != length(recipient_keys) - 2
    LIMIT 1;

    IF bad_id IS NOT NULL
    THEN RAISE EXCEPTION 'Cannot downgrade: many keys or incorrect length in recipient_keys for %', encode(bad_id, 'base64');
    END IF;
  END;
$$;

UPDATE msg_queues SET recipient_keys = substring(recipient_keys from 3);

ALTER TABLE msg_queues RENAME COLUMN recipient_keys TO recipient_key;
    |]

m20250514_service_certs :: Text
m20250514_service_certs =
  T.pack
    [r|
CREATE TABLE services(
  service_id BYTEA NOT NULL,
  service_role TEXT NOT NULL,
  service_cert BYTEA NOT NULL,
  service_cert_hash BYTEA NOT NULL UNIQUE,
  created_at BIGINT NOT NULL,
  PRIMARY KEY (service_id)
);

CREATE INDEX idx_services_service_role ON services(service_role);

ALTER TABLE msg_queues
  ADD COLUMN rcv_service_id BYTEA REFERENCES services(service_id) ON DELETE SET NULL ON UPDATE RESTRICT,
  ADD COLUMN ntf_service_id BYTEA REFERENCES services(service_id) ON DELETE SET NULL ON UPDATE RESTRICT;

CREATE INDEX idx_msg_queues_rcv_service_id ON msg_queues(rcv_service_id, deleted_at);
CREATE INDEX idx_msg_queues_ntf_service_id ON msg_queues(ntf_service_id, deleted_at);
    |]

down_m20250514_service_certs :: Text
down_m20250514_service_certs =
  T.pack
    [r|
DROP INDEX idx_msg_queues_rcv_service_id;
DROP INDEX idx_msg_queues_ntf_service_id;

ALTER TABLE msg_queues
  DROP COLUMN rcv_service_id,
  DROP COLUMN ntf_service_id;

DROP INDEX idx_services_service_role;

DROP TABLE services;
    |]

m20250830_queue_ids_hash :: Text
m20250830_queue_ids_hash =
  createXorHashFuncs
    <> T.pack
      [r|
ALTER TABLE services
  ADD COLUMN queue_count BIGINT NOT NULL DEFAULT 0,
  ADD COLUMN queue_ids_hash BYTEA NOT NULL DEFAULT '\x00000000000000000000000000000000';

WITH acc AS (
  SELECT
    s.service_id,
    count(1) as q_count,
    xor_aggregate(public.digest(CASE WHEN s.service_role = 'M' THEN q.recipient_id ELSE COALESCE(q.notifier_id, '\x00000000000000000000000000000000') END, 'md5')) AS q_ids_hash
  FROM services s
  JOIN msg_queues q ON (s.service_id = q.rcv_service_id AND s.service_role = 'M') OR (s.service_id = q.ntf_service_id AND s.service_role = 'N')
  WHERE q.deleted_at IS NULL
  GROUP BY s.service_id
)
UPDATE services s
SET queue_count = COALESCE(acc.q_count, 0),
    queue_ids_hash = COALESCE(acc.q_ids_hash, '\x00000000000000000000000000000000')
FROM acc
WHERE s.service_id = acc.service_id;

CREATE OR REPLACE FUNCTION update_ids_hash(p_service_id BYTEA, p_role TEXT, p_queue_id BYTEA, p_change BIGINT) RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  UPDATE services
  SET queue_count = queue_count + p_change,
      queue_ids_hash = xor_combine(queue_ids_hash, public.digest(p_queue_id, 'md5'))
  WHERE service_id = p_service_id AND service_role = p_role;
END;
$$;

CREATE OR REPLACE FUNCTION on_queue_insert() RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.rcv_service_id IS NOT NULL THEN
    PERFORM update_ids_hash(NEW.rcv_service_id, 'M', NEW.recipient_id, 1);
  END IF;
  IF NEW.ntf_service_id IS NOT NULL AND NEW.notifier_id IS NOT NULL THEN
    PERFORM update_ids_hash(NEW.ntf_service_id, 'N', NEW.notifier_id, 1);
  END IF;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION on_queue_delete() RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF OLD.deleted_at IS NULL THEN
    IF OLD.rcv_service_id IS NOT NULL THEN
      PERFORM update_ids_hash(OLD.rcv_service_id, 'M', OLD.recipient_id, -1);
    END IF;
    IF OLD.ntf_service_id IS NOT NULL AND OLD.notifier_id IS NOT NULL THEN
      PERFORM update_ids_hash(OLD.ntf_service_id, 'N', OLD.notifier_id, -1);
    END IF;
  END IF;
  RETURN OLD;
END;
$$;

CREATE OR REPLACE FUNCTION on_queue_update() RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF OLD.deleted_at IS NULL AND OLD.rcv_service_id IS NOT NULL THEN
    IF NOT (NEW.deleted_at IS NULL AND NEW.rcv_service_id IS NOT NULL) THEN
      PERFORM update_ids_hash(OLD.rcv_service_id, 'M', OLD.recipient_id, -1);
    ELSIF OLD.rcv_service_id IS DISTINCT FROM NEW.rcv_service_id THEN
      PERFORM update_ids_hash(OLD.rcv_service_id, 'M', OLD.recipient_id, -1);
      PERFORM update_ids_hash(NEW.rcv_service_id, 'M', NEW.recipient_id, 1);
    END IF;
  ELSIF NEW.deleted_at IS NULL AND NEW.rcv_service_id IS NOT NULL THEN
    PERFORM update_ids_hash(NEW.rcv_service_id, 'M', NEW.recipient_id, 1);
  END IF;

  IF OLD.deleted_at IS NULL AND OLD.ntf_service_id IS NOT NULL AND OLD.notifier_id IS NOT NULL THEN
    IF NOT (NEW.deleted_at IS NULL AND NEW.ntf_service_id IS NOT NULL AND NEW.notifier_id IS NOT NULL) THEN
      PERFORM update_ids_hash(OLD.ntf_service_id, 'N', OLD.notifier_id, -1);
    ELSIF OLD.ntf_service_id IS DISTINCT FROM NEW.ntf_service_id OR OLD.notifier_id IS DISTINCT FROM NEW.notifier_id THEN
      PERFORM update_ids_hash(OLD.ntf_service_id, 'N', OLD.notifier_id, -1);
      PERFORM update_ids_hash(NEW.ntf_service_id, 'N', NEW.notifier_id, 1);
    END IF;
  ELSIF NEW.deleted_at IS NULL AND NEW.ntf_service_id IS NOT NULL AND NEW.notifier_id IS NOT NULL THEN
    PERFORM update_ids_hash(NEW.ntf_service_id, 'N', NEW.notifier_id, 1);
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS tr_queue_insert ON msg_queues;
DROP TRIGGER IF EXISTS tr_queue_delete ON msg_queues;
DROP TRIGGER IF EXISTS tr_queue_update ON msg_queues;

CREATE TRIGGER tr_queue_insert
AFTER INSERT ON msg_queues
FOR EACH ROW EXECUTE PROCEDURE on_queue_insert();

CREATE TRIGGER tr_queue_delete
AFTER DELETE ON msg_queues
FOR EACH ROW EXECUTE PROCEDURE on_queue_delete();

CREATE TRIGGER tr_queue_update
AFTER UPDATE ON msg_queues
FOR EACH ROW EXECUTE PROCEDURE on_queue_update();
      |]

down_m20250830_queue_ids_hash :: Text
down_m20250830_queue_ids_hash =
  T.pack
    [r|
DROP TRIGGER tr_queue_insert ON msg_queues;
DROP TRIGGER tr_queue_delete ON msg_queues;
DROP TRIGGER tr_queue_update ON msg_queues;

DROP FUNCTION on_queue_insert;
DROP FUNCTION on_queue_delete;
DROP FUNCTION on_queue_update;

DROP FUNCTION update_ids_hash;

ALTER TABLE services
  DROP COLUMN queue_count,
  DROP COLUMN queue_ids_hash;
    |]
    <> dropXorHashFuncs

createXorHashFuncs :: Text
createXorHashFuncs =
  T.pack
    [r|
CREATE OR REPLACE FUNCTION xor_combine(state BYTEA, value BYTEA) RETURNS BYTEA
LANGUAGE plpgsql IMMUTABLE STRICT
AS $$
DECLARE
  result BYTEA := state;
  i INTEGER;
  len INTEGER := octet_length(value);
BEGIN
  IF octet_length(state) != len THEN
    RAISE EXCEPTION 'Inputs must be equal length (% != %)', octet_length(state), len;
  END IF;
  FOR i IN 0..len-1 LOOP
    result := set_byte(result, i, get_byte(state, i) # get_byte(value, i));
  END LOOP;
  RETURN result;
END;
$$;

CREATE OR REPLACE AGGREGATE xor_aggregate(BYTEA) (
  SFUNC = xor_combine,
  STYPE = BYTEA,
  INITCOND = '\x00000000000000000000000000000000' -- 16 bytes
);
    |]

dropXorHashFuncs :: Text
dropXorHashFuncs =
  T.pack
    [r|
DROP AGGREGATE xor_aggregate(BYTEA);
DROP FUNCTION xor_combine;
    |]
