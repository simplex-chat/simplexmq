{-# LANGUAGE DataKinds #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns #-}

module ConnStore where

import Transmission

data Connection = Connection
  { recipientId :: ConnId,
    senderId :: ConnId,
    recipientKey :: PublicKey,
    senderKey :: Maybe PublicKey,
    status :: ConnStatus
  }

data ConnStatus = ConnActive | ConnOff

class MonadConnStore s m where
  addConn :: s -> RecipientKey -> (RecipientId, SenderId) -> m (Either ErrorType ())
  getConn :: s -> SParty (a :: Party) -> ConnId -> m (Either ErrorType Connection)
  secureConn :: s -> RecipientId -> SenderKey -> m (Either ErrorType ())
  suspendConn :: s -> RecipientId -> m (Either ErrorType ())
  deleteConn :: s -> RecipientId -> m (Either ErrorType ())

-- TODO stub
mkConnection :: RecipientKey -> (RecipientId, SenderId) -> Connection
mkConnection recipientKey (recipientId, senderId) =
  Connection
    { recipientId,
      senderId,
      recipientKey,
      senderKey = Nothing,
      status = ConnActive
    }
