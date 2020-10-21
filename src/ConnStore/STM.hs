{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE UndecidableInstances #-}

module ConnStore.STM where

import ConnStore
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import Transmission
import UnliftIO.STM

data ConnStoreData = ConnStoreData
  { connections :: Map RecipientId Connection,
    senders :: Map SenderId RecipientId
  }

type ConnStore = TVar ConnStoreData

newConnStore :: STM ConnStore
newConnStore = newTVar ConnStoreData {connections = M.empty, senders = M.empty}

instance MonadConnStore ConnStore STM where
  addConn :: ConnStore -> RecipientKey -> (RecipientId, SenderId) -> STM (Either ErrorType ())
  addConn store rKey ids@(rId, sId) = do
    cs@ConnStoreData {connections, senders} <- readTVar store
    if M.member rId connections || M.member sId senders
      then return $ Left DUPLICATE
      else do
        writeTVar store $
          cs
            { connections = M.insert rId (mkConnection rKey ids) connections,
              senders = M.insert sId rId senders
            }
        return $ Right ()

  getConn :: ConnStore -> SParty (p :: Party) -> ConnId -> STM (Either ErrorType Connection)
  getConn store SRecipient rId = do
    cs <- readTVar store
    return $ getRcpConn cs rId
  getConn store SSender sId = do
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

  suspendConn :: ConnStore -> RecipientId -> STM (Either ErrorType ())
  suspendConn store rId =
    updateConnections store rId $ \cs c ->
      (Right (), cs {connections = M.insert rId c {status = ConnOff} (connections cs)})

  deleteConn :: ConnStore -> RecipientId -> STM (Either ErrorType ())
  deleteConn store rId =
    updateConnections store rId $ \cs c ->
      ( Right (),
        cs
          { connections = M.delete rId (connections cs),
            senders = M.delete (senderId c) (senders cs)
          }
      )

updateConnections ::
  ConnStore ->
  RecipientId ->
  (ConnStoreData -> Connection -> (Either ErrorType (), ConnStoreData)) ->
  STM (Either ErrorType ())
updateConnections store rId update = do
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
