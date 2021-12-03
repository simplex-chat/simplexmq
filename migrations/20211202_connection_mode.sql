ALTER TABLE connections ADD conn_mode TEXT NOT NULL DEFAULT 'INV';

CREATE TABLE conn_invitations (
  invitation_id BLOB NOT NULL PRIMARY KEY,
  contact_conn_id BLOB NOT NULL REFERENCES connections ON DELETE CASCADE,
  cr_invitation BLOB NOT NULL,
  recipient_conn_info BLOB NOT NULL,
  accepted INTEGER NOT NULL DEFAULT 0,
  own_conn_info BLOB,
  created_at TEXT NOT NULL DEFAULT (datetime('now'))
) WITHOUT ROWID;
