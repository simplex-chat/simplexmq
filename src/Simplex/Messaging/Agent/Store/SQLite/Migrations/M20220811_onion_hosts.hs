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

-- same servers as defined in Simplex.Messaging.Agent.Protocol, line 592

UPDATE servers
SET host = 'smp4.simplex.im,o5vmywmrnaxalvz6wi3zicyftgio6psuvyniis6gco6bp6ekl4cqj4id.onion'
WHERE host = 'smp4.simplex.im';

UPDATE servers
SET host = 'smp5.simplex.im,jjbyvoemxysm7qxap7m5d5m35jzv5qq6gnlv7s4rsn7tdwwmuqciwpid.onion'
WHERE host = 'smp5.simplex.im';

UPDATE servers
SET host = 'smp6.simplex.im,bylepyau3ty4czmn77q4fglvperknl4bi2eb2fdy2bh4jxtf32kf73yd.onion'
WHERE host = 'smp6.simplex.im';

UPDATE servers
SET host = 'smp8.simplex.im,beccx4yfxxbvyhqypaavemqurytl6hozr47wfc7uuecacjqdvwpw2xid.onion'
WHERE host = 'smp8.simplex.im';

UPDATE servers
SET host = 'smp9.simplex.im,jssqzccmrcws6bhmn77vgmhfjmhwlyr3u7puw4erkyoosywgl67slqqd.onion'
WHERE host = 'smp9.simplex.im';

UPDATE servers
SET host = 'smp10.simplex.im,rb2pbttocvnbrngnwziclp2f4ckjq65kebafws6g4hy22cdaiv5dwjqd.onion'
WHERE host = 'smp10.simplex.im';
|]
