# Unacknowledged-data timeout

## Problem

On Linux and Android, a client connection to a server that becomes unreachable while data is unacknowledged fails only after about 15 minutes. Until then, the client sends into the dead connection.

## Cause

On Linux and Android, TCP keep-alive probes are not sent while the connection has unacknowledged or unsent data. Such a connection is closed only at the retransmission limit (`tcp_retries2` = 15, about 15 minutes). On macOS and iOS, a connection is closed by keep-alive `keepIdle + keepIntvl * keepCnt` after the last received segment, with or without unacknowledged data.

## Fix

- `KeepAliveOpts.unackedDataTimeout :: Maybe Bool`:
  - `Just True`: on.
  - `Nothing` or `Just False`: off; JSON without the field is parsed as `Nothing`.
- `setSocketKeepAlive`, option on:
  - Linux and Android: `TCP_USER_TIMEOUT` = `keepIdle + keepIntvl * keepCnt` seconds (90 s with the default keep-alive values).
  - macOS, iOS and Windows: not set.
- `transportClientConfig`: `unackedDataTimeout = Nothing` when a SOCKS proxy is used for the host.

## Scope

- Client connections with keep-alive: SMP, NTF and XFTP clients (`transportClientConfig`).
- Unchanged:
  - outgoing connections of servers (`defaultNetworkConfig`) and remote control (`defaultTransportClientConfig`): `unackedDataTimeout = Nothing`;
  - `defaultHTTP2ClientConfig`: keep-alive not set.
