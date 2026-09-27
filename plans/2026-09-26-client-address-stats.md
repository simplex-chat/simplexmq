# Implementation plan: client address statistics

Scope:

- SMP server
- XFTP server
- NTF server

## Rules

- Counters per address are kept in memory only.
- Counters are neither saved nor restored.
- Prometheus receives aggregates across addresses only.
- Addresses are not logged.
- Addresses are shown only by a control port command.

## Address key

```
data AddrKey
  = AKIPv4 Word32
  | AKIPv6 Word64
```

Key of a socket address:

- IPv4 address: `AKIPv4`.
- IPv6 address in `::ffff:0:0/96`: `AKIPv4` of its last 32 bits.
- Other IPv6 address: `AKIPv6` of its first 64 bits.
- Other address types: not counted.

Text of a key:

- `AKIPv4`: `a.b.c.d`.
- `AKIPv6`: `xxxx:xxxx:xxxx:xxxx::/64`.

## Counters

Each server has a fixed set of counters:

```
class (Ord c, Enum c, Bounded c) => AddrCounter c where
  counterName :: c -> Text
  counterBounds :: c -> [Int]
  connectionsCounter :: c
```

`counterName` is the Prometheus label value and the control port argument.

Counters of every server:

- `connections`: connections passed to the protocol handler, after TLS setup.
- One counter per command tag, named by the tag: an attempt is counted, failed ones included.
- `errors`: parse failures and authorization failures.

Command tag types:

- SMP: `CommandTag` in `Simplex.Messaging.Protocol`.
- XFTP: `FileCommandTag` in `Simplex.FileTransfer.Protocol`.
- NTF: `NtfCommandTag` in `Simplex.Messaging.Notifications.Protocol`.

A function from a command to its counter is added for each server.

SMP proxy counters, by result of `PRXY`:

- `PRXY_own`: own server.
- `PRXY_connected`: other server with an existing connection.
- `PRXY_new`: other server with a new connection.
- `PRXY_onion`: server with onion hosts only.
- `PRXY_failed`: error.

SMP proxy counters, by result of `PFWD`:

- `PFWD_own`: own server.
- `PFWD_other`: other server.
- `PFWD_onion`: server with onion hosts only.
- `PFWD_failed`: error other than a protocol error, or no session.

Class precedence: `failed`, then `own`, then `onion`.

XFTP counters:

- `upload_kb`: kilobytes of chunks stored by successful `FPUT`.
- `download_kb`: kilobytes of chunks sent for `FGET`.
- `recipients`: recipient keys added by successful `FNEW` and `FADD`.

## Periods

- A period is a fixed interval of `period` seconds. The first period starts at server start.
- Counts of the current period are accumulated as events occur.
- Counts of the previous period are the counts of the last closed period.
- Histograms use the counts of closed periods.
- The control port command shows the previous and the current counts, sorted by their sum.

## Module `Simplex.Messaging.Server.AddressStats`

```
data AddrStats c = AddrStats
  { connectionsCount :: TVar Int,
    current :: Map c (IORef Int),
    previous :: Map c (IORef Int)
  }

type AddrStatsMap c = TMap AddrKey (AddrStats c)

data AddrHistogram = AddrHistogram
  { bucketCounts :: [Int],
    countSum :: Int,
    addressCount :: Int,
    periodMax :: Int
  }

newtype AddressStatsConfig = AddressStatsConfig
  { period :: Int64
  }
```

- `current` and `previous` contain one cell per counter, created when the address is inserted.
- `bucketCounts` are cumulative counts per bound, from server start.

Bounds:

- `countBounds`: 1 to 9, then R10 values times powers of 10, rounded half up to integers, up to 1,000,000: 60 bounds.
- `kilobyteBounds`: the same, up to 100,000,000: 80 bounds.
- R10 values: 1, 1.25, 1.6, 2, 2.5, 3.15, 4, 5, 6.3, 8.

Functions:

