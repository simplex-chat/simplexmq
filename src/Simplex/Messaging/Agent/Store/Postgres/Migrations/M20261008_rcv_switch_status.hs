{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}

module Simplex.Messaging.Agent.Store.Postgres.Migrations.M20261008_rcv_switch_status where

import Data.Text (Text)
import Text.RawString.QQ (r)

m20261008_rcv_switch_status :: Text
m20261008_rcv_switch_status =
  [r|
CREATE INDEX idx_rcv_queues_switch_status ON rcv_queues(switch_status);
|]

down_m20261008_rcv_switch_status :: Text
down_m20261008_rcv_switch_status =
  [r|
UPDATE rcv_queues SET switch_status = NULL WHERE switch_status = 'received_qend';
DROP INDEX idx_rcv_queues_switch_status;
|]
