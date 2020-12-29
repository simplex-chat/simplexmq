module Simplex.Messaging.Agent.Store.SQLite where

import qualified Database.SQLite.Simple as DB

-- instance MonadUnliftIO m => MonadQueueStore DB.Connection m where
--   createRcvConn :: DB.Connection -> Maybe ConnAlias -> ReceiveQueue -> m (Either StoreError (Connection CReceive))
--   createRcvConn conn connAlias q = do
--     id <- query conn "INSERT ..."
--     query conn "INSERT ..."



-- sqlite queries to create server, queue and connection

-- *** step 1 - insert server before create request to server
-- ! "INSERT OR REPLACE INTO" with autoincrement apparently would change id,
-- ! so going with "ON CONFLICT UPDATE" here

-- INSERT INTO servers (host_address, port, key_hash)
-- VALUES ({host_address}, {port}, {key_hash})
-- ON CONFLICT(host_address, port) DO UPDATE SET
--   host_address=excluded.host_address,
--   port=excluded.port,
--   key_hash=excluded.key_hash;

-- *** step 2 - insert queue and connection after server's response
-- BEGIN TRANSACTION;

-- INSERT INTO recipient_queues (
--   server_id,
--   rcv_id,
--   rcv_private_key,
--   snd_id,
--   snd_key,
--   decrypt_key,
--   verify_key,
--   status,
--   ack_mode
-- )
-- VALUES (
--   {server_id},
--   {rcv_id},
--   {rcv_private_key},
--   {snd_id},
--   {snd_key},
--   {decrypt_key},
--   {verify_key},
--   {status},
--   {ack_mode}
-- );

-- INSERT INTO connections (
--   conn_alias,
--   recipient_queue_id,
--   sender_queue_id
-- )
-- VALUES (
--   {conn_alias},
--   {recipient_queue_id},
--   {sender_queue_id}
-- );

-- COMMIT;
-- ***
