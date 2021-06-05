CREATE TABLE conn_intros (
  intro_id BLOB NOT NULL PRIMARY KEY,
  to_conn BLOB NOT NULL REFERENCES connections (conn_alias) ON DELETE SET NULL,
  to_info BLOB, -- info about "to" connection sent to "re" connection
  to_status TEXT NOT NULL DEFAULT '', -- '', INV, CON
  re_conn BLOB NOT NULL REFERENCES connections (conn_alias) ON DELETE SET NULL,
  re_info BLOB NOT NULL, -- info about "re" connection sent to "to" connection
  re_status TEXT NOT NULL DEFAULT '', -- '', INV, CON
  queue_info BLOB
) WITHOUT ROWID;

CREATE TABLE conn_invitations (
  inv_id BLOB NOT NULL PRIMARY KEY,
  via_conn BLOB REFERENCES connections (conn_alias) ON DELETE SET NULL,
  external_intro_id BLOB NOT NULL,
  conn_info BLOB, -- info about another connection
  queue_info BLOB, -- NULL if it's an initial introduction
  conn_id BLOB REFERENCES connections (conn_alias) -- created connection
    ON DELETE CASCADE
    DEFERRABLE INITIALLY DEFERRED,
  status TEXT DEFAULT '' -- '', 'ACPT', 'CON'
) WITHOUT ROWID;

ALTER TABLE connections
  ADD via_inv BLOB REFERENCES conn_invitations (inv_id) ON DELETE RESTRICT;
ALTER TABLE connections
  ADD conn_level INTEGER DEFAULT 0;
