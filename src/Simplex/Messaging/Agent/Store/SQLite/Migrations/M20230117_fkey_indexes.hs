{-# LANGUAGE QuasiQuotes #-}

module Simplex.Messaging.Agent.Store.SQLite.Migrations.M20230117_fkey_indexes where

import Database.SQLite.Simple (Query)
import Database.SQLite.Simple.QQ (sql)

-- .lint fkey-indexes
m20230117_fkey_indexes :: Query
m20230117_fkey_indexes =
  [sql|
CREATE INDEX idx_commands_host_port ON commands(host, port);
CREATE INDEX idx_conn_confirmations_conn_id ON conn_confirmations(conn_id);
CREATE INDEX idx_conn_invitations_contact_conn_id ON conn_invitations(contact_conn_id);
CREATE INDEX idx_messages_conn_id_internal_snd_id ON messages(conn_id, internal_snd_id);
CREATE INDEX idx_messages_conn_id_internal_rcv_id ON messages(conn_id, internal_rcv_id);
CREATE INDEX idx_messages_conn_id ON messages(conn_id);
CREATE INDEX idx_ntf_subscriptions_ntf_host_ntf_port ON ntf_subscriptions(ntf_host, ntf_port);
CREATE INDEX idx_ntf_subscriptions_smp_host_smp_port ON ntf_subscriptions(smp_host, smp_port);
CREATE INDEX idx_ntf_tokens_ntf_host_ntf_port ON ntf_tokens(ntf_host, ntf_port);
CREATE INDEX idx_ratchets_conn_id ON ratchets(conn_id);
CREATE INDEX idx_rcv_messages_conn_id_internal_id ON rcv_messages(conn_id, internal_id);
CREATE INDEX idx_skipped_messages_conn_id ON skipped_messages(conn_id);
CREATE INDEX idx_snd_message_deliveries_conn_id_internal_id ON snd_message_deliveries(conn_id, internal_id);
CREATE INDEX idx_snd_messages_conn_id_internal_id ON snd_messages(conn_id, internal_id);
CREATE INDEX idx_snd_queues_host_port ON snd_queues(host, port);
|]
