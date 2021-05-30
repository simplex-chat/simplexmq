CREATE TABLE IF NOT EXISTS broadcasts (
  broadcast_id BLOB NOT NULL,
  PRIMARY KEY (broadcast_id)
) WITHOUT ROWID;

CREATE TABLE IF NOT EXISTS broadcast_connections (
  broadcast_id BLOB NOT NULL REFERENCES broadcasts (broadcast_id),
  conn_alias BLOB NOT NULL REFERENCES connections (conn_alias),
  PRIMARY KEY (broadcast_id, conn_alias)
) WITHOUT ROWID;