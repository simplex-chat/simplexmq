{-# LANGUAGE OverloadedStrings #-}

module Fixtures where

import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as B
import Database.PostgreSQL.Simple (ConnectInfo (..), defaultConnectInfo)
import Simplex.Messaging.Agent.Store.Postgres.Options

testDBConnstr :: ByteString
testDBConnstr = "postgresql://test_agent_user@/test_agent_db"

testDBConnectInfo :: ConnectInfo
testDBConnectInfo =
  defaultConnectInfo {
    connectUser = "test_agent_user",
    connectDatabase = "test_agent_db"
  }

testDBOpts :: String -> DBOpts
testDBOpts schema' = DBOpts testDBConnstr (B.pack schema') 1 True
