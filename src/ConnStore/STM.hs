{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE UndecidableInstances #-}

module ConnStore.STM where

import ConnStore
import Control.Monad.IO.Unlift
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
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
  addConn :: STMConnStore -> m (RecipientId, SenderId) -> RecipientKey -> m (Either ErrorType Connection)
  addConn = _addConn (3 :: Int)
    where
      _addConn 0 _ _ _ = return $ Left INTERNAL
      _addConn retry store getIds rKey = do
        getIds >>= atomically . insertConn >>= \case
          Nothing -> _addConn (retry - 1) store getIds rKey
          Just c -> return $ Right c
        where
          insertConn ids@(rId, sId) = do
            cs@ConnStoreData {connections, senders} <- readTVar store
            if M.member rId connections || M.member sId senders
              then return Nothing
              else do
                let c = mkConnection ids rKey
                writeTVar store $
                  cs
                    { connections = M.insert rId c connections,
                      senders = M.insert sId rId senders
                    }
                return $ Just c

  getConn :: STMConnStore -> SParty (p :: Party) -> ConnId -> m (Either ErrorType Connection)
  getConn store SRecipient rId = atomically $ do
    cs <- readTVar store
    return $ getRcpConn cs rId
  getConn store SSender sId = atomically $ do
    cs <- readTVar store
    let rId = M.lookup sId $ senders cs
    return $ maybe (Left AUTH) (getRcpConn cs) rId
  getConn _ SBroker _ =
    return $ Left INTERNAL

  secureConn store rId sKey =
    updateConnections store rId $ \cs c ->
      case senderKey c of
        Just _ -> (Left AUTH, cs)
        _ -> (Right (), cs {connections = M.insert rId c {senderKey = Just sKey} (connections cs)})

  suspendConn :: STMConnStore -> RecipientId -> m (Either ErrorType ())
  suspendConn store rId =
    updateConnections store rId $ \cs c ->
      (Right (), cs {connections = M.insert rId c {status = ConnOff} (connections cs)})

  deleteConn :: STMConnStore -> RecipientId -> m (Either ErrorType ())
  deleteConn store rId =
    updateConnections store rId $ \cs c ->
      ( Right (),
        cs
          { connections = M.delete rId (connections cs),
            senders = M.delete (senderId c) (senders cs)
          }
      )

updateConnections ::
  MonadUnliftIO m =>
  STMConnStore ->
  RecipientId ->
  (ConnStoreData -> Connection -> (Either ErrorType (), ConnStoreData)) ->
  m (Either ErrorType ())
updateConnections store rId update = atomically $ do
  cs <- readTVar store
  let conn = getRcpConn cs rId
  either (return . Left) (_update cs) conn
  where
    _update cs c = do
      let (res, cs') = update cs c
      writeTVar store cs'
      return res

getRcpConn :: ConnStoreData -> RecipientId -> Either ErrorType Connection
getRcpConn cs rId = maybe (Left AUTH) Right . M.lookup rId $ connections cs
