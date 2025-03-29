{-# LANGUAGE CPP #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PostfixOperators #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}

module AgentTests (agentCoreTests, agentTests) where

import AgentTests.ConnectionRequestTests
import AgentTests.DoubleRatchetTests (doubleRatchetTests)
import AgentTests.FunctionalAPITests (functionalAPITests)
import AgentTests.MigrationTests (migrationTests)
import AgentTests.NotificationTests (notificationTests)
import AgentTests.ServerChoice (serverChoiceTests)
import AgentTests.ShortLinkTests (shortLinkTests)
import Simplex.Messaging.Server.Env.STM (AStoreType (..))
import Simplex.Messaging.Transport (ATransport (..))
import Test.Hspec
#if defined(dbPostgres)
import Fixtures
import Simplex.Messaging.Agent.Store.Postgres.Util (dropAllSchemasExceptSystem)
#else
import AgentTests.SQLiteTests (storeTests)
#endif

agentCoreTests :: Spec
agentCoreTests = do
  describe "Migration tests" migrationTests
  describe "Connection request" connectionRequestTests
  describe "Double ratchet tests" doubleRatchetTests
  describe "Short link tests" shortLinkTests

agentTests :: (ATransport, AStoreType) -> Spec
agentTests ps = do
#if defined(dbPostgres)
  after_ (dropAllSchemasExceptSystem testDBConnectInfo) $ do
#else
  do
#endif
    describe "Functional API" $ functionalAPITests ps
    describe "Chosen servers" serverChoiceTests
    describe "Notification tests" $ notificationTests ps
#if !defined(dbPostgres)
  describe "SQLite store" storeTests
#endif
