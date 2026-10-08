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
import AgentTests.ResolveNameTests (resolveNameTests)
import AgentTests.ServerChoice (serverChoiceTests)
import AgentTests.ShortLinkTests (shortLinkTests)
import Simplex.Messaging.Server.Env.STM (AStoreType (..))
import Simplex.Messaging.Transport (ASrvTransport)
import Test.Hspec hiding (fit, it)

#if !defined(dbPostgres)
import AgentTests.SQLiteTests (storeTests)
#endif

#if defined(dbServerPostgres)
import AgentTests.NotificationTests (notificationTests)
#endif

agentCoreTests :: Spec
agentCoreTests = do
  describe "Migration tests" migrationTests
  describe "Connection request" connectionRequestTests
  describe "Double ratchet tests" doubleRatchetTests
  describe "Short link tests" shortLinkTests
  describe "resolve names" resolveNameTests

agentTests :: (ASrvTransport, AStoreType) -> Spec
agentTests ps = do
  describe "Functional API" $ functionalAPITests ps
  describe "Chosen servers" serverChoiceTests
#if defined(dbServerPostgres)
  describe "Notification tests" $ notificationTests ps
#endif
#if !defined(dbPostgres)
  describe "SQLite store" storeTests
#endif
