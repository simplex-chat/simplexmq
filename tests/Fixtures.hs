{-# LANGUAGE OverloadedStrings #-}

module Fixtures where

import Data.ByteString (ByteString)
import Database.PostgreSQL.Simple (ConnectInfo (..), defaultConnectInfo)

testDBConnstr :: ByteString
testDBConnstr = "postgresql://test_agent_user@/test_agent_db"

testDBConnectInfo :: ConnectInfo
testDBConnectInfo =
  defaultConnectInfo {
    connectUser = "test_agent_user",
    connectDatabase = "test_agent_db"
  }
