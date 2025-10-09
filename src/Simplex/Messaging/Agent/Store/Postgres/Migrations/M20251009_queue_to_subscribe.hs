{-# LANGUAGE QuasiQuotes #-}

module Simplex.Messaging.Agent.Store.Postgres.Migrations.M20251009_queue_to_subscribe where

import Data.Text (Text)
import qualified Data.Text as T
import Text.RawString.QQ (r)

m20251009_queue_to_subscribe :: Text
m20251009_queue_to_subscribe =
  T.pack
    [r|
ALTER TABLE rcv_queues ADD COLUMN to_subscribe SMALLINT NOT NULL DEFAULT 0;
CREATE INDEX idx_rcv_queues_to_subscribe ON rcv_queues(to_subscribe);
|]

down_m20251009_queue_to_subscribe :: Text
down_m20251009_queue_to_subscribe =
  T.pack
    [r|
DROP INDEX idx_rcv_queues_to_subscribe;
ALTER TABLE rcv_queues DROP COLUMN to_subscribe;
|]
