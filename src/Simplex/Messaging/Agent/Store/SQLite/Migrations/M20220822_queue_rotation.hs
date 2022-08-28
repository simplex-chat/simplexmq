{-# LANGUAGE QuasiQuotes #-}

module Simplex.Messaging.Agent.Store.SQLite.Migrations.M20220822_queue_rotation where

import Database.SQLite.Simple (Query)
import Database.SQLite.Simple.QQ (sql)

m20220822_queue_rotation :: Query
m20220822_queue_rotation =
  [sql|
-- * rcv_queues

ALTER TABLE rcv_queues ADD COLUMN rcv_queue_id INTEGER NULL;
ALTER TABLE rcv_queues ADD COLUMN rcv_queue_action TEXT NULL;
ALTER TABLE rcv_queues ADD COLUMN rcv_queue_action_ts TEXT NULL;

ALTER TABLE rcv_queues ADD COLUMN curr_rcv_queue INTEGER CHECK (curr_rcv_queue NOT NULL);
UPDATE rcv_queues SET curr_rcv_queue = 1;

ALTER TABLE rcv_queues ADD COLUMN next_rcv_queue_id INTEGER NULL;
  -- REFERENCES rcv_queues (rcv_queue_id) ON DELETE SET NULL;
-- next_rcv_queue = 1: this is the new queue the connection is switching to
-- next_rcv_queue_id: the ID of the next queue

ALTER TABLE rcv_queues ADD COLUMN created_at TEXT CHECK (created_at NOT NULL);
UPDATE rcv_queues SET created_at = '1970-01-01 00:00:00';

ALTER TABLE rcv_queues ADD COLUMN updated_at TEXT CHECK (updated_at NOT NULL);
UPDATE rcv_queues SET updated_at = '1970-01-01 00:00:00';

CREATE UNIQUE INDEX idx_rcv_queue_id ON rcv_queues(rcv_queue_id);
CREATE UNIQUE INDEX idx_next_rcv_queue_id ON rcv_queues(next_rcv_queue_id);

-- * snd_queues

ALTER TABLE snd_queues ADD COLUMN snd_queue_id INTEGER NULL;
ALTER TABLE snd_queues ADD COLUMN snd_queue_action TEXT NULL;
ALTER TABLE snd_queues ADD COLUMN snd_queue_action_ts TEXT NULL;

ALTER TABLE snd_queues ADD COLUMN curr_snd_queue INTEGER CHECK (curr_snd_queue NOT NULL);
UPDATE snd_queues SET curr_snd_queue = 1;

ALTER TABLE snd_queues ADD COLUMN next_snd_queue_id INTEGER NULL;
  -- REFERENCES snd_queues (snd_queue_id) ON DELETE SET NULL;
-- next_snd_queue = 1: this is the new queue the connection is switching to
-- next_snd_queue_id: the ID of the next queue

ALTER TABLE snd_queues ADD COLUMN created_at TEXT CHECK (created_at NOT NULL);
UPDATE snd_queues SET created_at = '1970-01-01 00:00:00';

ALTER TABLE snd_queues ADD COLUMN updated_at TEXT CHECK (updated_at NOT NULL);
UPDATE snd_queues SET updated_at = '1970-01-01 00:00:00';

CREATE UNIQUE INDEX idx_snd_queue_id ON snd_queues(snd_queue_id);
CREATE UNIQUE INDEX idx_next_snd_queue_id ON snd_queues(next_snd_queue_id);
|]
