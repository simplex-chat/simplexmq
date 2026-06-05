{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Single source of truth for TLD -> SNRC contract address.
-- Both the agent (which sends the contract in RslvRequest so the server
-- can refuse mismatched calls) and the server (which checks the
-- client-supplied contract against this mapping in verifyRslv) read
-- from here. Lock-step bumps land in one place.
module Simplex.Messaging.SimplexName.Contracts
  ( tldContract,
  )
where

import qualified Data.ByteString.Char8 as B
import Simplex.Messaging.Names.Owner (NameOwner, mkNameOwner)
import Simplex.Messaging.SimplexName (SimplexTLD (..))

-- | Map a TLD to its SNRC contract address. `Nothing` means the TLD has
-- no SimpleX-native registry (e.g., `TLDWeb` is reserved for external
-- web domains and never resolved on-chain via this stack).
--
-- Both bytes are placeholders pending the live SNRC deployment; update
-- here and the change is observed atomically by agent and server.
tldContract :: SimplexTLD -> Maybe NameOwner
tldContract = \case
  TLDSimplex -> Just (placeholder '\x11')
  TLDTesting -> Just (placeholder '\x22')
  TLDWeb -> Nothing
  where
    placeholder c = either error id (mkNameOwner (B.replicate 20 c))
