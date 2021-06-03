CREATE TABLE broadcasts (
  broadcast_id BLOB NOT NULL PRIMARY KEY
) WITHOUT ROWID;

CREATE TABLE broadcast_connections (
  broadcast_id BLOB NOT NULL REFERENCES broadcasts (broadcast_id) ON DELETE CASCADE,
  conn_alias BLOB NOT NULL REFERENCES connections (conn_alias),
  PRIMARY KEY (broadcast_id, conn_alias)
) WITHOUT ROWID;
