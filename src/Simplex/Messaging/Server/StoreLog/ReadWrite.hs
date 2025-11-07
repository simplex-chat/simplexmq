{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

module Simplex.Messaging.Server.StoreLog.ReadWrite where

import Control.Concurrent.STM
import Control.Logger.Simple
import Control.Monad
import Control.Monad.IO.Class
import Control.Monad.Trans.Except
import qualified Data.ByteString.Char8 as B
import qualified Data.Text as T
import Data.Text.Encoding (decodeLatin1)
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Protocol (ASubscriberParty (..), ErrorType, RecipientId, SParty (..))
import Simplex.Messaging.Server.QueueStore (QueueRec, ServiceRec (..))
import Simplex.Messaging.Server.QueueStore.STM (STMQueueStore (..), STMService (..))
import Simplex.Messaging.Server.QueueStore.Types
import Simplex.Messaging.Server.StoreLog
import Simplex.Messaging.Util (tshow)
import System.IO

writeQueueStore :: forall q. StoreQueueClass q => StoreLog 'WriteMode -> STMQueueStore q -> IO ()
writeQueueStore s st = do
  readTVarIO (services st) >>= mapM_ (logNewService s . serviceRec)
  withLoadedQueues st $ writeQueue
  where
    writeQueue :: q -> IO ()
    writeQueue q = readTVarIO (queueRec q) >>= mapM_ (logCreateQueue s $ recipientId q)

readQueueStore :: forall q. StoreQueueClass q => Bool -> (RecipientId -> QueueRec -> IO q) -> FilePath -> STMQueueStore q -> IO ()
readQueueStore tty mkQ f st = readLogLines tty f $ \_ -> processLine
  where
    processLine :: B.ByteString -> IO ()
    processLine s = either printError procLogRecord (strDecode s)
      where
        procLogRecord :: StoreLogRecord -> IO ()
        procLogRecord = \case
          CreateQueue rId qr -> addQueue_ st mkQ rId qr >>= qError rId "CreateQueue"
          CreateLink rId lnkId d -> withQueue rId "CreateLink" $ \q -> addQueueLinkData st q lnkId d
          DeleteLink rId -> withQueue rId "DeleteLink" $ \q -> deleteQueueLinkData st q
          SecureQueue qId sKey -> withQueue qId "SecureQueue" $ \q -> secureQueue st q sKey
          UpdateKeys rId rKeys -> withQueue rId "UpdateKeys" $ \q -> updateKeys st q rKeys
          AddNotifier qId ntfCreds -> withQueue qId "AddNotifier" $ \q -> addQueueNotifier st q ntfCreds
          SuspendQueue qId -> withQueue qId "SuspendQueue" $ suspendQueue st
          BlockQueue qId info -> withQueue qId "BlockQueue" $ \q -> blockQueue st q info
          UnblockQueue qId -> withQueue qId "UnblockQueue" $ unblockQueue st
          DeleteQueue qId -> withQueue qId "DeleteQueue" $ deleteStoreQueue st
          DeleteNotifier qId -> withQueue qId "DeleteNotifier" $ deleteQueueNotifier st
          UpdateTime qId t -> withQueue qId "UpdateTime" $ \q -> updateQueueTime st q t
          NewService sr@ServiceRec {serviceId} -> getCreateService @q st sr >>= \case
            Right serviceId'
              | serviceId == serviceId' -> pure ()
              | otherwise -> logError $ errPfx <> "created with the wrong ID " <> decodeLatin1 (strEncode serviceId')
            Left e -> logError $ errPfx <> tshow e
            where
              errPfx = "STORE: getCreateService, stored service " <> decodeLatin1 (strEncode serviceId) <> ", "
          QueueService qId (ASP party) serviceId -> withQueue qId "QueueService" $ \q -> setQueueService st q party serviceId
        printError :: String -> IO ()
        printError e = B.putStrLn $ "Error parsing log: " <> B.pack e <> " - " <> s
        withQueue :: forall a. RecipientId -> T.Text -> (q -> IO (Either ErrorType a)) -> IO ()
        withQueue qId op a = runExceptT go >>= qError qId op
          where
            go = do
              q <- ExceptT $ getQueue_ st (\_ -> mkQ) SRecipient qId
              liftIO (readTVarIO $ queueRec q) >>= \case
                Nothing -> logWarn $ logPfx qId op <> "already deleted"
                Just _ -> void $ ExceptT $ a q
        qError qId op = \case
          Left e -> logError $ logPfx qId op <> tshow e
          Right _ -> pure ()
        logPfx qId op = "STORE: " <> op <> ", stored queue " <> decodeLatin1 (strEncode qId) <> ", "
