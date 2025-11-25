{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}

module Simplex.Messaging.Agent.Store.Postgres.Migrations.M20251020_service_certs where

import Data.Text (Text)
import Simplex.Messaging.Agent.Store.Postgres.Migrations.Util
import Text.RawString.QQ (r)

m20251020_service_certs :: Text
m20251020_service_certs =
  createXorHashFuncs <> [r|
CREATE TABLE client_services(
  user_id BIGINT NOT NULL REFERENCES users ON UPDATE RESTRICT ON DELETE CASCADE,
  host TEXT NOT NULL,
  port TEXT NOT NULL,
  server_key_hash BYTEA,
  service_cert BYTEA NOT NULL,
  service_cert_hash BYTEA NOT NULL,
  service_priv_key BYTEA NOT NULL,
  service_id BYTEA,
  service_queue_count BIGINT NOT NULL DEFAULT 0,
  service_queue_ids_hash BYTEA NOT NULL DEFAULT '\x00000000000000000000000000000000',
  FOREIGN KEY(host, port) REFERENCES servers ON DELETE RESTRICT
);

CREATE UNIQUE INDEX idx_server_certs_user_id_host_port ON client_services(user_id, host, port, server_key_hash);
CREATE INDEX idx_server_certs_host_port ON client_services(host, port);

ALTER TABLE rcv_queues ADD COLUMN rcv_service_assoc SMALLINT NOT NULL DEFAULT 0;

CREATE FUNCTION update_aggregates(p_conn_id BYTEA, p_host TEXT, p_port TEXT, p_change BIGINT, p_rcv_id BYTEA) RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE q_user_id BIGINT;
BEGIN
  SELECT user_id INTO q_user_id FROM connections WHERE conn_id = p_conn_id;
  UPDATE client_services
  SET service_queue_count = service_queue_count + p_change,
      service_queue_ids_hash = xor_combine(service_queue_ids_hash, public.digest(p_rcv_id, 'md5'))
  WHERE user_id = q_user_id AND host = p_host AND port = p_port;
END;
$$;

CREATE FUNCTION on_rcv_queue_insert() RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.rcv_service_assoc != 0 AND NEW.deleted = 0 THEN
    PERFORM update_aggregates(NEW.conn_id, NEW.host, NEW.port, 1, NEW.rcv_id);
  END IF;
  RETURN NEW;
END;
$$;

CREATE FUNCTION on_rcv_queue_delete() RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF OLD.rcv_service_assoc != 0 AND OLD.deleted = 0 THEN
    PERFORM update_aggregates(OLD.conn_id, OLD.host, OLD.port, -1, OLD.rcv_id);
  END IF;
  RETURN OLD;
END;
$$;

CREATE FUNCTION on_rcv_queue_update() RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF OLD.rcv_service_assoc != 0 AND OLD.deleted = 0 THEN
    IF NOT (NEW.rcv_service_assoc != 0 AND NEW.deleted = 0) THEN
      PERFORM update_aggregates(OLD.conn_id, OLD.host, OLD.port, -1, OLD.rcv_id);
    END IF;
  ELSIF NEW.rcv_service_assoc != 0 AND NEW.deleted = 0 THEN
    PERFORM update_aggregates(NEW.conn_id, NEW.host, NEW.port, 1, NEW.rcv_id);
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER tr_rcv_queue_insert
AFTER INSERT ON rcv_queues
FOR EACH ROW EXECUTE PROCEDURE on_rcv_queue_insert();

CREATE TRIGGER tr_rcv_queue_delete
AFTER DELETE ON rcv_queues
FOR EACH ROW EXECUTE PROCEDURE on_rcv_queue_delete();

CREATE TRIGGER tr_rcv_queue_update
AFTER UPDATE ON rcv_queues
FOR EACH ROW EXECUTE PROCEDURE on_rcv_queue_update();
    |]

down_m20251020_service_certs :: Text
down_m20251020_service_certs =
  [r|
DROP TRIGGER tr_rcv_queue_insert ON rcv_queues;
DROP TRIGGER tr_rcv_queue_delete ON rcv_queues;
DROP TRIGGER tr_rcv_queue_update ON rcv_queues;

DROP FUNCTION on_rcv_queue_insert;
DROP FUNCTION on_rcv_queue_delete;
DROP FUNCTION on_rcv_queue_update;

DROP FUNCTION update_aggregates;

ALTER TABLE rcv_queues DROP COLUMN rcv_service_assoc;

DROP INDEX idx_server_certs_host_port;
DROP INDEX idx_server_certs_user_id_host_port;
DROP TABLE client_services;
  |]
  <> dropXorHashFuncs
