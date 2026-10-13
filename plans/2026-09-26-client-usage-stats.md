# Implementation plan: client usage statistics

Scope:

- SMP server
- XFTP server
- NTF server

## Rules

- Usage counts per client address are kept in memory only.
- Counts are neither saved nor restored.
- Prometheus receives aggregates across clients only.
- Client addresses are not logged.
- Client addresses are shown only by a control port command.

## Client address

```haskell
data ClientAddr
  = ClientIPv4 IPv4
  | ClientIPv6 (AddrRange IPv6)
```

`clientAddr :: SockAddr -> Maybe ClientAddr`:

- IPv4 address: `ClientIPv4`.
- IPv6 address in `::ffff:0:0/96`: `ClientIPv4` of its last 32 bits.
- Other IPv6 address: `ClientIPv6` of its /64 range.
- Other address types: `Nothing`.

`clientAddrText :: ClientAddr -> Text`:

- `ClientIPv4`: `192.168.1.2`.
- `ClientIPv6`: `2001:db8:1:2::/64`.

## Counters

```haskell
class (Ord c, Enum c, Bounded c) => UsageCounter c where
  counterName :: c -> Text
  counterBounds :: c -> [Int]
  counterBounds _ = countBounds
  connectionsCounter :: c
```

`counterName` is the Prometheus label value and the control port argument.

Counter types and command functions:

- SMP: `SMPUsageCounter`, `smpCmdCounter :: Cmd -> SMPUsageCounter`, in `Simplex.Messaging.Server.Env.STM`.
- XFTP: `XFTPUsageCounter`, `xftpCmdCounter :: FileCmd -> XFTPUsageCounter`, in `Simplex.FileTransfer.Server.Env`.
- NTF: `NtfUsageCounter`, `ntfCmdCounter :: NtfCmd -> NtfUsageCounter`, in `Simplex.Messaging.Notifications.Server.Env`.

Counters of every server:

- `connections`: connections passed to the protocol handler, after TLS setup.
- `errors`: parse errors and failed verifications.
- Command counters: each parsed command is counted once, failed ones included.
  - A command with its own counter: the counter named by the command tag.
  - Other commands: `other`.

Commands with their own counter:

- SMP:
  - `NEW`
  - `SUB`
  - `SEND`
  - `PFWD`
  - `RFWD`
  - `RSLV`
- XFTP:
  - `FNEW`
- NTF:
  - `TNEW`
  - `TRPL`
  - `SNEW`

SMP proxy counters:

- `PRXY_new`: `PRXY` accepted by `allowProxy`, without a connected relay or an unexpired relay connection error.
- `PRXY_failed`: `PRXY` accepted by `allowProxy`, with a response other than `PKEY`.
- `PFWD_failed`: `PFWD` with an error other than a protocol error, or without a session.

XFTP counters:

- `upload_kb`: kilobytes of chunks stored by successful `FPUT`.
- `download_kb`: kilobytes of chunks in prepared `FGET` responses with the file.
- `recipients`: recipient keys added by successful `FNEW` and `FADD`.

Bounds:

- `upload_kb`, `download_kb`: `kilobyteBounds`.
- Other counters: `countBounds`.

## Periods

- Periods are closed every `period` seconds from server start.
- Current counts are increased by `addUsage`.
- Previous counts are the counts of the last closed period.
- The counts of closed periods are accumulated in histograms.

## Module `Simplex.Messaging.Server.UsageStats`

```haskell
data UsageStats c = UsageStats
  { clientCounts :: TMap ClientAddr (ClientCounts c),
    histograms :: IORef (Map c UsageHistogram)
  }

data ClientCounts c = ClientCounts
  { current :: TMap c (TVar Int),
    previous :: TVar (Map c Int)
  }

data ClientUsage c = ClientUsage (UsageStats c) ClientAddr

data UsageHistogram = UsageHistogram
  { bucketCounts :: IM.IntMap Int,
    usageSum :: Int,
    lastPeriodMax :: Int
  }
```

- `current`, `previous`: counts by counter. The count of a counter without a key is 0.
- `bucketCounts`: client counts by bucket index, from server start. The bucket index of a count is the number of bounds below it.

Bounds:

- `countBounds`: 1 to 9, then R10 values times powers of 10, rounded half up, up to 1,000,000: 60 bounds.
- `kilobyteBounds`: the same, up to 100,000,000: 80 bounds.
- R10 values: 1, 1.25, 1.6, 2, 2.5, 3.15, 4, 5, 6.3, 8.

Functions:

- `newUsageStats :: UsageCounter c => IO (UsageStats c)`
- `counterByName :: UsageCounter c => Text -> Maybe c`
- `clientConnected :: UsageCounter c => Socket -> Maybe (UsageStats c) -> IO (Maybe (ClientUsage c))`:
  1. Without `UsageStats`: `Nothing`.
  2. The peer address is read with `getPeerName`.
  3. On an exception or an address type without `ClientAddr`: `Nothing`.
  4. `connectionsCounter` is incremented.
