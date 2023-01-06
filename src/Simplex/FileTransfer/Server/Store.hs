{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}

module Simplex.FileTransfer.Server.Store
  ( FileStore(..),
    FileRec,
    NewFileRec(..),
    newFileStore,
    addFile,
    setFilePath,
    addRecipient,
    deleteFile,
    getFile,
    ackFile,
  )
where

import Control.Concurrent.STM
import Data.Functor (($>))
import Data.Set (Set)
import qualified Data.Set as S
import Simplex.Messaging.Protocol hiding (SParty, SRecipient, SSender)
import Simplex.Messaging.TMap (TMap)
import qualified Simplex.Messaging.TMap as TM
import Simplex.Messaging.Util (ifM)
import Data.List.NonEmpty (NonEmpty)
import Data.Word (Word32)

data FileStore = FileStore
  { files :: TMap SenderId FileRec,
    recipients :: TMap RecipientId (SenderId, RcvPublicVerifyKey)
  }

data FileRec = FileRec
  { senderId :: SenderId,
    senderKey :: SndPublicVerifyKey,
    recipientIds :: TVar (Set RecipientId),
    filepath :: TVar (Maybe FilePath)
  }
  deriving (Eq)

data NewFileRec = NewFileRec
 {
   senderPubKey :: SndPublicVerifyKey,
   recipientKeys :: NonEmpty RcvPublicVerifyKey,
   fileSize :: Word32
 }
 deriving (Eq)

newFileStore :: STM FileStore
newFileStore = do
  files <- TM.empty
  recipients <- TM.empty
  pure FileStore {files, recipients}

addFile :: FileStore -> SenderId -> SndPublicVerifyKey -> STM (Either ErrorType ())
addFile FileStore {files} sId sKey =
  ifM (TM.member sId files) (pure $ Left DUPLICATE_) $ do
    f <- newFileRec sId sKey
    TM.insert sId f files
    pure $ Right ()

newFileRec :: SenderId -> SndPublicVerifyKey -> STM FileRec
newFileRec senderId senderKey = do
  recipientIds <- newTVar S.empty
  filepath <- newTVar Nothing
  pure FileRec {senderId, senderKey, recipientIds, filepath}

setFilePath :: FileStore -> SenderId -> FilePath -> STM (Either ErrorType ())
setFilePath st sId fPath =
  withFile st sId $ \FileRec {filepath} ->
    writeTVar filepath (Just fPath) $> Right ()

addRecipient :: FileStore -> SenderId -> (RecipientId, RcvPublicVerifyKey) -> STM (Either ErrorType ())
addRecipient st@FileStore {recipients} senderId recipient@(rId, _) =
  withFile st senderId $ \FileRec {recipientIds} -> do
    rIds <- readTVar recipientIds
    mem <- TM.member rId recipients
    if rId `S.member` rIds || mem
      then pure $ Left DUPLICATE_
      else do
        writeTVar recipientIds $! S.insert rId rIds
        TM.insert rId recipient recipients
        pure $ Right ()

deleteFile :: FileStore -> SenderId -> STM (Either ErrorType ())
deleteFile FileStore {files, recipients} senderId = do
  TM.lookupDelete senderId files >>= \case
    Just FileRec {recipientIds} -> do
      readTVar recipientIds >>= mapM_ (`TM.delete` recipients)
      pure $ Right ()
    _ -> pure $ Left AUTH

getFile :: FileStore -> SenderId -> STM (Either ErrorType FileRec)
getFile st sId = withFile st sId $ pure . Right

-- TODO possibly, if acknowledgement of file reception by the last recipient
-- is going to lead to deleting the file this has to be updated and return some value to delete the actual file
ackFile :: FileStore -> RecipientId -> STM (Either ErrorType ())
ackFile st@FileStore {recipients} recipientId = do
  TM.lookupDelete recipientId recipients >>= \case
    Just (sId, _) ->
      withFile st sId $ \FileRec {recipientIds} -> do
        modifyTVar' recipientIds $ S.delete recipientId
        pure $ Right ()
    _ -> pure $ Left AUTH

withFile :: FileStore -> SenderId -> (FileRec -> STM (Either ErrorType a)) -> STM (Either ErrorType a)
withFile FileStore {files} sId a =
  TM.lookup sId files >>= \case
    Just f -> a f
    _ -> pure $ Left AUTH
