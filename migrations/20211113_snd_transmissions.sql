CREATE TABLE agent_transmissions (
  agent_trn_id     INTEGER PRIMARY KEY,
  conn_alias       BLOB NOT NULL,
  agent_command    BLOB NOT NULL,
  internal_msg_id  INTEGER,
  status           INTEGER NOT NULL DEFAULT 0,
  FOREIGN KEY (conn_alias, internal_msg_id)
    REFERENCES messages (conn_alias, internal_id)
    ON DELETE CASCADE
);

CREATE TABLE smp_transmissions (
  smp_trn_id       INTEGER PRIMARY KEY,
  agent_trn_id     INTEGER REFERENCES agent_transmissions ON DELETE CASCADE,
  host             TEXT NOT NULL,
  port             TEXT NOT NULL,
  rcv_id           BLOB,
  snd_id           BLOB,
  smp_command      BLOB NOT NULL,
  sent             INTEGER NOT NULL DEFAULT 0,
  FOREIGN KEY (host, port) REFERENCES servers,
  FOREIGN KEY (host, port, rcv_id) REFERENCES rcv_queues ON DELETE CASCADE,
  FOREIGN KEY (host, port, snd_id) REFERENCES snd_queues ON DELETE CASCADE
);
