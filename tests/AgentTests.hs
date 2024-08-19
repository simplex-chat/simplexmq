{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE PostfixOperators #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

module AgentTests (agentTests) where

import AgentTests.ConnectionRequestTests
import AgentTests.DoubleRatchetTests (doubleRatchetTests)
import AgentTests.FunctionalAPITests (functionalAPITests)
import AgentTests.MigrationTests (migrationTests)
import AgentTests.NotificationTests (notificationTests)
import AgentTests.SQLiteTests (storeTests)
import Simplex.Messaging.Transport (ATransport (..))
import Test.Hspec

agentTests :: ATransport -> Spec
agentTests (ATransport t) = do
  describe "Connection request" connectionRequestTests
  describe "Double ratchet tests" doubleRatchetTests
  describe "Functional API" $ functionalAPITests (ATransport t)
  describe "Notification tests" $ notificationTests (ATransport t)
  fdescribe "SQLite store" storeTests
  describe "Migration tests" migrationTests
