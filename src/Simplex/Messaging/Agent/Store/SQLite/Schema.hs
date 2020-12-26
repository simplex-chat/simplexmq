{-# LANGUAGE ScopedTypeVariables #-}

module Simplex.Messaging.Agent.Store.SQLite.Schema where

import Control.Monad.IO.Unlift
import Database.SQLite.Simple

createSchema :: MonadUnliftIO m => Connection -> m ()
createSchema conn = do
  sql "recipient_queues"
  sql "sender_queues"
  sql "connections"
  sql "messages"
  where
    sql name = return ()
