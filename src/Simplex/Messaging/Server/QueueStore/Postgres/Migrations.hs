{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE QuasiQuotes #-}

module Simplex.Messaging.Server.QueueStore.Postgres.Migrations where

import Data.List (sortOn)
import Data.Text (Text)
import qualified Data.Text as T
import Simplex.Messaging.Agent.Store.Postgres.Migrations.Util
import Simplex.Messaging.Agent.Store.Shared
import Text.RawString.QQ (r)

serverSchemaMigrations :: [(String, Text, Maybe Text)]
serverSchemaMigrations =
  [ ("20250207_initial", m20250207_initial, Nothing),
    ("20250319_updated_index", m20250319_updated_index, Just down_m20250319_updated_index),
    ("20250320_short_links", m20250320_short_links, Just down_m20250320_short_links),
    ("20250514_service_certs", m20250514_service_certs, Just down_m20250514_service_certs),
    ("20250903_store_messages", m20250903_store_messages, Just down_m20250903_store_messages),
    ("20250915_queue_ids_hash", m20250915_queue_ids_hash, Just down_m20250915_queue_ids_hash)
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

m20250903_store_messages :: Text
m20250903_store_messages =
  T.pack
    [r|
CREATE TABLE messages(
  message_id BIGINT NOT NULL PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
  recipient_id BYTEA NOT NULL REFERENCES msg_queues ON DELETE CASCADE ON UPDATE RESTRICT,
  msg_id BYTEA NOT NULL,
  msg_ts BIGINT NOT NULL,
  msg_quota BOOLEAN NOT NULL,
  msg_ntf_flag BOOLEAN NOT NULL,
  msg_body BYTEA NOT NULL
);

ALTER TABLE msg_queues
  ADD COLUMN msg_can_write BOOLEAN NOT NULL DEFAULT TRUE,
  ADD COLUMN msg_queue_expire BOOLEAN NOT NULL DEFAULT FALSE,
  ADD COLUMN msg_queue_size BIGINT NOT NULL DEFAULT 0;

CREATE INDEX idx_messages_recipient_id_message_id ON messages (recipient_id, message_id);
CREATE INDEX idx_messages_recipient_id_msg_ts on messages(recipient_id, msg_ts);
CREATE INDEX idx_messages_recipient_id_msg_quota on messages(recipient_id, msg_quota);

DROP INDEX idx_msg_queues_updated_at;
CREATE INDEX idx_msg_queues_updated_at_recipient_id ON msg_queues (deleted_at, updated_at, msg_queue_expire, recipient_id);

CREATE FUNCTION write_message(
  p_recipient_id BYTEA,
  p_msg_id BYTEA,
  p_msg_ts BIGINT,
  p_msg_quota BOOLEAN,
  p_msg_ntf_flag BOOLEAN,
  p_msg_body BYTEA,
  p_quota INT
)
RETURNS TABLE (quota_written BOOLEAN, was_empty BOOLEAN)
LANGUAGE plpgsql AS $$
DECLARE
  q_can_write BOOLEAN;
  q_size BIGINT;
BEGIN
  SELECT msg_can_write, msg_queue_size INTO q_can_write, q_size
  FROM msg_queues
  WHERE recipient_id = p_recipient_id AND deleted_at IS NULL
  FOR UPDATE;

  IF q_can_write OR q_size = 0 THEN
    quota_written := p_msg_quota OR q_size >= p_quota;
    was_empty := q_size = 0;

    INSERT INTO messages(recipient_id, msg_id, msg_ts, msg_quota, msg_ntf_flag, msg_body)
    VALUES (p_recipient_id, p_msg_id, p_msg_ts, quota_written, p_msg_ntf_flag AND NOT quota_written, CASE WHEN quota_written THEN '' :: BYTEA ELSE p_msg_body END);

    UPDATE msg_queues
    SET msg_can_write = NOT quota_written,
        msg_queue_expire = TRUE,
        msg_queue_size = msg_queue_size + 1
    WHERE recipient_id = p_recipient_id;

    RETURN QUERY VALUES (quota_written, was_empty);
  END IF;
END;
$$;

CREATE FUNCTION try_del_msg(p_recipient_id BYTEA, p_msg_id BYTEA)
RETURNS TABLE (r_msg_id BYTEA, r_msg_ts BIGINT, r_msg_quota BOOLEAN, r_msg_ntf_flag BOOLEAN, r_msg_body BYTEA)
LANGUAGE plpgsql AS $$
DECLARE
  q_size BIGINT;
  msg RECORD;
BEGIN
  SELECT msg_queue_size INTO q_size
  FROM msg_queues
  WHERE recipient_id = p_recipient_id AND deleted_at IS NULL
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN;
  END IF;

  SELECT message_id, msg_id, msg_ts, msg_quota, msg_ntf_flag, msg_body
  INTO msg
  FROM messages
  WHERE recipient_id = p_recipient_id
  ORDER BY message_id ASC LIMIT 1;

  IF NOT FOUND THEN
    IF q_size != 0 THEN
      UPDATE msg_queues
      SET msg_can_write = TRUE,
          msg_queue_expire = FALSE,
          msg_queue_size = 0
      WHERE recipient_id = p_recipient_id;
    END IF;
    RETURN;
  END IF;

  IF msg.msg_id = p_msg_id THEN
    DELETE FROM messages WHERE message_id = msg.message_id;
    IF FOUND THEN
      UPDATE msg_queues
      SET msg_can_write = msg_can_write OR msg_queue_size <= 1,
          msg_queue_expire = msg_queue_size > 1,
          msg_queue_size = GREATEST(msg_queue_size - 1, 0)
      WHERE recipient_id = p_recipient_id;
      RETURN QUERY VALUES (msg.msg_id, msg.msg_ts, msg.msg_quota, msg.msg_ntf_flag, msg.msg_body);
    END IF;
  END IF;
END;
$$;

CREATE FUNCTION try_del_peek_msg(p_recipient_id BYTEA, p_msg_id BYTEA)
RETURNS TABLE (r_msg_id BYTEA, r_msg_ts BIGINT, r_msg_quota BOOLEAN, r_msg_ntf_flag BOOLEAN, r_msg_body BYTEA)
LANGUAGE plpgsql AS $$
DECLARE
  q_size BIGINT;
  msg RECORD;
  msg_deleted BOOLEAN;
BEGIN
  SELECT msg_queue_size INTO q_size
  FROM msg_queues
  WHERE recipient_id = p_recipient_id AND deleted_at IS NULL
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN;
  END IF;

  SELECT message_id, msg_id, msg_ts, msg_quota, msg_ntf_flag, msg_body
  INTO msg
  FROM messages
  WHERE recipient_id = p_recipient_id
  ORDER BY message_id ASC LIMIT 1;

  IF NOT FOUND THEN
    IF q_size != 0 THEN
      UPDATE msg_queues
      SET msg_can_write = TRUE,
          msg_queue_expire = FALSE,
          msg_queue_size = 0
      WHERE recipient_id = p_recipient_id;
    END IF;
    RETURN;
  END IF;

  IF msg.msg_id = p_msg_id THEN
    DELETE FROM messages WHERE message_id = msg.message_id;

    msg_deleted := FOUND;
    IF msg_deleted THEN
      RETURN QUERY VALUES (msg.msg_id, msg.msg_ts, msg.msg_quota, msg.msg_ntf_flag, msg.msg_body);
    END IF;

    SELECT msg_id, msg_ts, msg_quota, msg_ntf_flag, msg_body
    INTO msg
    FROM messages
    WHERE recipient_id = p_recipient_id
    ORDER BY message_id ASC LIMIT 1;

    IF FOUND THEN
      RETURN QUERY VALUES (msg.msg_id, msg.msg_ts, msg.msg_quota, msg.msg_ntf_flag, msg.msg_body);
      IF msg_deleted THEN
        UPDATE msg_queues
        SET msg_can_write = msg_can_write OR msg_queue_size <= 1,
            msg_queue_expire = msg_queue_size > 1,
            msg_queue_size = GREATEST(msg_queue_size - 1, 0)
        WHERE recipient_id = p_recipient_id;
      END IF;
    ELSIF msg_deleted OR q_size != 0 THEN
      UPDATE msg_queues
      SET msg_can_write = TRUE,
          msg_queue_expire = FALSE,
          msg_queue_size = 0
      WHERE recipient_id = p_recipient_id;
    END IF;
  ELSE
    RETURN QUERY VALUES (msg.msg_id, msg.msg_ts, msg.msg_quota, msg.msg_ntf_flag, msg.msg_body);
  END IF;
END;
$$;

CREATE FUNCTION delete_expired_msgs(p_recipient_id BYTEA, p_old_ts BIGINT) RETURNS BIGINT
LANGUAGE plpgsql AS $$
DECLARE
  q_size BIGINT;
  keep_min_id BIGINT;
  del_count BIGINT;
BEGIN
  SELECT msg_queue_size INTO q_size
  FROM msg_queues
  WHERE recipient_id = p_recipient_id AND deleted_at IS NULL
  FOR UPDATE SKIP LOCKED;

  IF NOT FOUND OR q_size = 0 THEN
    RETURN 0;
  END IF;

  SELECT MIN(message_id) INTO keep_min_id
  FROM messages WHERE recipient_id = p_recipient_id AND msg_ts >= p_old_ts AND msg_quota = FALSE;

  IF keep_min_id IS NULL THEN
    DELETE FROM messages WHERE recipient_id = p_recipient_id AND msg_quota = FALSE;
  ELSE
    DELETE FROM messages WHERE recipient_id = p_recipient_id AND message_id < keep_min_id AND msg_quota = FALSE;
  END IF;

  GET DIAGNOSTICS del_count = ROW_COUNT;
  IF del_count > 0 THEN
    UPDATE msg_queues
    SET msg_can_write = msg_can_write OR msg_queue_size <= del_count,
        msg_queue_expire = msg_queue_size > del_count AND keep_min_id IS NOT NULL,
        msg_queue_size = GREATEST(msg_queue_size - del_count, 0)
    WHERE recipient_id = p_recipient_id;
  END IF;
  RETURN del_count;
END;
$$;

CREATE PROCEDURE expire_old_messages(
  p_old_queue BIGINT,
  p_old_ts BIGINT,
  batch_size INT,
  OUT r_expired_msgs_count BIGINT,
  OUT r_stored_msgs_count BIGINT,
  OUT r_stored_queues BIGINT
)
LANGUAGE plpgsql AS $$
DECLARE
  rids BYTEA[];
  rid BYTEA;
  last_rid BYTEA := '\x';
  del_count BIGINT;
  total_deleted BIGINT := 0;
BEGIN
  LOOP
    SELECT array_agg(recipient_id)
    INTO rids
    FROM (
      SELECT recipient_id
      FROM msg_queues
      WHERE deleted_at IS NULL
        AND updated_at > p_old_queue
        AND msg_queue_expire = TRUE
        AND recipient_id > last_rid
      ORDER BY recipient_id ASC
      LIMIT batch_size
    ) qs;

    EXIT WHEN rids IS NULL OR cardinality(rids) = 0;

    FOREACH rid IN ARRAY rids
    LOOP
      BEGIN
        del_count := delete_expired_msgs(rid, p_old_ts);
        total_deleted := total_deleted + del_count;
      EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'STORE, expire_old_messages, error expiring queue %: %', encode(rid, 'base64'), SQLERRM;
        CONTINUE;
      END;
      COMMIT;
    END LOOP;
    last_rid := rids[cardinality(rids)];
  END LOOP;

  r_expired_msgs_count := total_deleted;
  r_stored_msgs_count := (SELECT COUNT(1) FROM messages);
  r_stored_queues := (SELECT COUNT(1) FROM msg_queues WHERE deleted_at IS NULL);
END;
$$;
    |]

down_m20250903_store_messages :: Text
down_m20250903_store_messages =
  T.pack
    [r|
DROP FUNCTION write_message;
DROP FUNCTION try_del_msg;
DROP FUNCTION try_del_peek_msg;
DROP FUNCTION delete_expired_msgs;
DROP PROCEDURE expire_old_messages;

DROP INDEX idx_msg_queues_updated_at_recipient_id;
CREATE INDEX idx_msg_queues_updated_at ON msg_queues (deleted_at, updated_at);

DROP INDEX idx_messages_recipient_id_message_id;
DROP INDEX idx_messages_recipient_id_msg_ts;
DROP INDEX idx_messages_recipient_id_msg_quota;

ALTER TABLE msg_queues
  DROP COLUMN msg_can_write,
  DROP COLUMN msg_queue_expire,
  DROP COLUMN msg_queue_size;

DROP TABLE messages;
    |]

m20250915_queue_ids_hash :: Text
m20250915_queue_ids_hash =
  createXorHashFuncs
    <> T.pack
      [r|
ALTER TABLE services
  ADD COLUMN queue_count BIGINT NOT NULL DEFAULT 0,
  ADD COLUMN queue_ids_hash BYTEA NOT NULL DEFAULT '\x00000000000000000000000000000000';

CREATE FUNCTION update_all_aggregates() RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
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
END;
$$;

SELECT update_all_aggregates();

CREATE FUNCTION update_aggregates(p_service_id BYTEA, p_role TEXT, p_queue_id BYTEA, p_change BIGINT) RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
  UPDATE services
  SET queue_count = queue_count + p_change,
      queue_ids_hash = xor_combine(queue_ids_hash, public.digest(p_queue_id, 'md5'))
  WHERE service_id = p_service_id AND service_role = p_role;
END;
$$;

CREATE FUNCTION on_queue_insert() RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.rcv_service_id IS NOT NULL THEN
    PERFORM update_aggregates(NEW.rcv_service_id, 'M', NEW.recipient_id, 1);
  END IF;
  IF NEW.ntf_service_id IS NOT NULL AND NEW.notifier_id IS NOT NULL THEN
    PERFORM update_aggregates(NEW.ntf_service_id, 'N', NEW.notifier_id, 1);
  END IF;
  RETURN NEW;
END;
$$;

CREATE FUNCTION on_queue_delete() RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF OLD.deleted_at IS NULL THEN
    IF OLD.rcv_service_id IS NOT NULL THEN
      PERFORM update_aggregates(OLD.rcv_service_id, 'M', OLD.recipient_id, -1);
    END IF;
    IF OLD.ntf_service_id IS NOT NULL AND OLD.notifier_id IS NOT NULL THEN
      PERFORM update_aggregates(OLD.ntf_service_id, 'N', OLD.notifier_id, -1);
    END IF;
  END IF;
  RETURN OLD;
END;
$$;

CREATE FUNCTION on_queue_update() RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF OLD.deleted_at IS NULL AND OLD.rcv_service_id IS NOT NULL THEN
    IF NOT (NEW.deleted_at IS NULL AND NEW.rcv_service_id IS NOT NULL) THEN
      PERFORM update_aggregates(OLD.rcv_service_id, 'M', OLD.recipient_id, -1);
    ELSIF OLD.rcv_service_id IS DISTINCT FROM NEW.rcv_service_id THEN
      PERFORM update_aggregates(OLD.rcv_service_id, 'M', OLD.recipient_id, -1);
      PERFORM update_aggregates(NEW.rcv_service_id, 'M', NEW.recipient_id, 1);
    END IF;
  ELSIF NEW.deleted_at IS NULL AND NEW.rcv_service_id IS NOT NULL THEN
    PERFORM update_aggregates(NEW.rcv_service_id, 'M', NEW.recipient_id, 1);
  END IF;

  IF OLD.deleted_at IS NULL AND OLD.ntf_service_id IS NOT NULL AND OLD.notifier_id IS NOT NULL THEN
    IF NOT (NEW.deleted_at IS NULL AND NEW.ntf_service_id IS NOT NULL AND NEW.notifier_id IS NOT NULL) THEN
      PERFORM update_aggregates(OLD.ntf_service_id, 'N', OLD.notifier_id, -1);
    ELSIF OLD.ntf_service_id IS DISTINCT FROM NEW.ntf_service_id OR OLD.notifier_id IS DISTINCT FROM NEW.notifier_id THEN
      PERFORM update_aggregates(OLD.ntf_service_id, 'N', OLD.notifier_id, -1);
      PERFORM update_aggregates(NEW.ntf_service_id, 'N', NEW.notifier_id, 1);
    END IF;
  ELSIF NEW.deleted_at IS NULL AND NEW.ntf_service_id IS NOT NULL AND NEW.notifier_id IS NOT NULL THEN
    PERFORM update_aggregates(NEW.ntf_service_id, 'N', NEW.notifier_id, 1);
  END IF;
  RETURN NEW;
END;
$$;

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

down_m20250915_queue_ids_hash :: Text
down_m20250915_queue_ids_hash =
  T.pack
    [r|
DROP TRIGGER tr_queue_insert ON msg_queues;
DROP TRIGGER tr_queue_delete ON msg_queues;
DROP TRIGGER tr_queue_update ON msg_queues;

DROP FUNCTION on_queue_insert;
DROP FUNCTION on_queue_delete;
DROP FUNCTION on_queue_update;

DROP FUNCTION update_aggregates;

DROP FUNCTION update_all_aggregates;

ALTER TABLE services
  DROP COLUMN queue_count,
  DROP COLUMN queue_ids_hash;
    |]
    <> dropXorHashFuncs
