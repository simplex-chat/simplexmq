CREATE TABLE migrations(
  name TEXT NOT NULL,
  ts TEXT NOT NULL,
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
  duplex_handshake INTEGER NULL DEFAULT 0
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
  PRIMARY KEY(conn_id, internal_snd_id),
  FOREIGN KEY(conn_id, internal_id) REFERENCES messages
  ON DELETE CASCADE
) WITHOUT ROWID;
CREATE TABLE conn_confirmations(
  confirmation_id BLOB NOT NULL PRIMARY KEY,
  conn_id BLOB NOT NULL REFERENCES connections ON DELETE CASCADE,
  e2e_snd_pub_key BLOB NOT NULL, -- TODO per-queue key. Split?
  sender_key BLOB NOT NULL, -- TODO per-queue key. Split?
  ratchet_state BLOB NOT NULL,
  sender_conn_info BLOB NOT NULL,
  accepted INTEGER NOT NULL,
  own_conn_info BLOB,
  created_at TEXT NOT NULL DEFAULT(datetime('now'))
  ,
  smp_reply_queues BLOB NULL
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
  provider TEXT NOT NULL, -- apn
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
  updated_at TEXT NOT NULL DEFAULT(datetime('now')), -- this is to check token status periodically to know when it was last checked
  PRIMARY KEY(provider, device_token, ntf_host, ntf_port),
  FOREIGN KEY(ntf_host, ntf_port) REFERENCES ntf_servers
  ON DELETE RESTRICT ON UPDATE CASCADE
) WITHOUT ROWID;
CREATE UNIQUE INDEX idx_rcv_queues_ntf ON rcv_queues(host, port, ntf_id);
CREATE TABLE ntf_subscriptions(
  conn_id BLOB NOT NULL, -- ? make nullable for when connection is deleted but we still need to delete subscription
  smp_host TEXT NULL,
  smp_port TEXT NULL,
  smp_ntf_id BLOB,
  ntf_host TEXT NOT NULL,
  ntf_port TEXT NOT NULL,
  ntf_sub_id BLOB,
  ntf_sub_status TEXT NOT NULL, -- see NtfAgentSubStatus
  ntf_sub_action TEXT, -- if there is an action required on this subscription: NtfSubAction
  ntf_sub_smp_action TEXT, -- action with SMP server: NtfSubSMPAction; only one of this and ntf_sub_action can(should) be not null in same record
  ntf_sub_action_ts TEXT, -- the earliest time for the action, e.g. checks can be scheduled every X hours
  updated_by_supervisor INTEGER NOT NULL DEFAULT 0, -- to be checked on updates by workers to not overwrite supervisor command(state still should be updated)
  created_at TEXT NOT NULL DEFAULT(datetime('now')),
  updated_at TEXT NOT NULL DEFAULT(datetime('now')),
  PRIMARY KEY(conn_id),
  -- FOREIGN KEY(conn_id) REFERENCES connections
  -- ON DELETE SET NULL ON UPDATE CASCADE,
  FOREIGN KEY(smp_host, smp_port) REFERENCES servers(host, port)
  ON DELETE SET NULL ON UPDATE CASCADE,
  FOREIGN KEY(ntf_host, ntf_port) REFERENCES ntf_servers
  ON DELETE RESTRICT ON UPDATE CASCADE
) WITHOUT ROWID;
