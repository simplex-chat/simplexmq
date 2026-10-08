{-# LANGUAGE CPP #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

module SMPAgentClient where

import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as L
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import SMPClient (ntfTestPort, ntfTestPort2, testHost, testHost2, testKeyHash, testPort, testPort2)
import Simplex.Messaging.Agent.Env.SQLite
import Simplex.Messaging.Agent.Protocol
import Simplex.Messaging.Agent.RetryInterval
import Simplex.Messaging.Client (NetworkTimeout (..), ProtocolClientConfig (..), SMPProxyFallback (..), SMPProxyMode (..), defaultNetworkConfig, defaultSMPClientConfig)
import Simplex.Messaging.Notifications.Client (defaultNTFClientConfig)
import Simplex.Messaging.Protocol (NtfServer, ProtoServerWithAuth (..), ProtocolServer, pattern NtfServer)
import Simplex.Messaging.Transport
import Util
import XFTPClient (testXFTPServer)

-- name fixtures are reused, but they are used as schema name instead of database file path
#if defined(dbPostgres)
testDB :: HasTestEnv => String
testDB = testSchemaName "smp_agent_test_protocol_schema"

testDB2 :: HasTestEnv => String
testDB2 = testSchemaName "smp_agent2_test_protocol_schema"

testDB3 :: HasTestEnv => String
testDB3 = testSchemaName "smp_agent3_test_protocol_schema"
#else
testDB :: HasTestEnv => FilePath
testDB = testPath "smp-agent.test.protocol.db"

testDB2 :: HasTestEnv => FilePath
testDB2 = testPath "smp-agent2.test.protocol.db"

testDB3 :: HasTestEnv => FilePath
testDB3 = testPath "smp-agent3.test.protocol.db"
#endif

testSMPServer :: HasTestEnv => SMPServer
testSMPServer = SMPServer testHost testPort testKeyHash

testSMPServer2 :: HasTestEnv => SMPServer
testSMPServer2 = SMPServer testHost2 testPort2 testKeyHash

testNtfServer :: HasTestEnv => NtfServer
testNtfServer = NtfServer testHost ntfTestPort testKeyHash

testNtfServer2 :: HasTestEnv => NtfServer
testNtfServer2 = NtfServer testHost ntfTestPort2 testKeyHash

initAgentServers :: HasTestEnv => InitialAgentServers
initAgentServers =
  InitialAgentServers
    { smp = userServers [testSMPServer],
      ntf = [testNtfServer],
      xftp = userServers [testXFTPServer],
      entitlements = M.empty,
      netCfg = defaultNetworkConfig {tcpTimeout = NetworkTimeout 500000 500000, tcpConnectTimeout = NetworkTimeout 500000 500000},
      useServices = M.empty,
      presetDomains = [],
      presetServers = []
    }

initAgentServers2 :: HasTestEnv => InitialAgentServers
initAgentServers2 = initAgentServers {smp = userServers [testSMPServer, testSMPServer2]}

initAgentServersProxy :: HasTestEnv => InitialAgentServers
initAgentServersProxy = initAgentServersProxy_ SPMAlways SPFProhibit

initAgentServersProxy_ :: HasTestEnv => SMPProxyMode -> SMPProxyFallback -> InitialAgentServers
initAgentServersProxy_ smpProxyMode smpProxyFallback =
  initAgentServers {netCfg = (netCfg initAgentServers) {smpProxyMode, smpProxyFallback}}

initAgentServersProxy2 :: HasTestEnv => InitialAgentServers
initAgentServersProxy2 = initAgentServersProxy {smp = userServers [testSMPServer2]}

initAgentServersClientService :: HasTestEnv => InitialAgentServers
initAgentServersClientService = initAgentServers {useServices = M.fromList [(1, True)]}

agentCfg :: HasTestEnv => AgentConfig
agentCfg =
  defaultAgentConfig
    { tcpPort = Nothing,
      tbqSize = 4,
      -- database = testDB,
      smpCfg = defaultSMPClientConfig {qSize = 1, defaultTransport = (testPort, transport @TLS), networkConfig},
      ntfCfg = defaultNTFClientConfig {qSize = 1, defaultTransport = (ntfTestPort, transport @TLS), networkConfig},
      reconnectInterval = fastRetryInterval,
      persistErrorInterval = 1,
      caCertificateFile = "tests/fixtures/ca.crt",
      privateKeyFile = "tests/fixtures/server.key",
      certificateFile = "tests/fixtures/server.crt"
    }
  where
    networkConfig = defaultNetworkConfig {tcpConnectTimeout = NetworkTimeout 1_000000 1_000000, tcpTimeout = NetworkTimeout 2_000000 2_000000}

fastRetryInterval :: RetryInterval
fastRetryInterval = defaultReconnectInterval {initialInterval = 50_000}

fastMessageRetryInterval :: RetryInterval2
fastMessageRetryInterval = RetryInterval2 {riFast = fastRetryInterval, riSlow = fastRetryInterval}

userServers :: NonEmpty (ProtocolServer p) -> Map UserId (NonEmpty (ServerCfg p))
userServers = userServers' . L.map noAuthSrv

userServers' :: NonEmpty (ProtoServerWithAuth p) -> Map UserId (NonEmpty (ServerCfg p))
userServers' srvs = M.fromList [(1, L.map (presetServerCfg True (ServerRoles True True True) (Just 1)) srvs)]

noAuthSrvCfg :: ProtocolServer p -> ServerCfg p
noAuthSrvCfg = presetServerCfg True (ServerRoles True True True) (Just 1) . noAuthSrv
