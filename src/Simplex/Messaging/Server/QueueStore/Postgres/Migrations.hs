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

CREATE INDEX idx_messages_recipient_id_message_id ON messages (recipient_id, message_id); -- for FK and peek/del
CREATE INDEX idx_messages_recipient_id_msg_ts on messages(recipient_id, msg_ts); -- for queue expiration
CREATE INDEX idx_messages_msg_ts on messages(msg_ts); -- for global expiration

CREATE FUNCTION on_message_insert() RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  UPDATE msg_queues
  SET msg_can_write = NOT NEW.msg_quota,
      msg_queue_size = msg_queue_size + 1
  WHERE recipient_id = NEW.recipient_id;
  RETURN NEW;
END;
$$;

CREATE FUNCTION on_message_delete() RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  UPDATE msg_queues
  SET msg_can_write = msg_can_write OR msg_queue_size <= 1,
      msg_queue_size = msg_queue_size - 1
  WHERE recipient_id = OLD.recipient_id;
  RETURN OLD;
END;
$$;

CREATE TRIGGER tr_messages_insert
AFTER INSERT ON messages
FOR EACH ROW EXECUTE PROCEDURE on_message_insert();

CREATE TRIGGER tr_messages_delete
AFTER DELETE ON messages
FOR EACH ROW EXECUTE PROCEDURE on_message_delete();
    |]

down_m20250903_store_messages :: Text
down_m20250903_store_messages =
  T.pack
    [r|
DROP TRIGGER tr_messages_insert ON messages;
DROP TRIGGER tr_messages_delete ON messages;
DROP FUNCTION on_message_insert;
DROP FUNCTION on_message_delete;

DROP INDEX idx_messages_recipient_id_message_id;
DROP INDEX idx_messages_recipient_id_msg_ts;
DROP INDEX idx_messages_msg_ts;

ALTER TABLE msg_queues
  DROP COLUMN msg_can_write,
  DROP COLUMN msg_queue_size;

DROP TABLE messages;
    |]
