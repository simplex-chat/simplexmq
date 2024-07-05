{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}

module Simplex.Messaging.Agent.Env.KnownServer where

import Data.Int (Int64)
import Data.Text (Text)
import Simplex.Messaging.Protocol (ProtoServerWithAuth, ProtocolType (..))

data KnownServer p = KnownServer
  { server :: ProtoServerWithAuth p,
    operator :: Maybe ServerOperator
  }
  deriving (Show)

type SMPKnownServer = KnownServer 'PSMP

type XFTPKnownServer = KnownServer 'PXFTP

data ServerOperator = ServerOperator
  { operatorId :: Int64,
    operatorName :: Text
  }
