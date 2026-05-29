-- | SMP public-namespace resolver façade.
--
-- Re-exports the resolver's public surface from Names.Resolver and the
-- HTTP auth type from Names.Eth.RPC. Implementation lives in Resolver.hs;
-- Eth.RPC / Eth.SNRC are transport / codec internals.
module Simplex.Messaging.Server.Names
  ( NamesConfig (..),
    RpcAuth (..),
    NamesEnv,
    ResolveError (..),
    newNamesEnv,
    closeNamesEnv,
    resolveName,
  )
where

import Simplex.Messaging.Server.Names.Eth.RPC (RpcAuth (..))
import Simplex.Messaging.Server.Names.Resolver (NamesConfig (..), NamesEnv, ResolveError (..), closeNamesEnv, newNamesEnv, resolveName)
