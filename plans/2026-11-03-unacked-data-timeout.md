# Unacknowledged-data timeout

## Problem

A client connection to a server that becomes unreachable while data is unacknowledged is reported as failed after about 15 minutes on Linux and Android. Until then, the client sends into the dead connection.

## Cause

On Linux, TCP keep-alive probes are not sent while the connection has unacknowledged or unsent data. Such a connection is closed by the OS only after the retransmission limit: `tcp_retries2` = 15, about 15 minutes. macOS and iOS keep-alive closes it after the keep-alive time regardless of unacknowledged data.

## Fix

- `KeepAliveOpts.unackedDataTimeout :: Maybe Bool`:
  - `Just True`: on.
  - `Nothing` or `Just False`: off; JSON without the field is parsed as `Nothing`.
- `setSocketKeepAlive`, option on, Linux and Android: `TCP_USER_TIMEOUT` = `keepIdle + keepIntvl * keepCnt` seconds (90 s with `defaultKeepAliveOpts`). macOS, iOS and Windows: not set.

- `transportClientConfig`: `unackedDataTimeout = Nothing` when a SOCKS proxy is used for the host.

## Scope

- Client connections with keep-alive: SMP, NTF and XFTP clients (`transportClientConfig`).
- Unchanged:
  - outgoing connections of servers (`defaultNetworkConfig`) and remote control (`defaultTransportClientConfig`): `unackedDataTimeout = Nothing`;
  - `defaultHTTP2ClientConfig`: keep-alive not set.
