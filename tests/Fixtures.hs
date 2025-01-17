{-# LANGUAGE CPP #-}
{-# LANGUAGE OverloadedStrings #-}

module Fixtures where

#if defined(dbPostgres)
import Data.ByteString (ByteString)
import Database.PostgreSQL.Simple (ConnectInfo (..), defaultConnectInfo)
#endif

#if defined(dbPostgres)
testDBConnstr :: ByteString
testDBConnstr = "postgresql://test_agent_user@/test_agent_db"

testDBConnectInfo :: ConnectInfo
testDBConnectInfo =
  defaultConnectInfo {
    connectUser = "test_agent_user",
    connectDatabase = "test_agent_db"
  }
#endif
