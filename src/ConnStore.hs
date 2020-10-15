{-# LANGUAGE DataKinds #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE MultiParamTypeClasses #-}

module ConnStore where

import Data.Singletons
import Transmission

data Connection = Connection
  { recipientId :: ConnId,
    recipientKey :: PublicKey,
    senderId :: ConnId,
    senderKey :: Maybe PublicKey,
    status :: ConnStatus
  }

data ConnStatus = ConnActive | ConnSuspended

class MonadConnStore s m where
  createConn :: s -> RecipientKey -> m (Either ErrorType Connection)
  getConn :: s -> Sing (a :: Party) -> ConnId -> m (Either ErrorType Connection)
  secureConn :: s -> RecipientId -> SenderKey -> m (Either ErrorType ())
  suspendConn :: s -> RecipientId -> m (Either ErrorType ())
  deleteConn :: s -> RecipientId -> m (Either ErrorType ())

-- TODO stub
newConnection :: RecipientKey -> Connection
newConnection rKey =
  Connection
    { recipientId = "1",
      recipientKey = rKey,
      senderId = "2",
      senderKey = Nothing,
      status = ConnActive
    }