- `incUsage :: UsageCounter c => ClientUsage c -> c -> IO ()`
- `addUsage :: UsageCounter c => ClientUsage c -> c -> Int -> IO ()`:
  1. The client entry is read with `TM.lookupIO`.
  2. An absent entry is created, then looked up or inserted in one transaction.
  3. The counter is read from `current` with `TM.lookupIO`.
  4. An absent counter is looked up or inserted with the evaluated amount in one transaction.
  5. A present counter is increased with `modifyTVar'`.
  
  The amount is positive at every call site.
- `closeUsagePeriod :: UsageCounter c => UsageStats c -> IO ()`, per client:
  1. In one transaction:
     - `current` is set to an empty map; the counts of its counters are the closed counts;
     - `previous` is set to the closed counts.
  2. The entry is deleted when the closed counts are empty.
  
  Then, per counter, the histogram is updated with the closed counts:
  - `bucketCounts`: 1 is added at the bucket index of each count
  - `usageSum`: the counts are added
  
  `lastPeriodMax` is set to the largest closed count, 0 without closed counts.
- `usagePeriodThread :: UsageCounter c => Int64 -> UsageStats c -> IO ()`: `closeUsagePeriod` every `period` seconds.
- `topClients :: UsageCounter c => UsageStats c -> c -> Int -> IO [(ClientAddr, Int, Int)]`:
  - address, previous count, current count
  - sorted by the sum of both counts, largest first
  - clients with sum 0 excluded
  - limited to the given number
- `printTopClients :: UsageCounter c => Handle -> Text -> Maybe Int -> Maybe (UsageStats c) -> IO ()`: control port output.
- `usageMetrics :: UsageCounter c => Text -> Text -> Map c UsageHistogram -> Text`: Prometheus text for a metric prefix and a timestamp. The `_bucket` sample of the bound at index i is the sum of `bucketCounts` at indexes 0 to i. The `+Inf` and `_count` samples are the sum of `bucketCounts`.

Counts lost in `closeUsagePeriod`:

- a count added after the closing transaction to an entry deleted after it;
- a count added after the closing transaction to a counter read with `TM.lookupIO` before it.

## Prometheus

Written with the other metrics of each server, when usage statistics and `prometheus_interval` are both enabled:

```
# Client usage
# ------------

# HELP <prefix>_client_usage Clients by usage in a period
# TYPE <prefix>_client_usage histogram
<prefix>_client_usage_bucket{counter="<name>",le="<bound>"} <clients> <ts>
<prefix>_client_usage_bucket{counter="<name>",le="+Inf"} <clients> <ts>
<prefix>_client_usage_sum{counter="<name>"} <sum> <ts>
<prefix>_client_usage_count{counter="<name>"} <clients> <ts>

# HELP <prefix>_client_usage_max Largest usage of one client in the last period
# TYPE <prefix>_client_usage_max gauge
<prefix>_client_usage_max{counter="<name>"} <max> <ts>
```

Prefixes:

- `simplex_smp`
- `simplex_xftp`
- `simplex_ntf`

Field added to the metrics record of each server:

```haskell
usageHistograms :: Maybe (Map <counter type> UsageHistogram)
```

Metrics records:

- SMP: `RealTimeMetrics`
- XFTP: `FileServerMetrics`
- NTF: `NtfRealTimeMetrics`

In scrape jobs, `convert_classic_histograms_to_nhcb: true` is set.

## Configuration

The same INI section in `smp-server.ini`, `file-server.ini` and `ntf-server.ini`:

```
[USAGE_STATS]
enable = off
period = 300
```

- `enable = off` or an absent section: statistics are off.
- `period`: seconds, 300 when absent.

Added to `Simplex.Messaging.Server.CLI`:

- `iniUsageStatsPeriod :: Ini -> Maybe Int64`
- `usageStatsIniContent :: Text`: the section, written by `init` of each server.

Field added to `ServerConfig`, `XFTPServerConfig` and `NtfServerConfig`:

```haskell
usageStatsPeriod :: Maybe Int64
```

Field added to `Env`, `XFTPEnv` and `NtfEnv`, set when `usageStatsPeriod` is set:

```haskell
usageStats :: Maybe (UsageStats <counter type>)
```

`usagePeriodThread` is added to the server threads when `usageStatsPeriod` is set.

## Control port

Command of the SMP, XFTP and NTF control ports:

```
usage <counter> [<n>]
```

- User role.
- `<counter>`: a counter name.
- `<n>`: number of clients, 10 when absent.

Output:

```
address,previous,current
<address>,<count>,<count>
```

