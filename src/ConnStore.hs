{-# LANGUAGE DataKinds #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE MultiParamTypeClasses #-}

module ConnStore where

import Data.Singletons
import Transmission

type SMPResult a = Either ErrorType a

data Connection = Connection
  { recipientId :: ConnId,
    recipientKey :: PublicKey,
    senderId :: ConnId,
    senderKey :: Maybe PublicKey,
    active :: Bool
  }

class MonadConnStore s m where
  createConn :: s -> RecipientKey -> m (SMPResult Connection)
  getConn :: s -> Sing (a :: Party) -> ConnId -> m (SMPResult Connection)

-- secureConn :: RecipientId -> SenderKey -> m (SMPResult ())
-- suspendConn :: RecipientId -> m (SMPResult ())
-- deleteConn :: RecipientId -> m (SMPResult ())

newConnection :: RecipientKey -> Connection
newConnection rKey =
  Connection
    { recipientId = "1",
      recipientKey = rKey,
      senderId = "2",
      senderKey = Nothing,
      active = True
    }
