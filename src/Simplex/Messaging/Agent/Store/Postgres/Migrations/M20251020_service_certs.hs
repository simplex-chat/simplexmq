{-# LANGUAGE QuasiQuotes #-}

module Simplex.Messaging.Agent.Store.Postgres.Migrations.M20251020_service_certs where

import Data.Text (Text)
import qualified Data.Text as T
import Text.RawString.QQ (r)

m20251020_service_certs :: Text
m20251020_service_certs =
  T.pack
    [r|
CREATE TABLE client_services(
  user_id BIGINT NOT NULL REFERENCES users ON UPDATE RESTRICT ON DELETE CASCADE,
  host TEXT NOT NULL,
  port TEXT NOT NULL,
  service_cert BYTEA NOT NULL,
  service_cert_hash BYTEA NOT NULL,
  service_priv_key BYTEA NOT NULL,
  service_id BYTEA,
  service_queue_count BIGINT NOT NULL DEFAULT 0,
  service_queue_ids_hash BYTEA NOT NULL DEFAULT '\x00000000000000000000000000000000',
  FOREIGN KEY(host, port) REFERENCES servers ON UPDATE CASCADE ON DELETE RESTRICT
);

CREATE UNIQUE INDEX idx_server_certs_user_id_host_port ON client_services(user_id, host, port);
CREATE INDEX idx_server_certs_host_port ON client_services(host, port);

ALTER TABLE rcv_queues ADD COLUMN rcv_service_assoc SMALLINT NOT NULL DEFAULT 0;
    |]

down_m20251020_service_certs :: Text
down_m20251020_service_certs =
  T.pack
    [r|
ALTER TABLE rcv_queues DROP COLUMN rcv_service_assoc;

DROP INDEX idx_server_certs_host_port;
DROP INDEX idx_server_certs_user_id_host_port;
DROP TABLE client_services;
    |]