- `addrKey :: SockAddr -> Maybe AddrKey`
- `addrKeyText :: AddrKey -> Text`
- `counterByName :: AddrCounter c => Text -> Maybe c`
- `withAddrStats :: AddrCounter c => Maybe (AddrStatsMap c) -> Socket -> (Maybe (AddrStats c) -> IO a) -> IO a`:
  1. The peer address is read with `getPeerName`. On an exception, the connection is not counted.
  2. In one transaction, the entry is looked up or inserted, and `connectionsCount` is incremented.
  3. `connectionsCounter` is incremented.
  4. The action is run. `connectionsCount` is decremented in `finally`.
- `incAddrCounter :: AddrCounter c => AddrStats c -> c -> IO ()`
- `addAddrCounter :: AddrCounter c => AddrStats c -> c -> Int -> IO ()`
- `rolloverAddrStats :: AddrCounter c => AddrStatsMap c -> IORef (Map c AddrHistogram) -> IO ()`, in one pass over the entries, per counter:
  1. The `current` cell is set to 0. Its value is the closing count.
  2. A non-zero closing count is added to the histogram: to each bucket with a bound at or above it, to `countSum`, and to `addressCount`.
  3. `periodMax` is the largest closing count.
  4. The `previous` cell is set to the closing count.
  
  After the pass, an entry is deleted when `connectionsCount` is 0 and every closing count is 0. `connectionsCount` is read in the deleting transaction.
- `addressStatsThread :: AddrCounter c => AddressStatsConfig -> AddrStatsMap c -> IORef (Map c AddrHistogram) -> IO ()`: `rolloverAddrStats` every `period` seconds.
- `topAddresses :: AddrCounter c => AddrStatsMap c -> c -> Int -> IO [(AddrKey, Int, Int)]`: the key, previous count and current count of the counter, for up to the given number of entries, sorted by the sum of both counts, largest first. Entries with both counts 0 are excluded.
- `addrHistogramMetrics :: AddrCounter c => Text -> Map c AddrHistogram -> Text`: Prometheus text for a metric name prefix.

## Prometheus

Written with the other metrics of each server, when both `addressStats` and `prometheus_interval` are set:

```
# TYPE <prefix>_client_address_period_count histogram
<prefix>_client_address_period_count_bucket{counter="<name>",le="<bound>"} <addresses>
<prefix>_client_address_period_count_bucket{counter="<name>",le="+Inf"} <addresses>
<prefix>_client_address_period_count_sum{counter="<name>"} <sum>
<prefix>_client_address_period_count_count{counter="<name>"} <addresses>
# TYPE <prefix>_client_address_period_max gauge
<prefix>_client_address_period_max{counter="<name>"} <max>
```

Prefixes:

- `simplex_smp`
- `simplex_xftp`
- `simplex_ntf`

In scrape jobs, `convert_classic_histograms_to_nhcb: true` is set.

## Configuration

The same INI section in `smp-server.ini`, `file-server.ini` and `ntf-server.ini`:

```
[ADDRESS_STATS]
enable = off
period = 300
```

- `enable = off` or an absent section: statistics are off.
- `period`: seconds.

`iniAddressStats :: Ini -> Maybe AddressStatsConfig` is added to `Simplex.Messaging.Server.CLI`.

Added to `ServerConfig`, `XFTPServerConfig` and `NtfServerConfig`:

```
addressStats :: Maybe AddressStatsConfig
```

The section is written by the `init` command of each server with `enable = off`.

With `addressStats` set:

- an `AddrStatsMap` and a histogram reference are added to the server env
- `addressStatsThread` is added to the server threads

## Control port

Command of the SMP, XFTP and NTF control ports:

```
addresses <counter> [<n>]
```

- User role.
- `<counter>`: a counter name.
- `<n>`: number of addresses, 10 when absent.

Output of `topAddresses`:

```
address,previous,current
<key>,<count>,<count>
```

Errors:

- Unknown counter name: `error: unknown counter`.
- Statistics off: `error: address statistics are off`.

Changes:

