{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

module Simplex.Messaging.Notifications.Server.Store.Postgres where

import Control.Concurrent.STM
import Control.Logger.Simple
import Data.Int (Int64)
import Data.List.NonEmpty (NonEmpty)
import Data.Map.Strict (Map)
import Data.Set (Set)
import Data.Word (Word16)
import Simplex.Messaging.Agent.Store.Postgres (closeDBStore, createDBStore)
import Simplex.Messaging.Agent.Store.Postgres.Common
import Simplex.Messaging.Agent.Store.Shared (MigrationConfirmation (..))
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Notifications.Protocol
import Simplex.Messaging.Notifications.Server.Store (NtfSTMStore (..))
import Simplex.Messaging.Notifications.Server.Store.Migrations
import Simplex.Messaging.Protocol (NotifierId, NtfPrivateAuthKey, NtfPublicAuthKey, SMPServer)
import Simplex.Messaging.Server.QueueStore (RoundedSystemTime)
import Simplex.Messaging.Server.StoreLog (closeStoreLog, openWriteStoreLog)
import Simplex.Messaging.Server.StoreLog.Types
import Simplex.Messaging.Util (tshow)
import System.Exit (exitFailure)
import System.IO (IOMode (..))

data NtfPostgresStore = NtfPostgresStore
  { dbStore :: DBStore,
    dbStoreLog :: Maybe (StoreLog 'WriteMode),
    tokenNtfsTTL :: Int64
  }

data NtfPostgresStoreCfg = NtfPostgresStoreCfg
  { dbOpts :: DBOpts,
    dbStoreLogPath :: Maybe FilePath,
    confirmMigrations :: MigrationConfirmation,
    tokenNtfsTTL :: Int64
  }

data NtfTknData' = NtfTknData'
  { ntfTknId :: NtfTokenId,
    token :: DeviceToken,
    tknStatus :: NtfTknStatus,
    tknVerifyKey :: NtfPublicAuthKey,
    tknDhKeys :: C.KeyPair 'C.X25519,
    tknDhSecret :: C.DhSecretX25519,
    tknRegCode :: NtfRegCode,
    tknCronInterval :: Word16,
    tknUpdatedAt :: Maybe RoundedSystemTime
  }

mkNtfTknData :: NtfTokenId -> NewNtfEntity 'Token -> C.KeyPair 'C.X25519 -> C.DhSecretX25519 -> NtfRegCode -> RoundedSystemTime -> NtfTknData'
mkNtfTknData ntfTknId (NewNtfTkn token tknVerifyKey _) tknDhKeys tknDhSecret tknRegCode ts =
  NtfTknData' {ntfTknId, token, tknStatus = NTRegistered, tknVerifyKey, tknDhKeys, tknDhSecret, tknRegCode, tknCronInterval = 0, tknUpdatedAt = Just ts}

data NtfSubData' = NtfSubData'
  { ntfSubId :: NtfSubscriptionId,
    smpQueue :: SMPQueueNtf,
    notifierKey :: NtfPrivateAuthKey,
    tokenId :: NtfTokenId,
    subStatus :: NtfSubStatus
  }

data NtfEntityRec' (e :: NtfEntity) where
  NtfTkn' :: NtfTknData' -> NtfEntityRec' 'Token
  NtfSub' :: NtfSubData' -> NtfEntityRec' 'Subscription

newNtfDbStore :: NtfPostgresStoreCfg -> IO NtfPostgresStore
newNtfDbStore NtfPostgresStoreCfg {dbOpts, dbStoreLogPath, confirmMigrations, tokenNtfsTTL} = do
  dbStore <- either err pure =<< createDBStore dbOpts ntfServerMigrations confirmMigrations
  dbStoreLog <- mapM (openWriteStoreLog True) dbStoreLogPath
  pure NtfPostgresStore {dbStore, dbStoreLog, tokenNtfsTTL}
  where
    err e = do
      logError $ "STORE: newNtfStore, error opening PostgreSQL database, " <> tshow e
      exitFailure

closeNtfDbStore :: NtfPostgresStore -> IO ()
closeNtfDbStore NtfPostgresStore {dbStore, dbStoreLog} = do
  closeDBStore dbStore
  mapM_ closeStoreLog dbStoreLog

-- TODO [ntfdb] getting token should update its updated_at
getNtfToken :: NtfPostgresStore -> NtfTokenId -> IO (Maybe NtfTknData')
getNtfToken = undefined

-- getNtfToken :: NtfStore -> NtfTokenId -> STM (Maybe NtfTknData')
-- getNtfToken st tknId = TM.lookup tknId (tokens st)

-- getNtfTokenIO :: NtfStore -> NtfTokenId -> IO (Maybe NtfTknData')
-- getNtfTokenIO st tknId = TM.lookupIO tknId (tokens st)

addNtfToken :: NtfPostgresStore -> NtfTokenId -> NtfTknData' -> IO ()
addNtfToken = undefined

-- addNtfToken :: NtfStore -> NtfTokenId -> NtfTknData' -> STM ()
-- addNtfToken st tknId tkn@NtfTknData' {token, tknVerifyKey} = do
--   TM.insert tknId tkn $ tokens st
--   TM.lookup token regs >>= \case
--     Just tIds -> TM.insert regKey tknId tIds
--     _ -> do
--       tIds <- TM.singleton regKey tknId
--       TM.insert token tIds regs
--   where
--     regs = tokenRegistrations st
--     regKey = C.toPubKey C.pubKeyBytes tknVerifyKey

-- Note: addNtfToken should also do all that
-- atomically $ do
--   removeTokenRegistration st tkn
--   writeTVar tknStatus NTRegistered
--   let tkn' = tkn {token = token', tknRegCode = regCode}
--   addNtfToken st tknId tkn'

getNtfTokenRegistration :: NtfPostgresStore -> NewNtfEntity 'Token -> IO (Maybe NtfTknData')
getNtfTokenRegistration = undefined

-- getNtfTokenRegistration :: NtfStore -> NewNtfEntity 'Token -> STM (Maybe NtfTknData')
-- getNtfTokenRegistration st (NewNtfTkn token tknVerifyKey _) =
--   TM.lookup token (tokenRegistrations st)
--     $>>= TM.lookup regKey
--     $>>= (`TM.lookup` tokens st)
--   where
--     regKey = C.toPubKey C.pubKeyBytes tknVerifyKey

removeInactiveTokenRegistrations :: NtfPostgresStore -> NtfTknData' -> IO [NtfTokenId]
removeInactiveTokenRegistrations = undefined

-- removeInactiveTokenRegistrations :: NtfStore -> NtfTknData' -> STM [NtfTokenId]
-- removeInactiveTokenRegistrations st NtfTknData' {ntfTknId = tId, token} =
--   TM.lookup token (tokenRegistrations st)
--     >>= maybe (pure []) removeRegs
--   where
--     removeRegs :: TMap ByteString NtfTokenId -> STM [NtfTokenId]
--     removeRegs tknRegs = do
--       tIds <- filter ((/= tId) . snd) . M.assocs <$> readTVar tknRegs
--       forM_ tIds $ \(regKey, tId') -> do
--         TM.delete regKey tknRegs
--         TM.delete tId' $ tokens st
--         TM.delete tId' $ tokenLastNtfs st
--         void $ deleteTokenSubs st tId'
--       pure $ map snd tIds

removeTokenRegistration :: NtfPostgresStore -> NtfTknData' -> IO ()
removeTokenRegistration = undefined

-- removeTokenRegistration :: NtfStore -> NtfTknData' -> STM ()
-- removeTokenRegistration st NtfTknData' {ntfTknId = tId, token, tknVerifyKey} =
--   TM.lookup token (tokenRegistrations st) >>= mapM_ removeReg
--   where
--     removeReg regs =
--       TM.lookup k regs
--         >>= mapM_ (\tId' -> when (tId == tId') $ TM.delete k regs)
--     k = C.toPubKey C.pubKeyBytes tknVerifyKey

deleteNtfToken :: NtfPostgresStore -> NtfTokenId -> IO (Map SMPServer (Set NotifierId))
deleteNtfToken = undefined

-- deleteNtfToken :: NtfStore -> NtfTokenId -> STM (Map SMPServer (Set NotifierId))
-- deleteNtfToken st tknId = do
--   void $
--     TM.lookupDelete tknId (tokens st) $>>= \NtfTknData' {token, tknVerifyKey} ->
--       TM.lookup token regs $>>= \tIds ->
--         TM.delete (regKey tknVerifyKey) tIds
--           >> whenM (TM.null tIds) (TM.delete token regs) $> Just ()
--   TM.delete tknId $ tokenLastNtfs st
--   deleteTokenSubs st tknId
--   where
--     regs = tokenRegistrations st
--     regKey = C.toPubKey C.pubKeyBytes

deleteTokenSubs :: NtfPostgresStore -> NtfTokenId -> IO (Map SMPServer (Set NotifierId))
deleteTokenSubs = undefined

-- deleteTokenSubs :: NtfStore -> NtfTokenId -> STM (Map SMPServer (Set NotifierId))
-- deleteTokenSubs st tknId =
--   TM.lookupDelete tknId (tokenSubscriptions st)
--     >>= maybe (pure M.empty) (readTVar >=> deleteSrvSubs)
--   where
--     deleteSrvSubs :: Map SMPServer (TVar (Set NtfSubscriptionId), TVar (Set NotifierId)) -> STM (Map SMPServer (Set NotifierId))
--     deleteSrvSubs = M.traverseWithKey $ \smpServer (sVar, nVar) -> do
--       sIds <- readTVar sVar
--       modifyTVar' (subscriptions st) (`M.withoutKeys` sIds)
--       nIds <- readTVar nVar
--       TM.lookup smpServer (subscriptionLookup st) >>= mapM_ (`modifyTVar'` (`M.withoutKeys` nIds))
--       pure nIds    

updateTknCronInterval :: NtfPostgresStore -> NtfTknData' -> Word16 -> IO ()
updateTknCronInterval = undefined
-- 

-- TODO [ntfdb] this function should with some subscriptions
getUsedSMPServers :: NtfPostgresStore -> IO [SMPServer]
getUsedSMPServers = undefined

-- TODO [ntfdb] this function should read all subscriptions for a given SMP server and stream them to action in batches of specified size
-- possibly, action can be called for each row and batching to be done outside

-- ntfShouldSubscribe should be used directly in DB
getNtfSubscriptions :: NtfPostgresStore -> SMPServer -> Int -> (NonEmpty NtfSubData' -> IO ()) -> IO ()
getNtfSubscriptions _st _smpServer _batchSize _action = undefined

getNtfSubscription :: NtfPostgresStore -> NtfSubscriptionId -> IO (Maybe NtfSubData')
getNtfSubscription = undefined

-- getNtfSubscriptionIO :: NtfStore -> NtfSubscriptionId -> IO (Maybe NtfSubData')
-- getNtfSubscriptionIO st subId = TM.lookupIO subId (subscriptions st)

findNtfSubscription :: NtfPostgresStore -> SMPQueueNtf -> IO (Maybe NtfSubData')
findNtfSubscription = undefined

-- findNtfSubscription :: NtfStore -> SMPQueueNtf -> STM (Maybe NtfSubData')
-- findNtfSubscription st SMPQueueNtf {smpServer, notifierId} =
--   TM.lookup smpServer (subscriptionLookup st) $>>= TM.lookup notifierId 

findNtfSubscriptionToken :: NtfPostgresStore -> SMPQueueNtf -> IO (Maybe NtfTknData')
findNtfSubscriptionToken = undefined

-- findNtfSubscriptionToken :: NtfStore -> SMPQueueNtf -> STM (Maybe NtfTknData')
-- findNtfSubscriptionToken st smpQueue = do
--   findNtfSubscription st smpQueue
--     $>>= \NtfSubData' {tokenId} -> getActiveNtfToken st tokenId

-- TODO [ntfdb] getting active token should update its updated_at
getActiveNtfToken :: NtfPostgresStore -> NtfTokenId -> IO (Maybe NtfTknData')
getActiveNtfToken = undefined

-- getActiveNtfToken :: NtfStore -> NtfTokenId -> STM (Maybe NtfTknData')
-- getActiveNtfToken st tknId =
--   getNtfToken st tknId $>>= \tkn@NtfTknData' {tknStatus} -> do
--     tStatus <- readTVar tknStatus
--     pure $ if tStatus == NTActive then Just tkn else Nothing

mkNtfSubData :: NtfSubscriptionId -> NewNtfEntity 'Subscription -> NtfSubData'
mkNtfSubData ntfSubId (NewNtfSub tokenId smpQueue notifierKey) =
  NtfSubData' {ntfSubId, smpQueue, tokenId, subStatus = NSNew, notifierKey}

updateTknStatus :: NtfPostgresStore -> NtfTknData' -> NtfTknStatus -> IO ()
updateTknStatus = undefined
-- updateTknStatus NtfTknData' {ntfTknId, tknStatus} status = do
--   old <- atomically $ stateTVar tknStatus (,status)
--   when (old /= status) $ withNtfLog $ \sl -> logTokenStatus sl ntfTknId status

addNtfSubscription :: NtfPostgresStore -> NtfSubscriptionId -> NtfSubData' -> IO Bool
addNtfSubscription = undefined

-- -- returns False if subscription existed before
-- addNtfSubscription :: NtfStore -> NtfSubscriptionId -> NtfSubData' -> STM Bool
-- addNtfSubscription st subId sub@NtfSubData' {smpQueue = SMPQueueNtf {smpServer, notifierId}, tokenId} =
--   TM.lookup tokenId (tokenSubscriptions st)
--     >>= maybe newTokenSubs pure
--     >>= \ts -> TM.lookup smpServer ts
--     >>= maybe (newTokenSrvSubs ts) pure
--     >>= insertSub
--   where
--     newTokenSubs = do
--       ts <- newTVar M.empty
--       TM.insert tokenId ts $ tokenSubscriptions st
--       pure ts
--     newTokenSrvSubs ts = do
--       tss <- (,) <$> newTVar S.empty <*> newTVar S.empty
--       TM.insert smpServer tss ts
--       pure tss
--     insertSub  :: (TVar (Set NtfSubscriptionId), TVar (Set NotifierId)) -> STM Bool
--     insertSub (sIds, nIds) = do
--       modifyTVar' sIds $ S.insert subId
--       modifyTVar' nIds $ S.insert notifierId
--       TM.insert subId sub $ subscriptions st
--       TM.lookup smpServer (subscriptionLookup st)
--         >>= maybe newSubs pure
--         >>= fmap isNothing . TM.lookupInsert notifierId sub
--     newSubs = do
--       ss <- newTVar M.empty
--       TM.insert smpServer ss $ subscriptionLookup st
--       pure ss

deleteNtfSubscription :: NtfPostgresStore -> NtfSubscriptionId -> IO ()
deleteNtfSubscription = undefined

-- deleteNtfSubscription :: NtfStore -> NtfSubscriptionId -> STM ()
-- deleteNtfSubscription st subId = TM.lookupDelete subId (subscriptions st) >>= mapM_ deleteSubIndices
--   where
--     deleteSubIndices NtfSubData' {smpQueue = SMPQueueNtf {smpServer, notifierId}, tokenId} = do
--       TM.lookup smpServer (subscriptionLookup st) >>= mapM_ (TM.delete notifierId)
--       tss_ <- TM.lookup tokenId (tokenSubscriptions st) $>>= TM.lookup smpServer
--       forM_ tss_ $ \(sIds, nIds) -> do
--         modifyTVar' sIds $ S.delete subId
--         modifyTVar' nIds $ S.delete notifierId

updateSrvSubStatus :: NtfPostgresStore -> SMPQueueNtf -> NtfSubStatus -> IO ()
updateSrvSubStatus = undefined
-- updateSubStatus smpQueue status = do
--   st <- asks store
--   atomically (findNtfSubscription st smpQueue) >>= mapM_ update
--   where
--     update NtfSubData {ntfSubId, subStatus} = do
--       old <- atomically $ stateTVar subStatus (,status)
--       when (old /= status) $ withNtfLog $ \sl -> logSubscriptionStatus sl ntfSubId status

batchUpdateSrvSubStatus :: NtfPostgresStore -> SMPServer -> NonEmpty NotifierId -> NtfSubStatus -> IO ()
batchUpdateSrvSubStatus = undefined

batchUpdateSrvSubStatuses :: NtfPostgresStore -> SMPServer -> NonEmpty (NotifierId, NtfSubStatus) -> IO ()
batchUpdateSrvSubStatuses = undefined

batchUpdateSubStatus :: NtfPostgresStore -> NonEmpty NtfSubData' -> NtfSubStatus -> IO ()
batchUpdateSubStatus = undefined
-- mapM_ (\NtfSubData {smpQueue} -> updateSubStatus smpQueue NSPending) subs'

addTokenLastNtf :: NtfPostgresStore -> NtfTokenId -> PNMessageData -> IO (NonEmpty PNMessageData)
addTokenLastNtf = undefined

-- addTokenLastNtf :: NtfStore -> NtfTokenId -> PNMessageData -> IO (NonEmpty PNMessageData)
-- addTokenLastNtf st tknId newNtf =
--   TM.lookupIO tknId (tokenLastNtfs st) >>= maybe (atomically maybeNewTokenLastNtfs) (atomically . addNtf)
--   where
--     maybeNewTokenLastNtfs =
--       TM.lookup tknId (tokenLastNtfs st) >>= maybe newTokenLastNtfs addNtf
--     newTokenLastNtfs = do
--       v <- newTVar [newNtf]
--       TM.insert tknId v $ tokenLastNtfs st
--       pure [newNtf]
--     addNtf v =
--       stateTVar v $ \ntfs -> let !ntfs' = rebuildList ntfs in (ntfs', ntfs')
--       where
--         rebuildList :: NonEmpty PNMessageData -> NonEmpty PNMessageData
--         rebuildList = foldr keepPrevNtf [newNtf]
--           where
--             PNMessageData {smpQueue = newNtfQ} = newNtf
--             keepPrevNtf ntf@PNMessageData {smpQueue} ntfs
--               | smpQueue /= newNtfQ && length ntfs < maxNtfs = ntf <| ntfs
--               | otherwise = ntfs
--         maxNtfs = 6

-- storeTokenLastNtf -- is it needed?

-- -- This function is expected to be called after store log is read,
-- -- as it checks for token existence when adding last notification.
-- storeTokenLastNtf :: NtfStore -> NtfTokenId -> PNMessageData -> IO ()
-- storeTokenLastNtf (NtfStore {tokens, tokenLastNtfs}) tknId ntf = do
--   TM.lookupIO tknId tokenLastNtfs >>= atomically . maybe newTokenLastNtfs (`modifyTVar'` (ntf <|))
--   where
--     newTokenLastNtfs = TM.lookup tknId tokenLastNtfs >>= maybe insertForExistingToken (`modifyTVar'` (ntf <|))
--     insertForExistingToken =
--       whenM (TM.member tknId tokens) $
--         TM.insertM tknId (newTVar [ntf]) tokenLastNtfs

-- TODO [ntfdb]
importNtfSTMStore :: NtfPostgresStore -> NtfSTMStore -> IO (Int, Int, Int)
importNtfSTMStore _st stmStore = do
  _tokens <- readTVarIO $ tokens stmStore
  _subs <- readTVarIO $ subscriptions stmStore
  _ntfs <- readTVarIO $ tokenLastNtfs stmStore
  pure (0, 0, 0)

exportNtfDbStore :: NtfPostgresStore -> FilePath -> IO (Int, Int, Int)
exportNtfDbStore _st storeLogFilePath = do
  _sl <- openWriteStoreLog False storeLogFilePath
  undefined
