{-# LANGUAGE QuasiQuotes #-}

module Simplex.Messaging.Agent.Store.SQLite.Migrations.M20220811_onion_hosts where

import Database.SQLite.Simple (Query)
import Database.SQLite.Simple.QQ (sql)

m20220811_onion_hosts :: Query
m20220811_onion_hosts =
  [sql|
ALTER TABLE conn_confirmations ADD COLUMN smp_client_version INTEGER;

UPDATE ntf_servers
SET ntf_host = 'ntf2.simplex.im,ntg7jdjy2i3qbib3sykiho3enekwiaqg3icctliqhtqcg6jmoh6cxiad.onion'
WHERE ntf_host = 'ntf2.simplex.im';
|]
