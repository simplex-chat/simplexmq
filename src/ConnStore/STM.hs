{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns #-}
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
  createConn store rKey = atomically $ do
    db <- readTVar store
    let conn@Connection {senderId, recipientId} = newConnection rKey
        db' =
          ConnStoreData
            { connections = M.insert recipientId conn (connections db),
              senders = M.insert senderId recipientId (senders db)
            }
    writeTVar store db'
    return $ Right conn
  getConn store SRecipient rId = atomically $ do
    db <- readTVar store
    return $ getRcpConn db rId
  getConn store SSender sId = atomically $ do
    db <- readTVar store
    return $ maybeAuth (getRcpConn db) $ M.lookup sId $ senders db
  getConn _ SBroker _ = atomically $ do
    return $ Left INTERNAL

maybeAuth :: (a -> Either ErrorType b) -> Maybe a -> Either ErrorType b
maybeAuth = maybe (Left AUTH)

getRcpConn :: ConnStoreData -> RecipientId -> Either ErrorType Connection
getRcpConn db rId = maybeAuth Right $ M.lookup rId $ connections db
