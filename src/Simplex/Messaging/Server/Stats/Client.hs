{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}

module Simplex.Messaging.Server.Stats.Client where

import Data.IntSet (IntSet)
import qualified Data.IntSet as IS
import Data.Set (Set)
import Data.Time.Clock (UTCTime (..))
import Simplex.Messaging.Protocol (RecipientId)
import Simplex.Messaging.Transport (PeerId)
import UnliftIO.STM

-- | Ephemeral client ID across reconnects
type ClientStatsId = Int

data ClientStats = ClientStats
  { peerAddresses :: TVar IntSet, -- cumulative set of used PeerIds
    socketCount :: TVar Int,
    createdAt :: TVar UTCTime,
    updatedAt :: TVar UTCTime,
    qCreated :: TVar (Set RecipientId), -- can be IntSet with QueueRecIDs, for dumping into suspicous
    qSentSigned :: TVar (Set RecipientId), -- can be IntSet with QueueRecIDs
    msgSentSigned :: TVar Int,
    msgSentUnsigned :: TVar Int,
    msgDeliveredSigned :: TVar Int,
    proxyRelaysRequested :: TVar Int,
    proxyRelaysConnected :: TVar Int,
    msgSentViaProxy :: TVar Int
  }

-- may be combined with session duration to produce average rates (q/s, msg/s)
data ClientStatsData = ClientStatsData
  { _peerAddresses :: IntSet,
    _socketCount :: Int,
    _createdAt :: UTCTime,
    _updatedAt :: UTCTime,
    _qCreated :: Set RecipientId,
    _qSentSigned :: Set RecipientId,
    _msgSentSigned :: Int,
    _msgSentUnsigned :: Int,
    _msgDeliveredSigned :: Int,
    _proxyRelaysRequested :: Int,
    _proxyRelaysConnected :: Int,
    _msgSentViaProxy :: Int
  }

newClientStats :: Monad m => (forall a. a -> m (TVar a)) -> PeerId -> UTCTime -> m ClientStats
newClientStats newF peerId ts = do
  peerAddresses <- newF $ IS.singleton peerId
  socketCount <- newF 1
  createdAt <- newF ts
  updatedAt <- newF ts
  qCreated <- newF mempty
  qSentSigned <- newF mempty
  msgSentSigned <- newF 0
  msgSentUnsigned <- newF 0
  msgDeliveredSigned <- newF 0
  proxyRelaysRequested <- newF 0
  proxyRelaysConnected <- newF 0
  msgSentViaProxy <- newF 0
  pure
    ClientStats
      { peerAddresses,
        socketCount,
        createdAt,
        updatedAt,
        qCreated,
        qSentSigned,
        msgSentSigned,
        msgSentUnsigned,
        msgDeliveredSigned,
        proxyRelaysRequested,
        proxyRelaysConnected,
        msgSentViaProxy
      }
{-# INLINE newClientStats #-}

readClientStatsData :: Monad m => (forall a. TVar a -> m a) -> ClientStats -> m ClientStatsData
readClientStatsData readF cs = do
  _peerAddresses <- readF $ peerAddresses cs
  _socketCount <- readF $ socketCount cs
  _createdAt <- readF $ createdAt cs
  _updatedAt <- readF $ updatedAt cs
  _qCreated <- readF $ qCreated cs
  _qSentSigned <- readF $ qSentSigned cs
  _msgSentSigned <- readF $ msgSentSigned cs
  _msgSentUnsigned <- readF $ msgSentUnsigned cs
  _msgDeliveredSigned <- readF $ msgDeliveredSigned cs
  _proxyRelaysRequested <- readF $ proxyRelaysRequested cs
  _proxyRelaysConnected <- readF $ proxyRelaysConnected cs
  _msgSentViaProxy <- readF $ msgSentViaProxy cs
  pure
    ClientStatsData
      { _peerAddresses,
        _socketCount,
        _createdAt,
        _updatedAt,
        _qCreated,
        _qSentSigned,
        _msgSentSigned,
        _msgSentUnsigned,
        _msgDeliveredSigned,
        _proxyRelaysRequested,
        _proxyRelaysConnected,
        _msgSentViaProxy
      }
{-# INLINE readClientStatsData #-}

writeClientStatsData :: ClientStats -> ClientStatsData -> STM ()
writeClientStatsData cs csd = do
  writeTVar (peerAddresses cs) (_peerAddresses csd)
  writeTVar (socketCount cs) (_socketCount csd)
  writeTVar (createdAt cs) (_createdAt csd)
  writeTVar (updatedAt cs) (_updatedAt csd)
  writeTVar (qCreated cs) (_qCreated csd)
  writeTVar (qSentSigned cs) (_qSentSigned csd)
  writeTVar (msgSentSigned cs) (_msgSentSigned csd)
  writeTVar (msgSentUnsigned cs) (_msgSentUnsigned csd)
  writeTVar (msgDeliveredSigned cs) (_msgDeliveredSigned csd)
  writeTVar (proxyRelaysRequested cs) (_proxyRelaysRequested csd)
  writeTVar (proxyRelaysConnected cs) (_proxyRelaysConnected csd)
  writeTVar (msgSentViaProxy cs) (_msgSentViaProxy csd)

mergeClientStatsData :: ClientStatsData -> ClientStatsData -> ClientStatsData
mergeClientStatsData a b =
  ClientStatsData
    { _peerAddresses = _peerAddresses a <> _peerAddresses b,
      _socketCount = _socketCount a + _socketCount b,
      _createdAt = min (_createdAt a) (_createdAt b),
      _updatedAt = max (_updatedAt a) (_updatedAt b),
      _qCreated = _qCreated a <> _qCreated b,
      _qSentSigned = _qSentSigned a <> _qSentSigned b,
      _msgSentSigned = _msgSentSigned a + _msgSentSigned b,
      _msgSentUnsigned = _msgSentUnsigned a + _msgSentUnsigned b,
      _msgDeliveredSigned = _msgDeliveredSigned a + _msgDeliveredSigned b,
      _proxyRelaysRequested = _proxyRelaysRequested a + _proxyRelaysRequested b,
      _proxyRelaysConnected = _proxyRelaysConnected a + _proxyRelaysConnected b,
      _msgSentViaProxy = _msgSentViaProxy a + _msgSentViaProxy b
    }
