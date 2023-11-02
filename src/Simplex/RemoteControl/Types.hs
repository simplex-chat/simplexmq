{-# LANGUAGE CPP #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

module Simplex.RemoteControl.Types where

import Data.ByteString (ByteString)
import Simplex.Messaging.Encoding (Encoding (..))
import Simplex.Messaging.Version (VersionRange, mkVersionRange)
import UnliftIO

ipProbeVersionRange :: VersionRange
ipProbeVersionRange = mkVersionRange 1 1

data IpProbe = IpProbe
  { versionRange :: VersionRange,
    randomNonce :: ByteString
  }
  deriving (Show)

instance Encoding IpProbe where
  smpEncode IpProbe {versionRange, randomNonce} = smpEncode (versionRange, 'I', randomNonce)

  smpP = IpProbe <$> (smpP <* "I") *> smpP

-- XXX: Move to utils?
type Tasks = TVar [Async ()]

asyncRegistered :: MonadUnliftIO m => Tasks -> m () -> m ()
asyncRegistered tasks action = async action >>= registerAsync tasks

registerAsync :: MonadIO m => Tasks -> Async () -> m ()
registerAsync tasks = atomically . modifyTVar tasks . (:)

cancelTasks :: MonadIO m => Tasks -> m ()
cancelTasks tasks = readTVarIO tasks >>= mapM_ cancel
