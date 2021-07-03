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

-- remove snd_key from rcv_queues
CREATE TEMPORARY TABLE rcv_queues_backup(host,port,rcv_id,conn_alias,rcv_private_key,snd_id,decrypt_key,verify_key,status);
INSERT INTO rcv_queues_backup SELECT host,port,rcv_id,conn_alias,rcv_private_key,snd_id,decrypt_key,verify_key,status FROM rcv_queues;
DROP TABLE rcv_queues;
CREATE TABLE rcv_queues(
  host TEXT NOT NULL,
  port TEXT NOT NULL,
  rcv_id BLOB NOT NULL,
  conn_alias BLOB NOT NULL,
  rcv_private_key BLOB NOT NULL,
  snd_id BLOB,
  decrypt_key BLOB NOT NULL,
  verify_key BLOB,
  status TEXT NOT NULL,
  PRIMARY KEY (host, port, rcv_id),
  FOREIGN KEY (host, port) REFERENCES servers (host, port),
  FOREIGN KEY (conn_alias)
    REFERENCES connections (conn_alias)
    ON DELETE CASCADE
    DEFERRABLE INITIALLY DEFERRED,
  UNIQUE (host, port, snd_id)
) WITHOUT ROWID;
INSERT INTO rcv_queues SELECT host,port,rcv_id,conn_alias,rcv_private_key,snd_id,decrypt_key,verify_key,status FROM rcv_queues_backup;
DROP TABLE rcv_queues_backup;
