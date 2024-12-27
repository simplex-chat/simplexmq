{-# LANGUAGE QuasiQuotes #-}

module Simplex.Messaging.Agent.Store.Postgres.Migrations.M20241210_initial where

import Data.Text (Text)
import qualified Data.Text as T
import Text.RawString.QQ (r)

m20241210_initial :: Text
m20241210_initial =
  T.pack
    [r|
CREATE TABLE users(
  user_id BIGINT PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
  deleted SMALLINT NOT NULL DEFAULT 0
);
CREATE TABLE servers(
  host TEXT NOT NULL,
  port TEXT NOT NULL,
  key_hash BYTEA NOT NULL,
  PRIMARY KEY(host, port)
);
CREATE TABLE connections(
  conn_id BYTEA NOT NULL PRIMARY KEY,
  conn_mode TEXT NOT NULL,
  last_internal_msg_id BIGINT NOT NULL DEFAULT 0,
  last_internal_rcv_msg_id BIGINT NOT NULL DEFAULT 0,
  last_internal_snd_msg_id BIGINT NOT NULL DEFAULT 0,
  last_external_snd_msg_id BIGINT NOT NULL DEFAULT 0,
  last_rcv_msg_hash BYTEA NOT NULL DEFAULT ''::BYTEA,
  last_snd_msg_hash BYTEA NOT NULL DEFAULT ''::BYTEA,
  smp_agent_version INTEGER NOT NULL DEFAULT 1,
  duplex_handshake SMALLINT NULL DEFAULT 0,
  enable_ntfs SMALLINT,
  deleted SMALLINT NOT NULL DEFAULT 0,
  user_id BIGINT NOT NULL REFERENCES users ON DELETE CASCADE,
  ratchet_sync_state TEXT NOT NULL DEFAULT 'ok',
  deleted_at_wait_delivery TIMESTAMPTZ,
  pq_support SMALLINT NOT NULL DEFAULT 0
);
CREATE TABLE rcv_queues(
  host TEXT NOT NULL,
  port TEXT NOT NULL,
  rcv_id BYTEA NOT NULL,
  conn_id BYTEA NOT NULL REFERENCES connections ON DELETE CASCADE,
  rcv_private_key BYTEA NOT NULL,
  rcv_dh_secret BYTEA NOT NULL,
  e2e_priv_key BYTEA NOT NULL,
  e2e_dh_secret BYTEA,
  snd_id BYTEA NOT NULL,
  snd_key BYTEA,
  status TEXT NOT NULL,
  smp_server_version INTEGER NOT NULL DEFAULT 1,
  smp_client_version INTEGER,
  ntf_public_key BYTEA,
  ntf_private_key BYTEA,
  ntf_id BYTEA,
  rcv_ntf_dh_secret BYTEA,
  rcv_queue_id BIGINT NOT NULL,
  rcv_primary SMALLINT NOT NULL,
  replace_rcv_queue_id BIGINT NULL,
  delete_errors BIGINT NOT NULL DEFAULT 0,
  server_key_hash BYTEA,
  switch_status TEXT,
  deleted SMALLINT NOT NULL DEFAULT 0,
  snd_secure SMALLINT NOT NULL DEFAULT 0,
  last_broker_ts TIMESTAMPTZ,
  PRIMARY KEY(host, port, rcv_id),
  FOREIGN KEY(host, port) REFERENCES servers
  ON DELETE RESTRICT ON UPDATE CASCADE,
  UNIQUE(host, port, snd_id)
);
CREATE TABLE snd_queues(
  host TEXT NOT NULL,
  port TEXT NOT NULL,
  snd_id BYTEA NOT NULL,
  conn_id BYTEA NOT NULL REFERENCES connections ON DELETE CASCADE,
  snd_private_key BYTEA NOT NULL,
  e2e_dh_secret BYTEA NOT NULL,
  status TEXT NOT NULL,
  smp_server_version INTEGER NOT NULL DEFAULT 1,
  smp_client_version INTEGER NOT NULL DEFAULT 1,
  snd_public_key BYTEA,
  e2e_pub_key BYTEA,
  snd_queue_id BIGINT NOT NULL,
  snd_primary SMALLINT NOT NULL,
  replace_snd_queue_id BIGINT NULL,
  server_key_hash BYTEA,
  switch_status TEXT,
  snd_secure SMALLINT NOT NULL DEFAULT 0,
  PRIMARY KEY(host, port, snd_id),
  FOREIGN KEY(host, port) REFERENCES servers
  ON DELETE RESTRICT ON UPDATE CASCADE
);
CREATE TABLE messages(
  conn_id BYTEA NOT NULL REFERENCES connections(conn_id)
  ON DELETE CASCADE,
  internal_id BIGINT NOT NULL,
  internal_ts TIMESTAMPTZ NOT NULL,
  internal_rcv_id BIGINT,
  internal_snd_id BIGINT,
  msg_type BYTEA NOT NULL,
  msg_body BYTEA NOT NULL DEFAULT ''::BYTEA,
  msg_flags TEXT NULL,
  pq_encryption SMALLINT NOT NULL DEFAULT 0,
  PRIMARY KEY(conn_id, internal_id)
);
CREATE TABLE rcv_messages(
  conn_id BYTEA NOT NULL,
  internal_rcv_id BIGINT NOT NULL,
  internal_id BIGINT NOT NULL,
  external_snd_id BIGINT NOT NULL,
  broker_id BYTEA NOT NULL,
  broker_ts TIMESTAMPTZ NOT NULL,
  internal_hash BYTEA NOT NULL,
  external_prev_snd_hash BYTEA NOT NULL,
  integrity BYTEA NOT NULL,
  user_ack SMALLINT NULL DEFAULT 0,
  rcv_queue_id BIGINT NOT NULL,
  PRIMARY KEY(conn_id, internal_rcv_id),
  FOREIGN KEY(conn_id, internal_id) REFERENCES messages
  ON DELETE CASCADE
);
ALTER TABLE messages
ADD CONSTRAINT fk_messages_rcv_messages
  FOREIGN KEY (conn_id, internal_rcv_id) REFERENCES rcv_messages
  ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED;
CREATE TABLE snd_messages(
  conn_id BYTEA NOT NULL,
  internal_snd_id BIGINT NOT NULL,
  internal_id BIGINT NOT NULL,
  internal_hash BYTEA NOT NULL,
  previous_msg_hash BYTEA NOT NULL DEFAULT ''::BYTEA,
  retry_int_slow BIGINT,
  retry_int_fast BIGINT,
  rcpt_internal_id BIGINT,
  rcpt_status TEXT,
  PRIMARY KEY(conn_id, internal_snd_id),
  FOREIGN KEY(conn_id, internal_id) REFERENCES messages
  ON DELETE CASCADE
);
ALTER TABLE messages
ADD CONSTRAINT fk_messages_snd_messages
  FOREIGN KEY (conn_id, internal_snd_id) REFERENCES snd_messages
  ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED;
CREATE TABLE conn_confirmations(
  confirmation_id BYTEA NOT NULL PRIMARY KEY,
  conn_id BYTEA NOT NULL REFERENCES connections ON DELETE CASCADE,
  e2e_snd_pub_key BYTEA NOT NULL,
  sender_key BYTEA,
  ratchet_state BYTEA NOT NULL,
  sender_conn_info BYTEA NOT NULL,
  accepted SMALLINT NOT NULL,
  own_conn_info BYTEA,
  created_at TIMESTAMPTZ NOT NULL DEFAULT (now()),
  smp_reply_queues BYTEA NULL,
  smp_client_version INTEGER
);
CREATE TABLE conn_invitations(
  invitation_id BYTEA NOT NULL PRIMARY KEY,
  contact_conn_id BYTEA NOT NULL REFERENCES connections ON DELETE CASCADE,
  cr_invitation BYTEA NOT NULL,
  recipient_conn_info BYTEA NOT NULL,
  accepted SMALLINT NOT NULL DEFAULT 0,
  own_conn_info BYTEA,
  created_at TIMESTAMPTZ NOT NULL DEFAULT (now())
);
CREATE TABLE ratchets(
  conn_id BYTEA NOT NULL PRIMARY KEY REFERENCES connections
  ON DELETE CASCADE,
  x3dh_priv_key_1 BYTEA,
  x3dh_priv_key_2 BYTEA,
  ratchet_state BYTEA,
  e2e_version INTEGER NOT NULL DEFAULT 1,
  x3dh_pub_key_1 BYTEA,
  x3dh_pub_key_2 BYTEA,
  pq_priv_kem BYTEA,
  pq_pub_kem BYTEA
);
CREATE TABLE skipped_messages(
  skipped_message_id BIGINT PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
  conn_id BYTEA NOT NULL REFERENCES ratchets
  ON DELETE CASCADE,
  header_key BYTEA NOT NULL,
  msg_n BIGINT NOT NULL,
  msg_key BYTEA NOT NULL
);
CREATE TABLE ntf_servers(
  ntf_host TEXT NOT NULL,
  ntf_port TEXT NOT NULL,
  ntf_key_hash BYTEA NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT (now()),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT (now()),
  PRIMARY KEY(ntf_host, ntf_port)
);
CREATE TABLE ntf_tokens(
  provider TEXT NOT NULL,
  device_token TEXT NOT NULL,
  ntf_host TEXT NOT NULL,
  ntf_port TEXT NOT NULL,
  tkn_id BYTEA,
  tkn_pub_key BYTEA NOT NULL,
  tkn_priv_key BYTEA NOT NULL,
  tkn_pub_dh_key BYTEA NOT NULL,
  tkn_priv_dh_key BYTEA NOT NULL,
  tkn_dh_secret BYTEA,
  tkn_status TEXT NOT NULL,
  tkn_action BYTEA,
  created_at TIMESTAMPTZ NOT NULL DEFAULT (now()),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT (now()),
  ntf_mode TEXT NULL,
  PRIMARY KEY(provider, device_token, ntf_host, ntf_port),
  FOREIGN KEY(ntf_host, ntf_port) REFERENCES ntf_servers
  ON DELETE RESTRICT ON UPDATE CASCADE
);
CREATE TABLE ntf_subscriptions(
  conn_id BYTEA NOT NULL,
  smp_host TEXT NULL,
  smp_port TEXT NULL,
  smp_ntf_id BYTEA,
  ntf_host TEXT NOT NULL,
  ntf_port TEXT NOT NULL,
  ntf_sub_id BYTEA,
  ntf_sub_status TEXT NOT NULL,
  ntf_sub_action TEXT,
  ntf_sub_smp_action TEXT,
  ntf_sub_action_ts TIMESTAMPTZ,
  updated_by_supervisor SMALLINT NOT NULL DEFAULT 0,
  created_at TIMESTAMPTZ NOT NULL DEFAULT (now()),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT (now()),
  smp_server_key_hash BYTEA,
  ntf_failed SMALLINT DEFAULT 0,
  smp_failed SMALLINT DEFAULT 0,
  PRIMARY KEY(conn_id),
  FOREIGN KEY(smp_host, smp_port) REFERENCES servers(host, port)
  ON DELETE SET NULL ON UPDATE CASCADE,
  FOREIGN KEY(ntf_host, ntf_port) REFERENCES ntf_servers
  ON DELETE RESTRICT ON UPDATE CASCADE
);
CREATE TABLE commands(
  command_id BIGINT PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
  conn_id BYTEA NOT NULL REFERENCES connections ON DELETE CASCADE,
  host TEXT,
  port TEXT,
  corr_id BYTEA NOT NULL,
  command_tag BYTEA NOT NULL,
  command BYTEA NOT NULL,
  agent_version INTEGER NOT NULL DEFAULT 1,
  server_key_hash BYTEA,
  created_at TIMESTAMPTZ NOT NULL DEFAULT '1970-01-01 00:00:00',
  failed SMALLINT DEFAULT 0,
  FOREIGN KEY(host, port) REFERENCES servers
  ON DELETE RESTRICT ON UPDATE CASCADE
);
CREATE TABLE snd_message_deliveries(
  snd_message_delivery_id BIGINT PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
  conn_id BYTEA NOT NULL REFERENCES connections ON DELETE CASCADE,
  snd_queue_id BIGINT NOT NULL,
  internal_id BIGINT NOT NULL,
  failed SMALLINT DEFAULT 0,
  FOREIGN KEY(conn_id, internal_id) REFERENCES messages ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED
);
CREATE TABLE xftp_servers(
  xftp_server_id BIGINT PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
  xftp_host TEXT NOT NULL,
  xftp_port TEXT NOT NULL,
  xftp_key_hash BYTEA NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT (now()),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT (now()),
  UNIQUE(xftp_host, xftp_port, xftp_key_hash)
);
CREATE TABLE rcv_files(
  rcv_file_id BIGINT PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
  rcv_file_entity_id BYTEA NOT NULL,
  user_id BIGINT NOT NULL REFERENCES users ON DELETE CASCADE,
  size BIGINT NOT NULL,
  digest BYTEA NOT NULL,
  key BYTEA NOT NULL,
  nonce BYTEA NOT NULL,
  chunk_size BIGINT NOT NULL,
  prefix_path TEXT NOT NULL,
  tmp_path TEXT,
  save_path TEXT NOT NULL,
  status TEXT NOT NULL,
  deleted SMALLINT NOT NULL DEFAULT 0,
  error TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT (now()),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT (now()),
  save_file_key BYTEA,
  save_file_nonce BYTEA,
  failed SMALLINT DEFAULT 0,
  redirect_id BIGINT REFERENCES rcv_files ON DELETE SET NULL,
  redirect_entity_id BYTEA,
  redirect_size BIGINT,
  redirect_digest BYTEA,
  approved_relays SMALLINT NOT NULL DEFAULT 0,
  UNIQUE(rcv_file_entity_id)
);
CREATE TABLE rcv_file_chunks(
  rcv_file_chunk_id BIGINT PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
  rcv_file_id BIGINT NOT NULL REFERENCES rcv_files ON DELETE CASCADE,
  chunk_no BIGINT NOT NULL,
  chunk_size BIGINT NOT NULL,
  digest BYTEA NOT NULL,
  tmp_path TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT (now()),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT (now())
);
CREATE TABLE rcv_file_chunk_replicas(
  rcv_file_chunk_replica_id BIGINT PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
  rcv_file_chunk_id BIGINT NOT NULL REFERENCES rcv_file_chunks ON DELETE CASCADE,
  replica_number BIGINT NOT NULL,
  xftp_server_id BIGINT NOT NULL REFERENCES xftp_servers ON DELETE CASCADE,
  replica_id BYTEA NOT NULL,
  replica_key BYTEA NOT NULL,
  received SMALLINT NOT NULL DEFAULT 0,
  delay BIGINT,
  retries BIGINT NOT NULL DEFAULT 0,
  created_at TIMESTAMPTZ NOT NULL DEFAULT (now()),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT (now())
);
CREATE TABLE snd_files(
  snd_file_id BIGINT PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
  snd_file_entity_id BYTEA NOT NULL,
  user_id BIGINT NOT NULL REFERENCES users ON DELETE CASCADE,
  num_recipients BIGINT NOT NULL,
  digest BYTEA,
  key BYTEA NOT NUll,
  nonce BYTEA NOT NUll,
  path TEXT NOT NULL,
  prefix_path TEXT,
  status TEXT NOT NULL,
  deleted SMALLINT NOT NULL DEFAULT 0,
  error TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT (now()),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT (now()),
  src_file_key BYTEA,
  src_file_nonce BYTEA,
  failed SMALLINT DEFAULT 0,
  redirect_size BIGINT,
  redirect_digest BYTEA
);
CREATE TABLE snd_file_chunks(
  snd_file_chunk_id BIGINT PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
  snd_file_id BIGINT NOT NULL REFERENCES snd_files ON DELETE CASCADE,
  chunk_no BIGINT NOT NULL,
  chunk_offset BIGINT NOT NULL,
  chunk_size BIGINT NOT NULL,
  digest BYTEA NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT (now()),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT (now())
);
CREATE TABLE snd_file_chunk_replicas(
  snd_file_chunk_replica_id BIGINT PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
  snd_file_chunk_id BIGINT NOT NULL REFERENCES snd_file_chunks ON DELETE CASCADE,
  replica_number BIGINT NOT NULL,
  xftp_server_id BIGINT NOT NULL REFERENCES xftp_servers ON DELETE CASCADE,
  replica_id BYTEA NOT NULL,
  replica_key BYTEA NOT NULL,
  replica_status TEXT NOT NULL,
  delay BIGINT,
  retries BIGINT NOT NULL DEFAULT 0,
  created_at TIMESTAMPTZ NOT NULL DEFAULT (now()),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT (now())
);
CREATE TABLE snd_file_chunk_replica_recipients(
  snd_file_chunk_replica_recipient_id BIGINT PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
  snd_file_chunk_replica_id BIGINT NOT NULL REFERENCES snd_file_chunk_replicas ON DELETE CASCADE,
  rcv_replica_id BYTEA NOT NULL,
  rcv_replica_key BYTEA NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT (now()),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT (now())
);
CREATE TABLE deleted_snd_chunk_replicas(
  deleted_snd_chunk_replica_id BIGINT PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
  user_id BIGINT NOT NULL REFERENCES users ON DELETE CASCADE,
  xftp_server_id BIGINT NOT NULL REFERENCES xftp_servers ON DELETE CASCADE,
  replica_id BYTEA NOT NULL,
  replica_key BYTEA NOT NULL,
  chunk_digest BYTEA NOT NULL,
  delay BIGINT,
  retries BIGINT NOT NULL DEFAULT 0,
  created_at TIMESTAMPTZ NOT NULL DEFAULT (now()),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT (now()),
  failed SMALLINT DEFAULT 0
);
CREATE TABLE encrypted_rcv_message_hashes(
  encrypted_rcv_message_hash_id BIGINT PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
  conn_id BYTEA NOT NULL REFERENCES connections ON DELETE CASCADE,
  hash BYTEA NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT (now()),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT (now())
);
CREATE TABLE processed_ratchet_key_hashes(
  processed_ratchet_key_hash_id BIGINT PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
  conn_id BYTEA NOT NULL REFERENCES connections ON DELETE CASCADE,
  hash BYTEA NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT (now()),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT (now())
);
CREATE TABLE servers_stats(
  servers_stats_id BIGINT PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
  servers_stats TEXT,
  started_at TIMESTAMPTZ NOT NULL DEFAULT (now()),
  created_at TIMESTAMPTZ NOT NULL DEFAULT (now()),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT (now())
);
INSERT INTO servers_stats DEFAULT VALUES;
CREATE TABLE ntf_tokens_to_delete(
  ntf_token_to_delete_id BIGINT PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
  ntf_host TEXT NOT NULL,
  ntf_port TEXT NOT NULL,
  ntf_key_hash BYTEA NOT NULL,
  tkn_id BYTEA NOT NULL,
  tkn_priv_key BYTEA NOT NULL,
  del_failed SMALLINT DEFAULT 0,
  created_at TIMESTAMPTZ NOT NULL DEFAULT (now())
);
CREATE UNIQUE INDEX idx_rcv_queues_ntf ON rcv_queues(host, port, ntf_id);
CREATE UNIQUE INDEX idx_rcv_queue_id ON rcv_queues(conn_id, rcv_queue_id);
CREATE UNIQUE INDEX idx_snd_queue_id ON snd_queues(conn_id, snd_queue_id);
CREATE INDEX idx_snd_message_deliveries ON snd_message_deliveries(
  conn_id,
  snd_queue_id
);
CREATE INDEX idx_connections_user ON connections(user_id);
CREATE INDEX idx_commands_conn_id ON commands(conn_id);
CREATE INDEX idx_commands_host_port ON commands(host, port);
CREATE INDEX idx_conn_confirmations_conn_id ON conn_confirmations(conn_id);
CREATE INDEX idx_conn_invitations_contact_conn_id ON conn_invitations(
  contact_conn_id
);
CREATE INDEX idx_messages_conn_id_internal_snd_id ON messages(
  conn_id,
  internal_snd_id
);
CREATE INDEX idx_messages_conn_id_internal_rcv_id ON messages(
  conn_id,
  internal_rcv_id
);
CREATE INDEX idx_messages_conn_id ON messages(conn_id);
CREATE INDEX idx_ntf_subscriptions_ntf_host_ntf_port ON ntf_subscriptions(
  ntf_host,
  ntf_port
);
CREATE INDEX idx_ntf_subscriptions_smp_host_smp_port ON ntf_subscriptions(
  smp_host,
  smp_port
);
CREATE INDEX idx_ntf_tokens_ntf_host_ntf_port ON ntf_tokens(
  ntf_host,
  ntf_port
);
CREATE INDEX idx_ratchets_conn_id ON ratchets(conn_id);
CREATE INDEX idx_rcv_messages_conn_id_internal_id ON rcv_messages(
  conn_id,
  internal_id
);
CREATE INDEX idx_skipped_messages_conn_id ON skipped_messages(conn_id);
CREATE INDEX idx_snd_message_deliveries_conn_id_internal_id ON snd_message_deliveries(
  conn_id,
  internal_id
);
CREATE INDEX idx_snd_messages_conn_id_internal_id ON snd_messages(
  conn_id,
  internal_id
);
CREATE INDEX idx_snd_queues_host_port ON snd_queues(host, port);
CREATE INDEX idx_rcv_files_user_id ON rcv_files(user_id);
CREATE INDEX idx_rcv_file_chunks_rcv_file_id ON rcv_file_chunks(rcv_file_id);
CREATE INDEX idx_rcv_file_chunk_replicas_rcv_file_chunk_id ON rcv_file_chunk_replicas(
  rcv_file_chunk_id
);
CREATE INDEX idx_rcv_file_chunk_replicas_xftp_server_id ON rcv_file_chunk_replicas(
  xftp_server_id
);
CREATE INDEX idx_snd_files_user_id ON snd_files(user_id);
CREATE INDEX idx_snd_file_chunks_snd_file_id ON snd_file_chunks(snd_file_id);
CREATE INDEX idx_snd_file_chunk_replicas_snd_file_chunk_id ON snd_file_chunk_replicas(
  snd_file_chunk_id
);
CREATE INDEX idx_snd_file_chunk_replicas_xftp_server_id ON snd_file_chunk_replicas(
  xftp_server_id
);
CREATE INDEX idx_snd_file_chunk_replica_recipients_snd_file_chunk_replica_id ON snd_file_chunk_replica_recipients(
  snd_file_chunk_replica_id
);
CREATE INDEX idx_deleted_snd_chunk_replicas_user_id ON deleted_snd_chunk_replicas(
  user_id
);
CREATE INDEX idx_deleted_snd_chunk_replicas_xftp_server_id ON deleted_snd_chunk_replicas(
  xftp_server_id
);
CREATE INDEX idx_rcv_file_chunk_replicas_pending ON rcv_file_chunk_replicas(
  received,
  replica_number
);
CREATE INDEX idx_snd_file_chunk_replicas_pending ON snd_file_chunk_replicas(
  replica_status,
  replica_number
);
CREATE INDEX idx_deleted_snd_chunk_replicas_pending ON deleted_snd_chunk_replicas(
  created_at
);
CREATE INDEX idx_encrypted_rcv_message_hashes_hash ON encrypted_rcv_message_hashes(
  conn_id,
  hash
);
CREATE INDEX idx_processed_ratchet_key_hashes_hash ON processed_ratchet_key_hashes(
  conn_id,
  hash
);
CREATE INDEX idx_snd_messages_rcpt_internal_id ON snd_messages(
  conn_id,
  rcpt_internal_id
);
CREATE INDEX idx_processed_ratchet_key_hashes_created_at ON processed_ratchet_key_hashes(
  created_at
);
CREATE INDEX idx_encrypted_rcv_message_hashes_created_at ON encrypted_rcv_message_hashes(
  created_at
);
CREATE INDEX idx_messages_internal_ts ON messages(internal_ts);
CREATE INDEX idx_commands_server_commands ON commands(
  host,
  port,
  created_at,
  command_id
);
CREATE INDEX idx_rcv_files_status_created_at ON rcv_files(status, created_at);
CREATE INDEX idx_snd_files_status_created_at ON snd_files(status, created_at);
CREATE INDEX idx_snd_files_snd_file_entity_id ON snd_files(snd_file_entity_id);
CREATE INDEX idx_messages_snd_expired ON messages(
  conn_id,
  internal_snd_id,
  internal_ts
);
CREATE INDEX idx_snd_message_deliveries_expired ON snd_message_deliveries(
  conn_id,
  snd_queue_id,
  failed,
  internal_id
);
CREATE INDEX idx_rcv_files_redirect_id on rcv_files(redirect_id);
|]
