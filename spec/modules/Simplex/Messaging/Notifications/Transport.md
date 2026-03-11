# Simplex.Messaging.Notifications.Transport

> Notification Router Protocol transport: manages push notification subscriptions between client and NTF Router.

**Source**: [`Notifications/Transport.hs`](../../../../../src/Simplex/Messaging/Notifications/Transport.hs)

**Protocol spec**: [`protocol/push-notifications.md`](../../../../../protocol/push-notifications.md) — SimpleX Notification Router protocol.

## Overview

This module implements the transport layer for the **Notification Router Protocol**. Per the protocol spec: "To manage notification subscriptions to SMP routers, SimpleX Notification Router provides an RPC protocol with a similar design to SimpleX Messaging Protocol router."

The protocol spec diagram shows three separate protocols in the notification flow:
1. **Notification Router Protocol** (this module): client ↔ SimpleX Notification Router — subscription management
2. **SMP protocol**: SMP Router → SimpleX Notifications Subscriber — notification signals
3. **Push provider** (e.g., APN): SimpleX Push Router → device — per the spec: "the notifications are e2e encrypted between SimpleX Notification Router and the user's device"

## Differences from SMP transport

The NTF protocol reuses SMP's transport infrastructure but with reduced parameters:

| Property | SMP | NTF |
|----------|-----|-----|
| Block size | 16384 | 512 |
| Block encryption | Yes (v11+) | No (`encryptBlock = Nothing`) |
| Service certificates | Yes (v16+) | No (`serviceAuth = False`) |
| Version range | 6–19 | 1–3 |
| Handshake messages | 2–3 | 2 |

## Same ALPN/legacy fallback pattern as SMP

`ntfServerHandshake` uses the same pattern as `smpServerHandshake`: if ALPN is not negotiated (`getSessionALPN` returns `Nothing`), the server offers only `legacyServerNTFVRange` (v1 only).

## NTF handshake uses SMP shared types

The handshake reuses SMP's `THandle`, `THandleParams`, `THandleAuth` types. The `encodeAuthEncryptCmds` and `authEncryptCmdsP` helper functions are defined locally in this module (with NTF-specific version thresholds). NTF never sets `sessSecret` / `sessSecret'`, `peerClientService`, or `clientService` — these are always `Nothing`.
