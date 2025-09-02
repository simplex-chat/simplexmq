{-# LANGUAGE QuasiQuotes #-}

module Simplex.Messaging.Agent.Store.SQLite.Migrations.M20250815_service_certs where

import Database.SQLite.Simple (Query)
import Database.SQLite.Simple.QQ (sql)

m20250815_service_certs :: Query
m20250815_service_certs =
  [sql|
CREATE TABLE client_services(
  user_id INTEGER NOT NULL REFERENCES users ON UPDATE RESTRICT ON DELETE CASCADE,
  host TEXT NOT NULL,
  port TEXT NOT NULL,
  service_cert BLOB NOT NULL,
  service_cert_hash BLOB NOT NULL,
  service_priv_key BLOB NOT NULL,
  service_id BLOB,
  service_queue_count INTEGER NOT NULL DEFAULT 0,
  service_queue_ids_hash BLOB NOT NULL DEFAULT x'00000000000000000000000000000000',
  FOREIGN KEY(host, port) REFERENCES servers ON UPDATE CASCADE ON DELETE RESTRICT
);

CREATE UNIQUE INDEX idx_server_certs_user_id_host_port ON client_services(user_id, host, port);
CREATE INDEX idx_server_certs_host_port ON client_services(host, port);

ALTER TABLE rcv_queues ADD COLUMN rcv_service_assoc INTEGER NOT NULL DEFAULT 0;

CREATE TRIGGER tr_rcv_queue_insert
AFTER INSERT ON rcv_queues
FOR EACH ROW
WHEN NEW.rcv_service_assoc != 0 AND NEW.deleted = 0
BEGIN
  UPDATE client_services
  SET service_queue_count = service_queue_count + 1,
      service_queue_ids_hash = chat_xor_combine(service_queue_ids_hash, chat_md5hash(NEW.rcv_id))
  WHERE user_id = NEW.user_id AND host = NEW.host AND port = NEW.port;
END;

CREATE TRIGGER tr_rcv_queue_delete
AFTER DELETE ON rcv_queues
FOR EACH ROW
WHEN OLD.rcv_service_assoc != 0 AND OLD.deleted = 0
BEGIN
  UPDATE client_services
  SET service_queue_count = service_queue_count - 1,
      service_queue_ids_hash = chat_xor_combine(service_queue_ids_hash, chat_md5hash(OLD.rcv_id))
  WHERE user_id = OLD.user_id AND host = OLD.host AND port = OLD.port;
END;

CREATE TRIGGER tr_rcv_queue_update_remove
AFTER UPDATE ON rcv_queues
FOR EACH ROW
WHEN OLD.rcv_service_assoc != 0 AND OLD.deleted = 0 AND NOT (NEW.rcv_service_assoc != 0 AND NEW.deleted = 0)
BEGIN
  UPDATE client_services
  SET service_queue_count = service_queue_count - 1,
      service_queue_ids_hash = chat_xor_combine(service_queue_ids_hash, chat_md5hash(OLD.rcv_id))
  WHERE user_id = OLD.user_id AND host = OLD.host AND port = OLD.port;
END;

CREATE TRIGGER tr_rcv_queue_update_add
AFTER UPDATE ON rcv_queues
FOR EACH ROW
WHEN NEW.rcv_service_assoc != 0 AND NEW.deleted = 0 AND NOT (OLD.rcv_service_assoc != 0 AND OLD.deleted = 0)
BEGIN
  UPDATE client_services
  SET service_queue_count = service_queue_count + 1,
      service_queue_ids_hash = chat_xor_combine(service_queue_ids_hash, chat_md5hash(NEW.rcv_id))
  WHERE user_id = NEW.user_id AND host = NEW.host AND port = NEW.port;
END;
  |]

down_m20250815_service_certs :: Query
down_m20250815_service_certs =
  [sql|
DROP TRIGGER tr_rcv_queue_insert;
DROP TRIGGER tr_rcv_queue_delete;
DROP TRIGGER tr_rcv_queue_update_remove;
DROP TRIGGER tr_rcv_queue_update_add;

ALTER TABLE rcv_queues DROP COLUMN rcv_service_assoc;

DROP INDEX idx_server_certs_host_port;
DROP INDEX idx_server_certs_user_id_host_port;

DROP TABLE client_services;
  |]
