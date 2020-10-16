{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE UndecidableInstances #-}

module ConnStore.STM where

import ConnStore
import Control.Monad.IO.Unlift
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import Data.Singletons
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
  createConn :: STMConnStore -> RecipientKey -> m (Either ErrorType Connection)
  createConn store rKey = atomically $ do
    db <- readTVar store
    let c@Connection {recipientId = rId, senderId = sId} = newConnection rKey
        db' =
          db
            { connections = M.insert rId c (connections db),
              senders = M.insert sId rId (senders db)
            }
    writeTVar store db'
    return $ Right c

  getConn :: STMConnStore -> Sing (p :: Party) -> ConnId -> m (Either ErrorType Connection)
  getConn store SRecipient rId = atomically $ do
    db <- readTVar store
    return $ getRcpConn db rId
  getConn store SSender sId = atomically $ do
    db <- readTVar store
    let rId = M.lookup sId $ senders db
    return $ maybe (Left AUTH) (getRcpConn db) rId
  getConn _ SBroker _ =
    return $ Left INTERNAL

  secureConn store rId sKey = updateConnections store rId $ \db c ->
    case senderKey c of
      Just _ -> (Left AUTH, db)
      _ -> (Right (), db {connections = M.insert rId c {senderKey = Just sKey} (connections db)})

  suspendConn :: STMConnStore -> RecipientId -> m (Either ErrorType ())
  suspendConn store rId = updateConnections store rId $ \db c ->
    (Right (), db {connections = M.insert rId c {status = ConnOff} (connections db)})

  deleteConn :: STMConnStore -> RecipientId -> m (Either ErrorType ())
  deleteConn store rId = updateConnections store rId $ \db c ->
    ( Right (),
      db
        { connections = M.delete rId (connections db),
          senders = M.delete (senderId c) (senders db)
        }
    )

updateConnections ::
  MonadUnliftIO m =>
  STMConnStore ->
  RecipientId ->
  (ConnStoreData -> Connection -> (Either ErrorType (), ConnStoreData)) ->
  m (Either ErrorType ())
updateConnections store rId update = atomically $ do
  db <- readTVar store
  let conn = getRcpConn db rId
  either (return . Left) (_update db) conn
  where
    _update db c = do
      let (res, db') = update db c
      writeTVar store db'
      return res

getRcpConn :: ConnStoreData -> RecipientId -> Either ErrorType Connection
getRcpConn db rId = maybe (Left AUTH) Right . M.lookup rId $ connections db
