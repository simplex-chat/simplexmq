CREATE TABLE conn_confirmations (
  confirmation_id BLOB NOT NULL PRIMARY KEY,
  conn_alias BLOB NOT NULL REFERENCES connections ON DELETE CASCADE,
  e2e_snd_pub_key BLOB NOT NULL,
  sender_key BLOB NOT NULL,
  sender_conn_info BLOB NOT NULL,
  accepted INTEGER NOT NULL,
  own_conn_info BLOB,
  created_at TEXT NOT NULL DEFAULT (datetime('now'))
) WITHOUT ROWID;