Errors:

- Unknown counter name: `error: unknown counter`.
- Statistics off: `error: usage statistics are off`.

`CPUsage Text (Maybe Int)` is added to `ControlProtocol` in:

- `Simplex.Messaging.Server.Control`
- `Simplex.FileTransfer.Server.Control`
- `Simplex.Messaging.Notifications.Server.Control`

`usage` is added to the `help` output of each control port.

## SMP server

In `Simplex.Messaging.Server`:

- `runServer`: in the branch without HTTP, `runTransportServerState_` is called with `TLSServerCredential {credential = smpCreds, sniCredential = Nothing}`. In both branches, the socket is passed to `runClient`.
- `runClient`: `clientConnected` is called before the handshake. Its result is passed to `runClientTransport`.
- `clientUsage :: Maybe (ClientUsage SMPUsageCounter)` is added to `Client`, as the last parameter of `newClient`.
- `receive`:
  - Before verification, the counter of each parsed command is incremented.
  - After verification, `errors` is increased by the number of error responses.
- `processProxiedCmd`:
  - `PRXY_new` is incremented before the connection to the relay is forked.
  - `incFailed own sel`: the proxy stat `sel` and `PRXY_failed` or `PFWD_failed` are incremented.
- `processForwardedCommand`: the command forwarded in `RFWD` and its errors are not counted.

## NTF server

In `Simplex.Messaging.Notifications.Server`:

- `runServer`: `runTransportServerState_` is called with a new `SocketState` and `TLSServerCredential {credential = srvCreds, sniCredential = Nothing}`. The socket is passed to `runClient`.
- `runClient`: `clientConnected` is called before the handshake. Its result is passed to `runNtfClientTransport`.
- `clientUsage :: Maybe (ClientUsage NtfUsageCounter)` is added to `NtfServerClient`, as the last parameter of `newNtfServerClient`.
- `receive`, after verification:
  - `errors` is increased by the number of error responses.
  - The counter of each parsed command is incremented.

## XFTP server

In `Simplex.FileTransfer.Server`, `runServer` is composed of:

- `runTransportServerState_` with a new `SocketState` and `TLSServerCredential {credential = srvCreds, sniCredential = httpCreds_}`
- per connection, `runClient`:
  1. `clientConnected`
  2. `runHTTP2ServerWith_` with `($ h)` as the setup and the request handler with the `ClientUsage` of the connection

Other changes:

- `clientUsage :: Maybe (ClientUsage XFTPUsageCounter)` is added to `XFTPTransportRequest`.
- `processRequest`:
  - The counter of each decoded command is incremented.
  - `errors` is incremented for each block size error, decoding error and failed verification.
- `processXFTPRequest` has the `ClientUsage` as a parameter:
  - `upload_kb` is increased after the chunk is stored by a successful `FPUT`.
  - `download_kb` is increased when the `FGET` response with the file is prepared.
  - `recipients` is increased after a successful `FNEW` or `FADD`.

## Tests

`CoreTests.UsageStatsTests`:

- `clientAddr`:
  - IPv4 address
  - IPv4-mapped IPv6 address
  - two IPv6 addresses in one /64: one address
  - two IPv6 addresses in different /64: two addresses
  - other address types: `Nothing`
- bounds:
  - `countBounds` values
  - `kilobyteBounds` values
- `counterByName`:
  - each counter name
  - unknown name: `Nothing`
- `addUsage`: one entry per address
- `closeUsagePeriod`:
  - histogram buckets, sum and max
  - counters without counts excluded from histograms
  - previous counts set to closed counts
  - clients without counts in the closed period deleted
  - a period with counts of 40000 clients closed within 5 seconds
- `topClients`:
  - order by the sum of previous and current counts
  - number of clients limited
  - clients with both counts 0 excluded
- `usageMetrics` output
- command function of each server: counter named by the command tag or `other`

`usageStatsPeriod = Just 1` is set in the default test configurations of the SMP, XFTP and NTF servers.

Control port tests, with `usageStatsPeriod = Just 300`:

- SMP server:
  - output of `usage SEND`, `usage errors` and `usage connections`: the test client address
  - output of `usage SEND 0`: the header only
  - output of `usage` without authentication: `AUTH`
  - output of `usage` with an unknown counter: `error: unknown counter`
- SMP proxy: `other`, `PRXY_new`, `PRXY_failed`, `PFWD` and `PFWD_failed`.
- XFTP server: command, error, connection, transfer and recipient counters.
- NTF server: command, error and connection counters.

Other tests:

- `testPrometheusMetrics`: the histogram type line is checked in the metrics file.
- `testServiceSubsTotalCount`: the metrics file is read strictly.
- `CLITests`: `enable = off` and `period = 300` are checked in `[USAGE_STATS]` of each generated INI.
