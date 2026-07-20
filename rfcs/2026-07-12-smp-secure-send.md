---
Proposed: 2026-07-12
Protocol: smp (new version)
---

# SSND: combined secure-and-send command

## Problem

Two SMP flows secure a messaging queue and then immediately send the first message to it, as two commands and two round trips:

- The fast connection handshake: the joining party secures the queue with `SKEY`, then sends the confirmation with `SEND`.
- Any first send to a sender-securable queue where the sender both secures it and delivers the first message.

The two commands express one intent - "this is my key, and here is my first message" - so they can be one command and one round trip. The combination must be idempotent, because the first send is retried on network failure and a queue is often secured before the response is known. `SKEY` is already idempotent (a repeat with the same key succeeds). `SEND` is not, so a naive combination would deliver a duplicate message on retry.

## Solution

A new command `SSND` combines `SKEY` and `SEND` in one transmission, idempotent in both parts:

- Key part: as `SKEY` - a repeat with the same key succeeds, a different key fails with `AUTH`.
- Send part: the server keeps the hash of the message until it is acknowledged, and reports a repeat of the same message as delivered without delivering it again.

The server-side hash covers the common case, when the retry arrives before the message is acknowledged. A retry that arrives after the acknowledgement is delivered as a duplicate and discarded by the receiving agent by message hash, as duplicate messages are discarded today.

## Design

Syntax uses [ABNF][1] with [case-sensitive strings extension][2]. `senderAuthPublicKey`, `msgFlags` and `smpEncMessage` are as in the [SMP protocol](../protocol/simplex-messaging.md).

```abnf
secureSend = %s"SSND " senderAuthPublicKey SP msgFlags SP smpEncMessage
senderAuthPublicKey = length x509encoded
```

`SSND` is a sender command, authorized with the key it sets, and accepted only on messaging-mode queues (`QMMessaging`), where the sender can secure the queue. The server responds `OK` or `ERR`.

Server processing:

1. Secure the queue with the key, as `SKEY`. A repeat with the same key succeeds; a different key returns `AUTH`.
2. If the queue holds an unacknowledged message whose stored hash equals the hash of this message, respond `OK` without storing it again.
3. Otherwise store the message, keep its hash with the queue until the message is acknowledged, and deliver it.

The stored hash is one value per not-yet-acknowledged queue message. It is removed when the message is acknowledged. All queue store backends (in-memory, journal, PostgreSQL) keep it.

`SSND` composes with the proxy protocol without change: `proxySMPCommand` forwards any sender command through `PFWD`/`RFWD`, so `SSND` is proxied as `SEND` and `SKEY` are today.

## Uses

- The fast connection handshake replaces `SKEY` then the `SEND` confirmation with one `SSND`.
- The service RPC response (see the RPC RFC) secures the reply queue and sends the first reply with one `SSND`.

This RFC is independent of the RPC, PQ-queue, and address-DR RFCs and can be implemented on its own.

[1]: https://tools.ietf.org/html/rfc5234
[2]: https://tools.ietf.org/html/rfc7405
