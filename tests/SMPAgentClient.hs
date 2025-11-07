{-# LANGUAGE CPP #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

module SMPAgentClient where

import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as L
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import SMPClient (proxyVRangeV8, ntfTestPort, testPort)
import Simplex.Messaging.Agent.Env.SQLite
import Simplex.Messaging.Agent.Protocol
import Simplex.Messaging.Agent.RetryInterval
import Simplex.Messaging.Client (NetworkTimeout (..), ProtocolClientConfig (..), SMPProxyFallback (..), SMPProxyMode (..), defaultNetworkConfig, defaultSMPClientConfig)
import Simplex.Messaging.Notifications.Client (defaultNTFClientConfig)
import Simplex.Messaging.Protocol (NtfServer, ProtoServerWithAuth (..), ProtocolServer)
import Simplex.Messaging.Transport
import XFTPClient (testXFTPServer)

-- name fixtures are reused, but they are used as schema name instead of database file path
#if defined(dbPostgres)
testDB :: String
testDB = "smp_agent_test_protocol_schema"

testDB2 :: String
testDB2 = "smp_agent2_test_protocol_schema"

testDB3 :: String
testDB3 = "smp_agent3_test_protocol_schema"
#else
testDB :: FilePath
testDB = "tests/tmp/smp-agent.test.protocol.db"

testDB2 :: FilePath
testDB2 = "tests/tmp/smp-agent2.test.protocol.db"

testDB3 :: FilePath
testDB3 = "tests/tmp/smp-agent3.test.protocol.db"
#endif

testSMPServer :: SMPServer
testSMPServer = "smp://LcJUMfVhwD8yxjAiSaDzzGF3-kLG4Uh0Fl_ZIjrRwjI=@localhost:5001"

testSMPServer2 :: SMPServer
testSMPServer2 = "smp://LcJUMfVhwD8yxjAiSaDzzGF3-kLG4Uh0Fl_ZIjrRwjI=@127.0.0.1:5002"

testNtfServer :: NtfServer
testNtfServer = "ntf://LcJUMfVhwD8yxjAiSaDzzGF3-kLG4Uh0Fl_ZIjrRwjI=@localhost:6001"

testNtfServer2 :: NtfServer
testNtfServer2 = "ntf://LcJUMfVhwD8yxjAiSaDzzGF3-kLG4Uh0Fl_ZIjrRwjI=@localhost:6002"

initAgentServers :: InitialAgentServers
initAgentServers =
  InitialAgentServers
    { smp = userServers [testSMPServer],
      ntf = [testNtfServer],
      xftp = userServers [testXFTPServer],
      netCfg = defaultNetworkConfig {tcpTimeout = NetworkTimeout 500000 500000, tcpConnectTimeout = NetworkTimeout 500000 500000},
      useServices = M.empty,
      presetDomains = [],
      presetServers = []
    }

initAgentServers2 :: InitialAgentServers
initAgentServers2 = initAgentServers {smp = userServers [testSMPServer, testSMPServer2]}

initAgentServersProxy :: InitialAgentServers
initAgentServersProxy = initAgentServersProxy_ SPMAlways SPFProhibit

initAgentServersProxy_ :: SMPProxyMode -> SMPProxyFallback -> InitialAgentServers
initAgentServersProxy_ smpProxyMode smpProxyFallback =
  initAgentServers {netCfg = (netCfg initAgentServers) {smpProxyMode, smpProxyFallback}}

initAgentServersProxy2 :: InitialAgentServers
initAgentServersProxy2 = initAgentServersProxy {smp = userServers [testSMPServer2]}

agentCfg :: AgentConfig
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

agentProxyCfgV8 :: AgentConfig
agentProxyCfgV8 = agentCfg {smpCfg = (smpCfg agentCfg) {serverVRange = proxyVRangeV8}}

fastRetryInterval :: RetryInterval
fastRetryInterval = defaultReconnectInterval {initialInterval = 50_000}

fastMessageRetryInterval :: RetryInterval2
fastMessageRetryInterval = RetryInterval2 {riFast = fastRetryInterval, riSlow = fastRetryInterval}

userServers :: NonEmpty (ProtocolServer p) -> Map UserId (NonEmpty (ServerCfg p))
userServers = userServers' . L.map noAuthSrv

userServers' :: NonEmpty (ProtoServerWithAuth p) -> Map UserId (NonEmpty (ServerCfg p))
userServers' srvs = M.fromList [(1, L.map (presetServerCfg True (ServerRoles True True) (Just 1)) srvs)]

noAuthSrvCfg :: ProtocolServer p -> ServerCfg p
noAuthSrvCfg = presetServerCfg True (ServerRoles True True) (Just 1) . noAuthSrv
