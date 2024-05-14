{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}

module Simplex.Messaging.Server.Stats.Client where

import Control.Applicative (optional, (<|>))
import qualified Data.Attoparsec.ByteString.Char8 as A
import qualified Data.ByteString.Char8 as B
import Data.IntMap (IntMap)
import qualified Data.IntMap.Strict as IM
import Data.IntPSQ (IntPSQ)
import qualified Data.IntPSQ as IP
import Data.IntSet (IntSet)
import qualified Data.IntSet as IS
import Data.Monoid (getSum)
import Data.Set (Set)
import qualified Data.Set as S
import Data.Time.Calendar.Month (pattern MonthDay)
import Data.Time.Calendar.OrdinalDate (mondayStartWeek)
import Data.Time.Clock (NominalDiffTime, UTCTime (..))
import Data.Time.Clock.POSIX (POSIXTime)
import Data.Word (Word32)
import Simplex.Messaging.Encoding.String
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
    qCreated :: TVar (Set RecipientId), -- can be IntSet with QueueRecIDs
    qSentSigned :: TVar (Set RecipientId), -- can be IntSet with QueueRecIDs
    msgSentSigned :: TVar Int,
    msgSentUnsigned :: TVar Int,
    msgSentViaProxy :: TVar Int,
    msgDeliveredSigned :: TVar Int
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
    _msgSentViaProxy :: Int,
    _msgDeliveredSigned :: Int
  }

newClientStats :: Monad m => (forall a. a -> m (TVar a)) -> PeerId -> UTCTime -> m ClientStats
newClientStats newF peerId ts = do
  peerAddresses <- newF $ IS.singleton peerId
  socketCount <- newF 0
  createdAt <- newF ts
  updatedAt <- newF ts
  qCreated <- newF mempty
  qSentSigned <- newF mempty
  msgSentSigned <- newF 0
  msgSentUnsigned <- newF 0
  msgSentViaProxy <- newF 0
  msgDeliveredSigned <- newF 0
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
        msgSentViaProxy,
        msgDeliveredSigned
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
  _msgSentViaProxy <- readF $ msgSentViaProxy cs
  _msgDeliveredSigned <- readF $ msgDeliveredSigned cs
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
        _msgSentViaProxy,
        _msgDeliveredSigned
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
  writeTVar (msgSentViaProxy cs) (_msgSentViaProxy csd)
  writeTVar (msgDeliveredSigned cs) (_msgDeliveredSigned csd)

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
      _msgSentViaProxy = _msgSentViaProxy a + _msgSentViaProxy b,
      _msgDeliveredSigned = _msgDeliveredSigned a + _msgDeliveredSigned b
    }
