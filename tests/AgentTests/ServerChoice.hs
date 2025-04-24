{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE OverloadedStrings #-}

module AgentTests.ServerChoice where

import AgentTests.FunctionalAPITests
import Control.Monad.IO.Class
import Data.List.NonEmpty (NonEmpty (..))
import qualified Data.Map.Strict as M
import SMPAgentClient
import Simplex.Messaging.Agent (withAgentEnv)
import Simplex.Messaging.Agent.Client hiding (userServers)
import Simplex.Messaging.Agent.Env.SQLite
import Simplex.Messaging.Client (defaultNetworkConfig)
import Simplex.Messaging.Protocol
import Test.Hspec
import Test.QuickCheck
import XFTPClient (testXFTPServer)

serverChoiceTests :: Spec
serverChoiceTests = do
  describe "Server operators" $ do
    it "should choose server of different operator" $ ioProperty $ testChooseDifferentOperator

operatorSimpleX :: Maybe OperatorId
operatorSimpleX = Just 1

operator2 :: Maybe OperatorId
operator2 = Just 2

testOp1Srv1 :: ProtoServerWithAuth 'PSMP
testOp1Srv1 = "smp://LcJU@test1.simplex.im"

testOp1Srv2 :: ProtoServerWithAuth 'PSMP
testOp1Srv2 = "smp://LcJU@test2.simplex.im"

testOp2Srv1 :: ProtoServerWithAuth 'PSMP
testOp2Srv1 = "smp://LcJU@srv1.example.com"

testOp2Srv2 :: ProtoServerWithAuth 'PSMP
testOp2Srv2 = "smp://LcJU@srv2.example.com"

testSMPServers :: NonEmpty (ServerCfg 'PSMP)
testSMPServers =
  [ presetServerCfg True allRoles operatorSimpleX testOp1Srv1,
    presetServerCfg True allRoles operatorSimpleX testOp1Srv2,
    presetServerCfg True proxyOnly operator2 testOp2Srv1,
    presetServerCfg True proxyOnly operator2 testOp2Srv2
  ]

storageOnly :: ServerRoles
storageOnly = ServerRoles {storage = True, proxy = False}

proxyOnly :: ServerRoles
proxyOnly = ServerRoles {storage = False, proxy = True}

initServers :: InitialAgentServers
initServers =
  InitialAgentServers
    { smp = M.fromList [(1, testSMPServers)],
      ntf = [testNtfServer],
      xftp = userServers [testXFTPServer],
      netCfg = defaultNetworkConfig,
      presetDomains = []
    }

testChooseDifferentOperator :: IO ()
testChooseDifferentOperator = do
  c <- getSMPAgentClient' 1 agentCfg initServers testDB
  runRight_ $ do
    -- chooses the only operator with storage role
    srv1 <- withAgentEnv c $ getNextServer c 1 storageSrvs []
    liftIO $ srv1 == testOp1Srv1 || srv1 == testOp1Srv2 `shouldBe` True
    -- chooses another server for storage
    srv2 <- withAgentEnv c $ getNextServer c 1 storageSrvs [protoServer testOp1Srv1]
    liftIO $ srv2 `shouldBe` testOp1Srv2
    -- chooses another operator for proxy
    srv3 <- withAgentEnv c $ getNextServer c 1 proxySrvs [protoServer srv1]
    liftIO $ srv3 == testOp2Srv1 || srv3 == testOp2Srv2 `shouldBe` True
    -- chooses another operator for proxy
    srv3' <- withAgentEnv c $ getNextServer c 1 proxySrvs [protoServer testOp1Srv1, protoServer testOp1Srv2]
    liftIO $ srv3' == testOp2Srv1 || srv3' == testOp2Srv2 `shouldBe` True
    -- chooses any other server
    srv4 <- withAgentEnv c $ getNextServer c 1 proxySrvs [protoServer testOp1Srv1, protoServer testOp2Srv1]
    liftIO $ srv4 == testOp1Srv2 || srv4 == testOp2Srv2 `shouldBe` True
