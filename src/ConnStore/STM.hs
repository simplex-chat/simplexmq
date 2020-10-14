{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE UndecidableInstances #-}

module ConnStore.STM where

import ConnStore
import Control.Monad.IO.Unlift
import Data.Map (Map)
import qualified Data.Map as M
import Transmission
import UnliftIO.STM

data ConnStoreData = ConnStoreData
  { connections :: Map RecipientId Connection,
    senders :: Map SenderId RecipientId
  }

type STMConnStore = TVar ConnStoreData

newConnStore :: STM STMConnStore
newConnStore = newTVar ConnStoreData {connections = M.empty, senders = M.empty}

instance MonadUnliftIO m => MonadConnStore STMConnStore m where
  createConn store rKey = atomically do
    db <- readTVar store
    let c@Connection {recipientId = rId, senderId = sId} = newConnection rKey
        db' =
          ConnStoreData
            { connections = M.insert rId c (connections db),
              senders = M.insert sId rId (senders db)
            }
    writeTVar store db'
    return $ Right c

  -- TODO do not return suspended connections
  getConn store SRecipient rId = atomically do
    db <- readTVar store
    return $ getRcpConn db rId
  getConn store SSender sId = atomically do
    db <- readTVar store
    return $ maybe (Left AUTH) (getRcpConn db) $ M.lookup sId $ senders db
  getConn _ SBroker _ = atomically do
    return $ Left INTERNAL

  secureConn store rId sKey = atomically do
    db <- readTVar store
    let conn = getRcpConn db rId
    either (return . Left) (updateConn db) conn
    where
      updateConn db c = case senderKey c of
        Just _ -> return $ Left AUTH
        Nothing -> do
          let db' = db {connections = M.insert rId c {senderKey = Just sKey} (connections db)}
          writeTVar store db'
          return $ Right ()

getRcpConn :: ConnStoreData -> RecipientId -> Either ErrorType Connection
getRcpConn db rId = maybe (Left AUTH) Right . M.lookup rId $ connections db
