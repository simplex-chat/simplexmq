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
  addConn :: s -> m (RecipientId, SenderId) -> RecipientKey -> m (Either ErrorType Connection)
  getConn :: s -> SParty (a :: Party) -> ConnId -> m (Either ErrorType Connection)
  secureConn :: s -> RecipientId -> SenderKey -> m (Either ErrorType ())
  suspendConn :: s -> RecipientId -> m (Either ErrorType ())
  deleteConn :: s -> RecipientId -> m (Either ErrorType ())

-- TODO stub
mkConnection :: (RecipientId, SenderId) -> RecipientKey -> Connection
mkConnection (recipientId, senderId) recipientKey =
  Connection
    { recipientId,
      senderId,
      recipientKey,
      senderKey = Nothing,
      status = ConnActive
    }
