CREATE TABLE conn_confirmations (
  confirmation_id BLOB NOT NULL,
  conn_alias BLOB NOT NULL,
  sender_key BLOB NOT NULL,
  sender_conn_info BLOB NOT NULL,
  approved INTEGER NOT NULL,
  own_conn_info BLOB,
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  PRIMARY KEY (confirmation_id),
  FOREIGN KEY (conn_alias)
    REFERENCES connections (conn_alias)
    ON DELETE CASCADE
) WITHOUT ROWID;
