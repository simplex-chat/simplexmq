{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE UndecidableInstances #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

module Simplex.Messaging.Agent.Store.SQLite.Types where

import Data.Int (Int64)
import qualified Database.SQLite.Simple as DB
import UnliftIO.STM

data SQLiteStore = SQLiteStore
  { dbFilename :: String,
    conn :: DB.Connection,
    serversLock :: TMVar (),
    rcvQueuesLock :: TMVar (),
    sndQueuesLock :: TMVar (),
    connectionsLock :: TMVar (),
    messagesLock :: TMVar ()
  }

type QueueRowId = Int64

type ConnectionRowId = Int64
