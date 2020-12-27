{-# LANGUAGE ScopedTypeVariables #-}

module Simplex.Messaging.Agent.Store.SQLite.Schema where

import Control.Monad.IO.Unlift
import qualified Data.Text as T
import Database.SQLite.Simple

createSchema :: MonadUnliftIO m => Connection -> m ()
createSchema conn = do
  sql "recipient_queues"
  -- sql "sender_queues"
  -- sql "connections"
  -- sql "messages"
  return ()
  where
    sql name = liftIO $ do
      q <- readFile $ "./src/Simplex/Messaging/Agent/Store/SQLite/sql/" <> name <> ".sql"
      putStrLn q
      execute_ conn . Query . T.pack $ q
