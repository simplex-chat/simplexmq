CREATE TABLE migrations(
  name TEXT NOT NULL,
  ts TEXT NOT NULL,
  down TEXT,
  PRIMARY KEY(name)
);
CREATE TABLE servers(
  host TEXT NOT NULL,
  port TEXT NOT NULL,
  key_hash BLOB NOT NULL,
  PRIMARY KEY(host, port)
) WITHOUT ROWID;
CREATE TABLE connections(
  conn_id BLOB NOT NULL PRIMARY KEY,
  conn_mode TEXT NOT NULL,
  last_internal_msg_id INTEGER NOT NULL DEFAULT 0,
  last_internal_rcv_msg_id INTEGER NOT NULL DEFAULT 0,
  last_internal_snd_msg_id INTEGER NOT NULL DEFAULT 0,
  last_external_snd_msg_id INTEGER NOT NULL DEFAULT 0,
  last_rcv_msg_hash BLOB NOT NULL DEFAULT x'',
  last_snd_msg_hash BLOB NOT NULL DEFAULT x'',
  smp_agent_version INTEGER NOT NULL DEFAULT 1
  ,
  duplex_handshake INTEGER NULL DEFAULT 0,
  enable_ntfs INTEGER,
  deleted INTEGER DEFAULT 0 CHECK(deleted NOT NULL),
  user_id INTEGER CHECK(user_id NOT NULL)
  REFERENCES users ON DELETE CASCADE,
  ratchet_sync_state TEXT NOT NULL DEFAULT 'ok'
) WITHOUT ROWID;
CREATE TABLE rcv_queues(
  host TEXT NOT NULL,
  port TEXT NOT NULL,
  rcv_id BLOB NOT NULL,
  conn_id BLOB NOT NULL REFERENCES connections ON DELETE CASCADE,
  rcv_private_key BLOB NOT NULL,
  rcv_dh_secret BLOB NOT NULL,
  e2e_priv_key BLOB NOT NULL,
  e2e_dh_secret BLOB,
  snd_id BLOB NOT NULL,
  snd_key BLOB,
  status TEXT NOT NULL,
  smp_server_version INTEGER NOT NULL DEFAULT 1,
  smp_client_version INTEGER,
  ntf_public_key BLOB,
  ntf_private_key BLOB,
  ntf_id BLOB,
  rcv_ntf_dh_secret BLOB,
  rcv_queue_id INTEGER CHECK(rcv_queue_id NOT NULL),
  rcv_primary INTEGER CHECK(rcv_primary NOT NULL),
  replace_rcv_queue_id INTEGER NULL,
  delete_errors INTEGER DEFAULT 0 CHECK(delete_errors NOT NULL),
  server_key_hash BLOB,
  switch_status TEXT,
  deleted INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY(host, port, rcv_id),
  FOREIGN KEY(host, port) REFERENCES servers
  ON DELETE RESTRICT ON UPDATE CASCADE,
  UNIQUE(host, port, snd_id)
) WITHOUT ROWID;
CREATE TABLE snd_queues(
  host TEXT NOT NULL,
  port TEXT NOT NULL,
  snd_id BLOB NOT NULL,
  conn_id BLOB NOT NULL REFERENCES connections ON DELETE CASCADE,
  snd_private_key BLOB NOT NULL,
  e2e_dh_secret BLOB NOT NULL,
  status TEXT NOT NULL,
  smp_server_version INTEGER NOT NULL DEFAULT 1,
  smp_client_version INTEGER NOT NULL DEFAULT 1,
  snd_public_key BLOB,
  e2e_pub_key BLOB,
  snd_queue_id INTEGER CHECK(snd_queue_id NOT NULL),
  snd_primary INTEGER CHECK(snd_primary NOT NULL),
  replace_snd_queue_id INTEGER NULL,
  server_key_hash BLOB,
  switch_status TEXT,
  PRIMARY KEY(host, port, snd_id),
  FOREIGN KEY(host, port) REFERENCES servers
  ON DELETE RESTRICT ON UPDATE CASCADE
) WITHOUT ROWID;
CREATE TABLE messages(
  conn_id BLOB NOT NULL REFERENCES connections(conn_id)
  ON DELETE CASCADE,
  internal_id INTEGER NOT NULL,
  internal_ts TEXT NOT NULL,
  internal_rcv_id INTEGER,
  internal_snd_id INTEGER,
  msg_type BLOB NOT NULL, --(H)ELLO,(R)EPLY,(D)ELETE. Should SMP confirmation be saved too?
  msg_body BLOB NOT NULL DEFAULT x'',
  msg_flags TEXT NULL,
  PRIMARY KEY(conn_id, internal_id),
  FOREIGN KEY(conn_id, internal_rcv_id) REFERENCES rcv_messages
  ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY(conn_id, internal_snd_id) REFERENCES snd_messages
  ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED
) WITHOUT ROWID;
CREATE TABLE rcv_messages(
  conn_id BLOB NOT NULL,
  internal_rcv_id INTEGER NOT NULL,
  internal_id INTEGER NOT NULL,
  external_snd_id INTEGER NOT NULL,
  broker_id BLOB NOT NULL,
  broker_ts TEXT NOT NULL,
  internal_hash BLOB NOT NULL,
  external_prev_snd_hash BLOB NOT NULL,
  integrity BLOB NOT NULL,
  user_ack INTEGER NULL DEFAULT 0,
  rcv_queue_id INTEGER CHECK(rcv_queue_id NOT NULL),
  PRIMARY KEY(conn_id, internal_rcv_id),
  FOREIGN KEY(conn_id, internal_id) REFERENCES messages
  ON DELETE CASCADE
) WITHOUT ROWID;
CREATE TABLE snd_messages(
  conn_id BLOB NOT NULL,
  internal_snd_id INTEGER NOT NULL,
  internal_id INTEGER NOT NULL,
  internal_hash BLOB NOT NULL,
  previous_msg_hash BLOB NOT NULL DEFAULT x'',
  retry_int_slow INTEGER,
  retry_int_fast INTEGER,
  rcpt_internal_id INTEGER,
  rcpt_status TEXT,
  PRIMARY KEY(conn_id, internal_snd_id),
  FOREIGN KEY(conn_id, internal_id) REFERENCES messages
  ON DELETE CASCADE
) WITHOUT ROWID;
CREATE TABLE conn_confirmations(
  confirmation_id BLOB NOT NULL PRIMARY KEY,
  conn_id BLOB NOT NULL REFERENCES connections ON DELETE CASCADE,
  e2e_snd_pub_key BLOB NOT NULL,
  sender_key BLOB NOT NULL,
  ratchet_state BLOB NOT NULL,
  sender_conn_info BLOB NOT NULL,
  accepted INTEGER NOT NULL,
  own_conn_info BLOB,
  created_at TEXT NOT NULL DEFAULT(datetime('now'))
  ,
  smp_reply_queues BLOB NULL,
  smp_client_version INTEGER
) WITHOUT ROWID;
CREATE TABLE conn_invitations(
  invitation_id BLOB NOT NULL PRIMARY KEY,
  contact_conn_id BLOB NOT NULL REFERENCES connections ON DELETE CASCADE,
  cr_invitation BLOB NOT NULL,
  recipient_conn_info BLOB NOT NULL,
  accepted INTEGER NOT NULL DEFAULT 0,
  own_conn_info BLOB,
  created_at TEXT NOT NULL DEFAULT(datetime('now'))
) WITHOUT ROWID;
CREATE TABLE ratchets(
  conn_id BLOB NOT NULL PRIMARY KEY REFERENCES connections
  ON DELETE CASCADE,
  -- x3dh keys are not saved on the sending side(the side accepting the connection)
  x3dh_priv_key_1 BLOB,
  x3dh_priv_key_2 BLOB,
  -- ratchet is initially empty on the receiving side(the side offering the connection)
  ratchet_state BLOB,
  e2e_version INTEGER NOT NULL DEFAULT 1
  ,
  x3dh_pub_key_1 BLOB,
  x3dh_pub_key_2 BLOB
) WITHOUT ROWID;
CREATE TABLE skipped_messages(
  skipped_message_id INTEGER PRIMARY KEY,
  conn_id BLOB NOT NULL REFERENCES ratchets
  ON DELETE CASCADE,
  header_key BLOB NOT NULL,
  msg_n INTEGER NOT NULL,
  msg_key BLOB NOT NULL
);
CREATE TABLE ntf_servers(
  ntf_host TEXT NOT NULL,
  ntf_port TEXT NOT NULL,
  ntf_key_hash BLOB NOT NULL,
  created_at TEXT NOT NULL DEFAULT(datetime('now')),
  updated_at TEXT NOT NULL DEFAULT(datetime('now')),
  PRIMARY KEY(ntf_host, ntf_port)
) WITHOUT ROWID;
CREATE TABLE ntf_tokens(
  provider TEXT NOT NULL, -- apns
  device_token TEXT NOT NULL, -- ! this field is mislabeled and is actually saved as binary
  ntf_host TEXT NOT NULL,
  ntf_port TEXT NOT NULL,
  tkn_id BLOB, -- token ID assigned by notifications server
  tkn_pub_key BLOB NOT NULL, -- client's public key to verify token commands(used by server, for repeat registraions)
tkn_priv_key BLOB NOT NULL, -- client's private key to sign token commands
tkn_pub_dh_key BLOB NOT NULL, -- client's public DH key(for repeat registraions)
tkn_priv_dh_key BLOB NOT NULL, -- client's private DH key(for repeat registraions)
tkn_dh_secret BLOB, -- DH secret for e2e encryption of notifications
  tkn_status TEXT NOT NULL,
  tkn_action BLOB,
  created_at TEXT NOT NULL DEFAULT(datetime('now')),
  updated_at TEXT NOT NULL DEFAULT(datetime('now')),
  ntf_mode TEXT NULL, -- this is to check token status periodically to know when it was last checked
  PRIMARY KEY(provider, device_token, ntf_host, ntf_port),
  FOREIGN KEY(ntf_host, ntf_port) REFERENCES ntf_servers
  ON DELETE RESTRICT ON UPDATE CASCADE
) WITHOUT ROWID;
CREATE TABLE ntf_subscriptions(
  conn_id BLOB NOT NULL,
  smp_host TEXT NULL,
  smp_port TEXT NULL,
  smp_ntf_id BLOB,
  ntf_host TEXT NOT NULL,
  ntf_port TEXT NOT NULL,
  ntf_sub_id BLOB,
  ntf_sub_status TEXT NOT NULL, -- see NtfAgentSubStatus
  ntf_sub_action TEXT, -- if there is an action required on this subscription: NtfSubNTFAction
  ntf_sub_smp_action TEXT, -- action with SMP server: NtfSubSMPAction; only one of this and ntf_sub_action can(should) be not null in same record
  ntf_sub_action_ts TEXT, -- the earliest time for the action, e.g. checks can be scheduled every X hours
  updated_by_supervisor INTEGER NOT NULL DEFAULT 0, -- to be checked on updates by workers to not overwrite supervisor command(state still should be updated)
  created_at TEXT NOT NULL DEFAULT(datetime('now')),
  updated_at TEXT NOT NULL DEFAULT(datetime('now')),
  smp_server_key_hash BLOB,
  PRIMARY KEY(conn_id),
  FOREIGN KEY(smp_host, smp_port) REFERENCES servers(host, port)
  ON DELETE SET NULL ON UPDATE CASCADE,
  FOREIGN KEY(ntf_host, ntf_port) REFERENCES ntf_servers
  ON DELETE RESTRICT ON UPDATE CASCADE
) WITHOUT ROWID;
CREATE TABLE commands(
  command_id INTEGER PRIMARY KEY,
  conn_id BLOB NOT NULL REFERENCES connections ON DELETE CASCADE,
  host TEXT,
  port TEXT,
  corr_id BLOB NOT NULL,
  command_tag BLOB NOT NULL,
  command BLOB NOT NULL,
  agent_version INTEGER NOT NULL DEFAULT 1,
  server_key_hash BLOB,
  FOREIGN KEY(host, port) REFERENCES servers
  ON DELETE RESTRICT ON UPDATE CASCADE
);
CREATE TABLE snd_message_deliveries(
  snd_message_delivery_id INTEGER PRIMARY KEY AUTOINCREMENT,
  conn_id BLOB NOT NULL REFERENCES connections ON DELETE CASCADE,
  snd_queue_id INTEGER NOT NULL,
  internal_id INTEGER NOT NULL,
  FOREIGN KEY(conn_id, internal_id) REFERENCES messages ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED
);
CREATE TABLE sqlite_sequence(name,seq);
CREATE TABLE users(
  user_id INTEGER PRIMARY KEY AUTOINCREMENT
  ,
  deleted INTEGER DEFAULT 0 CHECK(deleted NOT NULL)
);
CREATE TABLE xftp_servers(
  xftp_server_id INTEGER PRIMARY KEY,
  xftp_host TEXT NOT NULL,
  xftp_port TEXT NOT NULL,
  xftp_key_hash BLOB NOT NULL,
  created_at TEXT NOT NULL DEFAULT(datetime('now')),
  updated_at TEXT NOT NULL DEFAULT(datetime('now')),
  UNIQUE(xftp_host, xftp_port, xftp_key_hash)
);
CREATE TABLE rcv_files(
  rcv_file_id INTEGER PRIMARY KEY,
  rcv_file_entity_id BLOB NOT NULL,
  user_id INTEGER NOT NULL REFERENCES users ON DELETE CASCADE,
  size INTEGER NOT NULL,
  digest BLOB NOT NULL,
  key BLOB NOT NULL,
  nonce BLOB NOT NULL,
  chunk_size INTEGER NOT NULL,
  prefix_path TEXT NOT NULL,
  tmp_path TEXT,
  save_path TEXT NOT NULL,
  status TEXT NOT NULL,
  deleted INTEGER NOT NULL DEFAULT 0,
  error TEXT,
  created_at TEXT NOT NULL DEFAULT(datetime('now')),
  updated_at TEXT NOT NULL DEFAULT(datetime('now')),
  save_file_key BLOB,
  save_file_nonce BLOB,
  UNIQUE(rcv_file_entity_id)
);
CREATE TABLE rcv_file_chunks(
  rcv_file_chunk_id INTEGER PRIMARY KEY,
  rcv_file_id INTEGER NOT NULL REFERENCES rcv_files ON DELETE CASCADE,
  chunk_no INTEGER NOT NULL,
  chunk_size INTEGER NOT NULL,
  digest BLOB NOT NULL,
  tmp_path TEXT,
  created_at TEXT NOT NULL DEFAULT(datetime('now')),
  updated_at TEXT NOT NULL DEFAULT(datetime('now'))
);
CREATE TABLE rcv_file_chunk_replicas(
  rcv_file_chunk_replica_id INTEGER PRIMARY KEY,
  rcv_file_chunk_id INTEGER NOT NULL REFERENCES rcv_file_chunks ON DELETE CASCADE,
  replica_number INTEGER NOT NULL,
  xftp_server_id INTEGER NOT NULL REFERENCES xftp_servers ON DELETE CASCADE,
  replica_id BLOB NOT NULL,
  replica_key BLOB NOT NULL,
  received INTEGER NOT NULL DEFAULT 0,
  delay INTEGER,
  retries INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL DEFAULT(datetime('now')),
  updated_at TEXT NOT NULL DEFAULT(datetime('now'))
);
CREATE TABLE snd_files(
  snd_file_id INTEGER PRIMARY KEY,
  snd_file_entity_id BLOB NOT NULL,
  user_id INTEGER NOT NULL REFERENCES users ON DELETE CASCADE,
  num_recipients INTEGER NOT NULL,
  digest BLOB,
  key BLOB NOT NUll,
  nonce BLOB NOT NUll,
  path TEXT NOT NULL,
  prefix_path TEXT,
  status TEXT NOT NULL,
  deleted INTEGER NOT NULL DEFAULT 0,
  error TEXT,
  created_at TEXT NOT NULL DEFAULT(datetime('now')),
  updated_at TEXT NOT NULL DEFAULT(datetime('now'))
  ,
  src_file_key BLOB,
  src_file_nonce BLOB
);
CREATE TABLE snd_file_chunks(
  snd_file_chunk_id INTEGER PRIMARY KEY,
  snd_file_id INTEGER NOT NULL REFERENCES snd_files ON DELETE CASCADE,
  chunk_no INTEGER NOT NULL,
  chunk_offset INTEGER NOT NULL,
  chunk_size INTEGER NOT NULL,
  digest BLOB NOT NULL,
  created_at TEXT NOT NULL DEFAULT(datetime('now')),
  updated_at TEXT NOT NULL DEFAULT(datetime('now'))
);
CREATE TABLE snd_file_chunk_replicas(
  snd_file_chunk_replica_id INTEGER PRIMARY KEY,
  snd_file_chunk_id INTEGER NOT NULL REFERENCES snd_file_chunks ON DELETE CASCADE,
  replica_number INTEGER NOT NULL,
  xftp_server_id INTEGER NOT NULL REFERENCES xftp_servers ON DELETE CASCADE,
  replica_id BLOB NOT NULL,
  replica_key BLOB NOT NULL,
  replica_status TEXT NOT NULL,
  delay INTEGER,
  retries INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL DEFAULT(datetime('now')),
  updated_at TEXT NOT NULL DEFAULT(datetime('now'))
);
CREATE TABLE snd_file_chunk_replica_recipients(
  snd_file_chunk_replica_recipient_id INTEGER PRIMARY KEY,
  snd_file_chunk_replica_id INTEGER NOT NULL REFERENCES snd_file_chunk_replicas ON DELETE CASCADE,
  rcv_replica_id BLOB NOT NULL,
  rcv_replica_key BLOB NOT NULL,
  created_at TEXT NOT NULL DEFAULT(datetime('now')),
  updated_at TEXT NOT NULL DEFAULT(datetime('now'))
);
CREATE TABLE deleted_snd_chunk_replicas(
  deleted_snd_chunk_replica_id INTEGER PRIMARY KEY,
  user_id INTEGER NOT NULL REFERENCES users ON DELETE CASCADE,
  xftp_server_id INTEGER NOT NULL REFERENCES xftp_servers ON DELETE CASCADE,
  replica_id BLOB NOT NULL,
  replica_key BLOB NOT NULL,
  chunk_digest BLOB NOT NULL,
  delay INTEGER,
  retries INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL DEFAULT(datetime('now')),
  updated_at TEXT NOT NULL DEFAULT(datetime('now'))
);
CREATE TABLE encrypted_rcv_message_hashes(
  encrypted_rcv_message_hash_id INTEGER PRIMARY KEY,
  conn_id BLOB NOT NULL REFERENCES connections ON DELETE CASCADE,
  hash BLOB NOT NULL,
  created_at TEXT NOT NULL DEFAULT(datetime('now')),
  updated_at TEXT NOT NULL DEFAULT(datetime('now'))
);
CREATE TABLE processed_ratchet_key_hashes(
  processed_ratchet_key_hash_id INTEGER PRIMARY KEY,
  conn_id BLOB NOT NULL REFERENCES connections ON DELETE CASCADE,
  hash BLOB NOT NULL,
  created_at TEXT NOT NULL DEFAULT(datetime('now')),
  updated_at TEXT NOT NULL DEFAULT(datetime('now'))
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
