{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

-- | A latency-injecting Transport for the memory-leak bench.
--
-- 'LagTLS' is a newtype over 'TLS' that delegates every 'Transport' method, adding a
-- configurable delay before each read and write and optionally swallowing writes. It is
-- wire-identical to 'TLS' - 'transportName' is only used for thread labels and logging, so a
-- peer speaking plain TLS interoperates with it unchanged.
--
-- Used as the destination relay's listener transport so that proxy->relay traffic can be
-- delayed without touching the proxy, the clients, or any production code:
--
-- > withSmpServerConfigOn (transport @TLS) proxyCfg testPort $ \_ ->
-- >   withSmpServerConfigOn (transport @LagTLS) cfgJ2 testPort2 $ \_ -> ...
--
-- 'setDropSnd' keeps the TLS session healthy while responses vanish, which is what the
-- proxy sentCommands leak needs: the relay must stay up and stop answering, so the proxy's
-- RFWD requests time out without the client being torn down.
--
-- Delays apply to the SMP handshake as well as to post-handshake traffic (both go through
-- cGet/cPut), so phases that need an established session must connect first and arm the lag
-- afterwards.
module NetLag
  ( LagTLS,
    setLag,
    setDropSnd,
    setDropEvery,
    clearLag,
  )
where

import Control.Concurrent (threadDelay)
import Control.Concurrent.STM
import Control.Monad (unless, when)
import Data.ByteString.Char8 (ByteString)
import Simplex.Messaging.Transport
import System.IO.Unsafe (unsafePerformIO)

newtype LagTLS (p :: TransportPeer) = LagTLS (TLS p)

data LagCtl = LagCtl
  { rcvDelayUs :: TVar Int,
    sndDelayUs :: TVar Int,
    dropSnd :: TVar Bool,
    -- drop every nth write, 0 disables. Distinct from dropSnd: dropping everything makes the
    -- peer's monitor eventually tear the session down, while dropping a fraction keeps the
    -- session healthy indefinitely because any reply resets its counters.
    dropEvery :: TVar Int,
    sndSeq :: TVar Int
  }

-- A single process-wide control: getTransportConnection has nowhere to thread per-listener
-- state through, and the bench runs one lagged relay at a time.
lagCtl :: LagCtl
lagCtl =
  unsafePerformIO $
    LagCtl <$> newTVarIO 0 <*> newTVarIO 0 <*> newTVarIO False <*> newTVarIO 0 <*> newTVarIO 0
{-# NOINLINE lagCtl #-}

-- | One-way delays in microseconds: inbound (peer -> this transport) and outbound.
setLag :: Int -> Int -> IO ()
setLag rcv snd' = atomically $ do
  writeTVar (rcvDelayUs lagCtl) rcv
  writeTVar (sndDelayUs lagCtl) snd'

-- | Silently discard everything written. The session stays open and the peer keeps waiting.
setDropSnd :: Bool -> IO ()
setDropSnd b = atomically $ writeTVar (dropSnd lagCtl) b

-- | Silently discard every nth write, passing the rest. 0 disables.
setDropEvery :: Int -> IO ()
setDropEvery n = atomically $ writeTVar (dropEvery lagCtl) n

clearLag :: IO ()
clearLag = setLag 0 0 >> setDropSnd False >> setDropEvery 0

delayBy :: TVar Int -> IO ()
delayBy v = do
  d <- readTVarIO v
  when (d > 0) $ threadDelay d

instance Transport LagTLS where
  transportName _ = "LagTLS"
  transportConfig (LagTLS t) = transportConfig t
  getTransportConnection cfg sent chain ctx = LagTLS <$> getTransportConnection cfg sent chain ctx
  certificateSent (LagTLS t) = certificateSent t
  getPeerCertChain (LagTLS t) = getPeerCertChain t
  getSessionALPN (LagTLS t) = getSessionALPN t
  tlsUnique (LagTLS t) = tlsUnique t
  closeConnection (LagTLS t) = closeConnection t

  cGet :: LagTLS p -> Int -> IO ByteString
  cGet (LagTLS t) n = delayBy (rcvDelayUs lagCtl) >> cGet t n

  cPut :: LagTLS p -> ByteString -> IO ()
  cPut (LagTLS t) s = do
    delayBy (sndDelayUs lagCtl)
    drop' <- atomically $ do
      always <- readTVar (dropSnd lagCtl)
      every <- readTVar (dropEvery lagCtl)
      i <- stateTVar (sndSeq lagCtl) $ \n -> let n' = n + 1 in (n', n')
      pure $ always || (every > 0 && i `mod` every == 0)
    unless drop' $ cPut t s

  getLn :: LagTLS p -> IO ByteString
  getLn (LagTLS t) = delayBy (rcvDelayUs lagCtl) >> getLn t
