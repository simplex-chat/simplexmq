CREATE TABLE IF NOT EXISTS servers(
  host TEXT NOT NULL,
  port TEXT NOT NULL,
  key_hash BLOB,
  PRIMARY KEY (host, port)
) WITHOUT ROWID;

CREATE TABLE IF NOT EXISTS rcv_queues(
  host TEXT NOT NULL,
  port TEXT NOT NULL,
  rcv_id BLOB NOT NULL,
  conn_alias BLOB NOT NULL,
  rcv_private_key BLOB NOT NULL,
  e2e_priv_key BLOB NOT NULL,
  e2e_snd_pub_key BLOB,
  e2e_dh_secret BLOB,
  snd_id BLOB NOT NULL,
  snd_key BLOB,
  status TEXT NOT NULL,
  PRIMARY KEY (host, port, rcv_id),
  FOREIGN KEY (host, port) REFERENCES servers (host, port),
  FOREIGN KEY (conn_alias)
    REFERENCES connections (conn_alias)
    ON DELETE CASCADE
    DEFERRABLE INITIALLY DEFERRED,
  UNIQUE (host, port, snd_id)
) WITHOUT ROWID;

CREATE TABLE IF NOT EXISTS snd_queues(
  host TEXT NOT NULL,
  port TEXT NOT NULL,
  snd_id BLOB NOT NULL,
  conn_alias BLOB NOT NULL,
  snd_private_key BLOB NOT NULL,
  e2e_pub_key BLOB NOT NULL,
  e2e_dh_secret BLOB NOT NULL,
  status TEXT NOT NULL,
  PRIMARY KEY (host, port, snd_id),
  FOREIGN KEY (host, port) REFERENCES servers (host, port),
  FOREIGN KEY (conn_alias)
    REFERENCES connections (conn_alias)
    ON DELETE CASCADE
    DEFERRABLE INITIALLY DEFERRED
) WITHOUT ROWID;

CREATE TABLE IF NOT EXISTS connections(
  conn_alias BLOB NOT NULL,
  rcv_host TEXT,
  rcv_port TEXT,
  rcv_id BLOB,
  snd_host TEXT,
  snd_port TEXT,
  snd_id BLOB,
  last_internal_msg_id INTEGER NOT NULL, -- TODO add defauls here and below in the new schema
  last_internal_rcv_msg_id INTEGER NOT NULL,
  last_internal_snd_msg_id INTEGER NOT NULL,
  last_external_snd_msg_id INTEGER NOT NULL,
  last_rcv_msg_hash BLOB NOT NULL,
  last_snd_msg_hash BLOB NOT NULL,
  PRIMARY KEY (conn_alias),
  FOREIGN KEY (rcv_host, rcv_port, rcv_id) REFERENCES rcv_queues (host, port, rcv_id),
  FOREIGN KEY (snd_host, snd_port, snd_id) REFERENCES snd_queues (host, port, snd_id)
) WITHOUT ROWID;

CREATE TABLE IF NOT EXISTS messages(
  conn_alias BLOB NOT NULL,
  internal_id INTEGER NOT NULL,
  internal_ts TEXT NOT NULL,
  internal_rcv_id INTEGER,
  internal_snd_id INTEGER,
  body TEXT NOT NULL,  -- deprecated
  PRIMARY KEY (conn_alias, internal_id),
  FOREIGN KEY (conn_alias)
    REFERENCES connections (conn_alias)
    ON DELETE CASCADE,
  FOREIGN KEY (conn_alias, internal_rcv_id)
    REFERENCES rcv_messages (conn_alias, internal_rcv_id)
    ON DELETE CASCADE
    DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY (conn_alias, internal_snd_id)
    REFERENCES snd_messages (conn_alias, internal_snd_id)
    ON DELETE CASCADE
    DEFERRABLE INITIALLY DEFERRED
) WITHOUT ROWID;

CREATE TABLE IF NOT EXISTS rcv_messages(
  conn_alias BLOB NOT NULL,
  internal_rcv_id INTEGER NOT NULL,
  internal_id INTEGER NOT NULL,
  external_snd_id INTEGER NOT NULL,
  broker_id BLOB NOT NULL,
  broker_ts TEXT NOT NULL,
  rcv_status TEXT NOT NULL,
  ack_brocker_ts TEXT,
  ack_sender_ts TEXT,
  internal_hash BLOB NOT NULL,
  external_prev_snd_hash BLOB NOT NULL,
  integrity BLOB NOT NULL,
  PRIMARY KEY (conn_alias, internal_rcv_id),
  FOREIGN KEY (conn_alias, internal_id)
    REFERENCES messages (conn_alias, internal_id)
    ON DELETE CASCADE
) WITHOUT ROWID;

CREATE TABLE IF NOT EXISTS snd_messages(
  conn_alias BLOB NOT NULL,
  internal_snd_id INTEGER NOT NULL,
  internal_id INTEGER NOT NULL,
  snd_status TEXT NOT NULL,
  sent_ts TEXT,
  delivered_ts TEXT,
  internal_hash BLOB NOT NULL,
  PRIMARY KEY (conn_alias, internal_snd_id),
  FOREIGN KEY (conn_alias, internal_id)
    REFERENCES messages (conn_alias, internal_id)
    ON DELETE CASCADE
) WITHOUT ROWID;
