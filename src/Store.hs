{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
-- {-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}

module Store where

import Control.Concurrent.STM
import Data.Map (Map)
import qualified Data.Map as M
import Polysemy
import Polysemy.Input
import Transmission

type SMPResult a = Either SMPError a

data SMPError = CmdError | SyntaxError | AuthError | InternalError

data Connection = Connection
  { recipientId :: ConnId,
    recipientKey :: PublicKey,
    senderId :: ConnId,
    senderKey :: Maybe PublicKey,
    active :: Bool
  }

data ConnStore m a where
  CreateConn :: RecipientKey -> ConnStore m (SMPResult Connection)
  GetConn :: Party -> ConnId -> ConnStore m (SMPResult Connection)

-- SecureConn :: RecipientId -> SenderKey -> ConnStore m (SMPResult ())
-- SuspendConn :: RecipientId -> ConnStore m (SMPResult ())
-- DeleteConn :: RecipientId -> ConnStore m (SMPResult ())

makeSem ''ConnStore

data ConnStoreData = ConnStoreData
  { connections :: Map RecipientId Connection,
    senders :: Map SenderId RecipientId
  }

newConnStore :: STM (TVar ConnStoreData)
newConnStore = newTVar ConnStoreData {connections = M.empty, senders = M.empty}

newConnection :: RecipientKey -> Connection
newConnection rKey =
  Connection
    { recipientId = "1",
      recipientKey = rKey,
      senderId = "2",
      senderKey = Nothing,
      active = True
    }

runConnStoreSTM :: Member (Embed STM) r => Sem (ConnStore ': r) a -> Sem (Input (TVar ConnStoreData) ': r) a
runConnStoreSTM = reinterpret $ \case
  CreateConn rKey -> do
    store <- input
    db <- embed $ readTVar store
    let conn@Connection {senderId, recipientId} = newConnection rKey
        db' =
          ConnStoreData
            { connections = M.insert recipientId conn (connections db),
              senders = M.insert senderId recipientId (senders db)
            }
    embed $ writeTVar store db'
    return $ Right conn
  GetConn Recipient rId -> do
    db <- input >>= embed . readTVar
    return $ getConn db rId
  GetConn Sender sId -> do
    db <- input >>= embed . readTVar
    return $ maybeError (getConn db) $ M.lookup sId $ senders db
  GetConn Broker _ -> do
    return $ Left InternalError
  where
    maybeError = maybe (Left AuthError)
    getConn db rId = maybeError Right $ M.lookup rId $ connections db
