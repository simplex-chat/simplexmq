CREATE TABLE messages (
  message_id INTEGER PRIMARY KEY, -- new field
  ------------------------------
  conn_alias BLOB NOT NULL REFERENCES connections (conn_alias)
    ON DELETE CASCADE,
  internal_id INTEGER, -- NOT NULL, ---- NULL for control messages
  internal_ts TEXT NOT NULL,
  internal_rcv_id INTEGER,
  internal_snd_id INTEGER,
  msg_ctrl BLOB, ---- new field, NULL for user messages, the same single-letter value as on the wire: (H)ELLO, (R)EPLY, (D)ELETE
  --------------------
  -- msg_type BLOB, ---- this field is replaced with msg_ctrl
  msg_body BLOB NOT NULL DEFAULT x'', ---- control messages still need bodies, as they are encrypted and padded here with double ratchet
  -- PRIMARY KEY (conn_alias, internal_id), ---- now the key is message_id
  FOREIGN KEY (conn_alias, internal_rcv_id) REFERENCES rcv_messages
    ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY (conn_alias, internal_snd_id) REFERENCES snd_messages
    ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED
); -- it is now ROWID table
-- WITHOUT ROWID;

CREATE TABLE rcv_messages (
  conn_alias BLOB NOT NULL,
  internal_rcv_id INTEGER NOT NULL,
  -- internal_id INTEGER NOT NULL, ---- replaced with message_id
  message_id INTEGER NOT NULL REFERENCES messages -- new field
    ON DELETE CASCADE,
  -----------------------------------------------
  external_snd_id INTEGER NOT NULL,
  broker_id BLOB NOT NULL,
  broker_ts TEXT NOT NULL,
  rcv_status TEXT NOT NULL,
  ack_brocker_ts TEXT,
  internal_hash BLOB NOT NULL,
  external_prev_snd_hash BLOB NOT NULL,
  integrity BLOB NOT NULL,
  PRIMARY KEY (conn_alias, internal_rcv_id)
--   FOREIGN KEY (conn_alias, internal_id) REFERENCES messages
--     ON DELETE CASCADE
) WITHOUT ROWID;

CREATE TABLE snd_messages (
  conn_alias BLOB NOT NULL,
  internal_snd_id INTEGER NOT NULL,
  -- internal_id INTEGER NOT NULL, ---- replaced with message_id
  message_id INTEGER NOT NULL REFERENCES messages -- new field
    ON DELETE CASCADE,
  -----------------------------------------------
  snd_status TEXT NOT NULL,
  sent_ts TEXT,
  internal_hash BLOB NOT NULL,
  previous_msg_hash BLOB NOT NULL DEFAULT x'',
  PRIMARY KEY (conn_alias, internal_snd_id)
--   FOREIGN KEY (conn_alias, internal_id) REFERENCES messages
--     ON DELETE CASCADE
) WITHOUT ROWID;
