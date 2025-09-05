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
    ("20250903_store_messages", m20250903_store_messages, Just down_m20250903_store_messages)
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
  ADD COLUMN msg_can_write BOOLEAN NOT NULL DEFAULT true,
  ADD COLUMN msg_queue_size BIGINT NOT NULL DEFAULT 0;

CREATE INDEX idx_messages_recipient_id_message_id ON messages (recipient_id, message_id);
CREATE INDEX idx_messages_recipient_id_msg_ts on messages(recipient_id, msg_ts);
CREATE INDEX idx_messages_recipient_id_msg_quota on messages(recipient_id, msg_quota);

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
AS $$
DECLARE
  q_can_write BOOLEAN;
  q_size INT;
BEGIN
  SELECT msg_can_write, msg_queue_size INTO q_can_write, q_size
  FROM msg_queues
  WHERE recipient_id = p_recipient_id AND deleted_at IS NULL
  FOR UPDATE;

  IF q_can_write OR q_size = 0 THEN
    quota_written := p_msg_quota OR q_size >= p_quota;
    was_empty := q_size = 0;

    INSERT INTO messages(recipient_id, msg_id, msg_ts, msg_quota, msg_ntf_flag, msg_body)
    VALUES (p_recipient_id, p_msg_id, p_msg_ts, quota_written, NOT quota_written AND p_msg_ntf_flag, CASE WHEN quota_written THEN '' :: BYTEA ELSE p_msg_body END);

    UPDATE msg_queues
    SET msg_can_write = NOT quota_written,
        msg_queue_size = msg_queue_size + 1
    WHERE recipient_id = p_recipient_id;

    RETURN NEXT;
  END IF;

  RETURN;
END;
$$ LANGUAGE plpgsql;

CREATE PROCEDURE expire_old_messages(
  p_now_ts BIGINT,
  p_ttl BIGINT,
  OUT r_expired_msgs_count BIGINT,
  OUT r_stored_msgs_count BIGINT,
  OUT r_stored_queues BIGINT
)
AS $$
  DECLARE
    old_ts BIGINT := p_now_ts - p_ttl;
    very_old_ts BIGINT := p_now_ts - 2 * p_ttl - 86400;
    rid BYTEA;
    min_id BIGINT;
    q_size BIGINT;
    del_count BIGINT;
    total_deleted BIGINT := 0;
  BEGIN
    FOR rid IN
      SELECT recipient_id
      FROM msg_queues
      WHERE deleted_at IS NULL AND updated_at > very_old_ts
    LOOP
      BEGIN -- sub-transaction for each queue
        SELECT msg_queue_size INTO q_size
        FROM msg_queues
        WHERE recipient_id = rid AND deleted_at IS NULL
        FOR UPDATE SKIP LOCKED;

        IF NOT FOUND THEN
          RAISE WARNING 'STORE, expire_old_messages, skipping locked or deleted queue %', encode(rid, 'base64');
          CONTINUE;
        ELSIF q_size = 0 THEN
          CONTINUE;
        END IF;

        SELECT LEAST( -- ignores NULLs
          (SELECT MIN(message_id) FROM messages WHERE recipient_id = rid AND msg_ts >= old_ts),
          (SELECT MIN(message_id) FROM messages WHERE recipient_id = rid AND msg_quota = TRUE)
        ) INTO min_id;

        IF min_id IS NULL THEN
          DELETE FROM messages WHERE recipient_id = rid;
        ELSE
          DELETE FROM messages WHERE recipient_id = rid AND message_id < min_id;
        END IF;

        GET DIAGNOSTICS del_count = ROW_COUNT;
        total_deleted := total_deleted + del_count;
      EXCEPTION WHEN OTHERS THEN
        ROLLBACK;
        RAISE WARNING 'STORE, expire_old_messages, error expiring queue %: %', encode(rid, 'base64'), SQLERRM;
        CONTINUE;
      END;
      COMMIT;
    END LOOP;

    r_expired_msgs_count := total_deleted;
    r_stored_msgs_count := (SELECT COUNT(1) FROM messages);
    r_stored_queues := (SELECT COUNT(1) FROM msg_queues WHERE deleted_at IS NULL);
  END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION on_messages_delete()
RETURNS TRIGGER AS $$
BEGIN
  UPDATE msg_queues q
  SET msg_can_write = msg_can_write OR msg_queue_size <= d.del_count,
      msg_queue_size = msg_queue_size - d.del_count
  FROM (
    SELECT recipient_id, COUNT(1) AS del_count
    FROM deleted_messages -- Transition table alias
    GROUP BY recipient_id
  ) d
  WHERE q.recipient_id = d.recipient_id;
  RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER tr_messages_delete
AFTER DELETE ON messages
REFERENCING OLD TABLE AS deleted_messages
FOR EACH STATEMENT
EXECUTE FUNCTION on_messages_delete();
    |]

down_m20250903_store_messages :: Text
down_m20250903_store_messages =
  T.pack
    [r|
DROP TRIGGER tr_messages_delete ON messages;
DROP FUNCTION on_messages_delete;

DROP FUNCTION write_message;
DROP PROCEDURE expire_old_messages;

DROP INDEX idx_messages_recipient_id_message_id;
DROP INDEX idx_messages_recipient_id_msg_ts;
DROP INDEX idx_messages_recipient_id_msg_quota;

ALTER TABLE msg_queues
  DROP COLUMN msg_can_write,
  DROP COLUMN msg_queue_size;

DROP TABLE messages;
    |]
