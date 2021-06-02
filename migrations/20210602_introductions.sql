CREATE TABLE IF NOT EXISTS conn_intros (
  intro_id BLOB NOT NULL PRIMARY KEY,
  to_conn BLOB REFERENCES connections (conn_alias) ON DELETE SET NULL,
  to_info BLOB, -- info about "to" connection sent to "re" connection
  to_status TEXT, -- '', INTRO, INV, CON
  re_conn BLOB REFERENCES connections (conn_alias) ON DELETE SET NULL,
  re_info BLOB, -- info about "re" connection sent to "to" connection
  re_status TEXT -- '', REQ, CON
) WITHOUT ROWID;

CREATE TABLE IF NOT EXISTS conn_invitations (
  inv_id BLOB NOT NULL PRIMARY KEY,
  via_conn BLOB REFERENCES connections (conn_alias) ON DELETE SET NULL,
  ext_intro_id BLOB NOT NULL,
  conn_info BLOB, -- info about another connection
  conn_alias BLOB REFERENCES connections (conn_alias) -- created connection
    ON DELETE CASCADE
    DEFERRABLE INITIALLY DEFERRED,
  invitation TEXT -- NULL if it's an initial introduction
  status TEXT -- '', 'ACPT', 'CON'
) WITHOUT ROWID;

ALTER TABLE connections
  ADD via_inv INTEGER REFERENCES conn_invitations (inv_id) ON DELETE RESTRICT;
ALTER TABLE connections
  ADD conn_level INTEGER DEFAULT 0;
