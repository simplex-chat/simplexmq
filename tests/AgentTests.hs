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
import AgentTests.ServerChoice (serverChoiceTests)
import Simplex.Messaging.Transport (ATransport (..))
import Test.Hspec
#if defined(dbPostgres)
import Fixtures
import Simplex.Messaging.Agent.Store.Postgres (dropAllSchemasExceptSystem)
#else
import AgentTests.NotificationTests (notificationTests)
import AgentTests.SQLiteTests (storeTests)
#endif

agentTests :: ATransport -> Spec
agentTests (ATransport t) = do
  describe "Connection request" connectionRequestTests
  describe "Double ratchet tests" doubleRatchetTests
#if defined(dbPostgres)
  after_ (dropAllSchemasExceptSystem testDBConnectInfo) $
    describe "Functional API" $ functionalAPITests (ATransport t)
#else
  describe "Functional API" $ functionalAPITests (ATransport t)
  describe "Notification tests" $ notificationTests (ATransport t)
  describe "SQLite store" storeTests
#endif
  describe "Chosen servers" serverChoiceTests
  describe "Migration tests" migrationTests
