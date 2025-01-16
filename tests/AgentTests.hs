{-# LANGUAGE CPP #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PostfixOperators #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}

module AgentTests (agentTests) where

import AgentTests.ConnectionRequestTests
import AgentTests.DoubleRatchetTests (doubleRatchetTests)
import AgentTests.FunctionalAPITests (functionalAPITests)
import AgentTests.MigrationTests (migrationTests)
import AgentTests.NotificationTests (notificationTests)
import AgentTests.ServerChoice (serverChoiceTests)
import Simplex.Messaging.Transport (ATransport (..))
import Test.Hspec
#if defined(dbPostgres)
import Fixtures
import Simplex.Messaging.Agent.Store.Postgres.Util (dropAllSchemasExceptSystem)
#else
import AgentTests.SQLiteTests (storeTests)
#endif

agentTests :: ATransport -> Spec
agentTests (ATransport t) = do
  describe "Migration tests" migrationTests
  describe "Connection request" connectionRequestTests
  describe "Double ratchet tests" doubleRatchetTests
#if defined(dbPostgres)
  after_ (dropAllSchemasExceptSystem testDBConnectInfo) $ do
#else
  do
#endif
    describe "Functional API" $ functionalAPITests (ATransport t)
    describe "Chosen servers" serverChoiceTests
    fdescribe "Notification tests" $ notificationTests (ATransport t)
#if !defined(dbPostgres)
  describe "SQLite store" storeTests
#endif
