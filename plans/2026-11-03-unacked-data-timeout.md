# Unacknowledged-data timeout

## Problem

A client connection to a server that becomes unreachable while data is unacknowledged is reported as failed after about 15 minutes on Linux and Android. Until then, the client sends into the dead connection.

## Cause

TCP keep-alive probes are not sent while the connection has unacknowledged or unsent data. Such a connection is closed by the OS only after the retransmission limit: `tcp_retries2` = 15, about 15 minutes.

## Fix

- `KeepAliveOpts.unackedDataTimeout :: Maybe Bool`:
  - `Just True`: on.
  - `Nothing` or `Just False`: off; JSON without the field is parsed as `Nothing`.
- `setSocketKeepAlive`, option on: the socket timeout for unacknowledged data is set to `keepIdle + keepIntvl * keepCnt` seconds (90 s with `defaultKeepAliveOpts`):

  | OS | Socket option | Unit |
  |---|---|---|
  | Linux, Android | `TCP_USER_TIMEOUT` | ms |
  | macOS, iOS | `TCP_RXT_CONNDROPTIME` | s |
  | Windows | not set | |

- `transportClientConfig`: `unackedDataTimeout = Nothing` when a SOCKS proxy is used for the host.

## Scope

- Client connections with keep-alive: SMP, NTF and XFTP clients (`transportClientConfig`).
- Unchanged:
  - connections without the option;
  - outgoing connections of servers (`defaultNetworkConfig`) and remote control (`defaultTransportClientConfig`): `unackedDataTimeout = Nothing`;
  - `defaultHTTP2ClientConfig`: keep-alive not set.
- Tests:
  - `tests/CoreTests/SOCKSSettings.hs`: the option is removed only with a SOCKS proxy for the host.
  - `tests/CoreTests/KeepAliveTests.hs`, Linux only: a client writing to a peer that does not read fails with `ETIMEDOUT` within 8 s with the option and keep-alive time 2 s, and does not fail within 8 s without it.