- `CPAddresses Text (Maybe Int)` is added to `ControlProtocol` in `Simplex.Messaging.Server.Control`, `Simplex.FileTransfer.Server.Control` and `Simplex.Messaging.Notifications.Server.Control`.
- `addresses` is added to the `help` output of each control port.

## SMP server

In `Simplex.Messaging.Server`:

- `runServer`: in the branch without HTTP, `runTransportServerState_` is called with `TLSServerCredential {credential = smpCreds, sniCredential = Nothing}`. In both branches, the socket is passed to `runClient`.
- `runClient` is run in `withAddrStats`. The `AddrStats` is passed to `runClientTransport`.
- `clientAddrStats :: Maybe (AddrStats SMPAddrCounter)` is added to `Client`, as a parameter of `newClient`.
- `receive`:
  - The counter of each parsed transmission is incremented.
  - `errors` is incremented for each parse error and each failed verification.
- `processProxiedCmd`: the proxy counter is incremented when the result of `PRXY` or `PFWD` is known.

## NTF server

In `Simplex.Messaging.Notifications.Server`:

- `runServer`: `runTransportServerState_` is called with a new `SocketState` and `TLSServerCredential {credential = srvCreds, sniCredential = Nothing}`. The socket is passed to `runClient`.
- `runClient` is run in `withAddrStats`. The `AddrStats` is passed to `runNtfClientTransport`.
- `ntfClientAddrStats :: Maybe (AddrStats NtfAddrCounter)` is added to `NtfServerClient`, as a parameter of `newNtfServerClient`.
- `receive`: counting as in the SMP server.

## XFTP server

In `Simplex.Messaging.Transport.HTTP2.Server`:

- A parameter `Socket -> SessionId -> IO () -> IO ()` is added to `runHTTP2Server`. The handler of each connection is run inside it, after TLS setup.
- In `getHTTP2Server`, the wrapper only runs the handler.

In `Simplex.FileTransfer.Server`:

- `TMap SessionId (AddrStats XFTPAddrCounter)` is created in `runServer`.
- In the connection wrapper, the handler is run in `withAddrStats`. The `AddrStats` is inserted in the map before the handler, and deleted in `finally`.
- `addrStats :: Maybe (AddrStats XFTPAddrCounter)` is added to `XFTPTransportRequest`. It is looked up by session ID for each request.
- `processRequest`:
  - The counter of each decoded command is incremented.
  - `errors` is incremented for each decoding error and each failed verification.
- `upload_kb` is increased by the chunk size, rounded up to kilobytes, after a successful `FPUT`.
- `download_kb` is increased by the chunk size, rounded up to kilobytes, when an `FGET` response with the file is sent.
- `recipients` is increased by the number of recipient keys after a successful `FNEW` or `FADD`.

## Tests

`CoreTests.AddressStatsTests`:

- `addrKey`:
  - IPv4 address
  - IPv4-mapped IPv6 address
  - two IPv6 addresses in one /64: one key
  - two IPv6 addresses in different /64: two keys
- bounds:
  - `countBounds` values
  - `kilobyteBounds` values
- `counterByName` of each counter name
- `rolloverAddrStats`:
  - histogram buckets, sum, address count, and max
  - zero counts not added to histograms
  - previous counts set to closing counts
  - entry with an open connection kept
  - entry with closing counts kept
  - entry without connections and closing counts deleted
- `topAddresses`:
  - order by the sum of previous and current counts
  - number of entries limited
  - entries with both counts 0 excluded
- `addrHistogramMetrics` output
- command to counter function of each server

Server tests, with `addressStats` set and `period` 1:

- SMP basic queue tests
- SMP proxy tests
- XFTP basic file tests
- NTF basic token tests

Control port test, SMP server with `addressStats` and a control port set:

- after messages are sent, `addresses SEND` lists the test client address
- `addresses` without authentication returns `AUTH`
- `addresses` with an unknown counter returns `error: unknown counter`

`CLITests`: `enable = off` is checked in `[ADDRESS_STATS]` of each generated INI.
