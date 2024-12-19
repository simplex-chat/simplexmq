{-# LANGUAGE CPP #-}

module Fixtures where

#if defined(dbPostgres)
import Database.PostgreSQL.Simple (ConnectInfo (..), defaultConnectInfo)
#endif

#if defined(dbPostgres)
testDBConnectInfo :: ConnectInfo
testDBConnectInfo =
  defaultConnectInfo {
    connectUser = "test_user",
    connectDatabase = "test_agent_db"
  }
#endif
