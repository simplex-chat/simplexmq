{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE UndecidableInstances #-}
{-# OPTIONS_GHC -Wno-unrecognised-pragmas #-}
{-# HLINT ignore "Use lambda-case" #-}

module Simplex.FileTransfer.Server.Store where

import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Protocol hiding (SParty, SRecipient, SSender)
import Control.Monad
import Data.Functor (($>))
import Simplex.Messaging.TMap (TMap)
import qualified Simplex.Messaging.TMap as TM
import Simplex.Messaging.Util (ifM, ($>>=))
import UnliftIO.STM
import Simplex.FileTransfer.Protocol (SFileParty (..))
import Data.List.NonEmpty (NonEmpty)
import Data.Aeson.KeyMap (mapMaybe)
import Data.Maybe (fromMaybe)
import Data.Set (Set)
import qualified Data.Set as Set

data FileStore = FileStore
  { chunks :: TMap SenderId FileRec,
    recipients :: TMap RecipientId (SenderId, RcvPublicVerifyKey)
  }

data FileRec = FileRec
  { senderId :: SenderId,
    senderKey :: SndPublicVerifyKey,
    readers :: TVar (Set RecipientId),
    filepath :: String
  }
  deriving (Eq)

{-   newFile :: s -> FileRec -> m (Either ErrorType ())
  addRecipients:: s -> SenderId -> NonEmpty (RecipientId, RcvPublicVerifyKey) -> m (Either ErrorType ())
  putFile:: s -> SenderId -> String -> m (Either ErrorType ())
  deleteFile :: s -> SenderId -> m (Either ErrorType ())
  getFile :: s -> QueueId -> m (Either ErrorType FileRec)
  ackFile :: s -> QueueId -> RecipientId -> m (Either ErrorType ()) -}

newQueueStore :: STM FileStore
newQueueStore = do
  chunks <- TM.empty
  recipients <- TM.empty
  pure FileStore {chunks, recipients}

newFile :: FileStore -> FileRec -> [(RecipientId, RcvPublicVerifyKey)] -> STM (Either ErrorType ())
newFile FileStore {chunks, recipients} fileRec@FileRec {senderId} addReaders = do
  ifM hasId (pure $ Left DUPLICATE_) $ do
    TM.insert senderId fileRec chunks
    forM_ addReaders $ \(recipientId, key) -> TM.insert recipientId (senderId, key) recipients
    pure $ Right ()
  where
    hasId = TM.member senderId chunks

addRecipients:: FileStore -> SenderId -> NonEmpty (RecipientId, RcvPublicVerifyKey) -> STM (Either ErrorType ())
addRecipients FileStore{chunks, recipients} senderId addReaders = do
  TM.lookup senderId chunks >>= \case
    Just chunk ->
      readTVar (readers chunk) >>= \_r ->
        forM_ addReaders $ \(recipientId, key) ->
          ifM (TM.member recipientId recipients) (pure $ Left DUPLICATE_) $
            TM.insert recipientId (senderId, key) recipients
            modifyTVar' (readers chunk) $ Set.insert recipientId
  pure $ Right ()

deleteFile :: FileStore -> SenderId -> STM (Either ErrorType ())
deleteFile FileStore {chunks, recipients} senderId = do
  TM.lookupDelete senderId chunks >>= \case
    Just chunk -> 
      readTVar (readers chunk) >>= \readers ->
        forM_ readers $ \recipientId -> TM.lookupDelete recipientId recipients
    _ -> pure $ Left AUTH
  pure $ Right ()

getFile :: FileStore -> SenderId -> STM (Either ErrorType FileRec)
getFile FileStore {chunks} senderId =
  toResult <$> TM.lookup senderId chunks

ackFile :: FileStore -> SenderId -> RecipientId -> STM (Either ErrorType ())
ackFile FileStore {chunks, recipients} senderId recipientId = do
  TM.lookup senderId chunks >>= \case
    Just chunk ->
      TM.lookupDelete recipientId recipients
      readTVar (readers chunk) >>= \_r ->
        modifyTVar' (readers chunk) $ Set.delete recipientId
    _ -> pure $ Left AUTH
  pure $ Right ()

toResult :: Maybe a -> Either ErrorType a
toResult = maybe (Left AUTH) Right
