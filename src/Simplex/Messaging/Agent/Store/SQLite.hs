module Simplex.Messaging.Agent.Store.SQLite where

import qualified Database.SQLite.Simple as DB

-- instance MonadUnliftIO m => MonadQueueStore DB.Connection m where
--   createRcvConn :: DB.Connection -> Maybe ConnAlias -> ReceiveQueue -> m (Either StoreError (Connection CReceive))
--   createRcvConn conn connAlias q = do
--     id <- query conn "INSERT ..."
--     query conn "INSERT ..."
