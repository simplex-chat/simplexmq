# SimpleX Network

[![GitHub build](https://github.com/simplex-chat/simplexmq/actions/workflows/build.yml/badge.svg)](https://github.com/simplex-chat/simplexmq/actions/workflows/build.yml)
[![GitHub release](https://img.shields.io/github/v/release/simplex-chat/simplexmq)](https://github.com/simplex-chat/simplexmq/releases)

The simplexmq package provides the software for [SimpleX Network](./protocol/overview-tjr.md) — a general-purpose packet routing network where endpoints exchange data through independently operated routers using resource-based addressing. Unlike IP networks, SimpleX addresses identify resources on routers (queues, data packets), not endpoint devices. Participants do not need globally unique identifiers to communicate.

The software is organized in three layers:

```
  Application (e.g. SimpleX Chat)
+----------------------------------+
|         SimpleX Agent            |  Layer 3 — duplex connections, e2e encryption
+----------------------------------+
|      SimpleX Client Libraries    |  Layer 2 — protocol clients for SMP, XFTP
+----------------------------------+
|        SimpleX Routers           |  Layer 1 — network infrastructure (SMP, XFTP, NTF)
+----------------------------------+
```

[SimpleX Chat](https://github.com/simplex-chat/simplex-chat) is one application built on Layer 3. IoT devices, AI services, monitoring systems, and automated services are other applications that can use Layers 2 or 3 directly.

The simplexmq package is implemented in Haskell, benefiting from robust software transactional memory (STM) and concurrency primitives.

See the [SimpleX Network overview](./protocol/overview-tjr.md) for the full protocol architecture, trust model, and [security analysis](./protocol/security.md).

## Architecture

### SimpleX Routers

Routers are the network infrastructure — they accept, buffer, and deliver packets. Three router types serve different purposes:

- **SMP routers** provide messaging queues — unidirectional, ordered sequences of fixed-size packets (16,384 bytes). Protocol: [SMP](./protocol/simplex-messaging.md). Module spec: [`Simplex.Messaging.Server`](./spec/modules/Simplex/Messaging/Server.md).
- **XFTP routers** accept and deliver data packets — individually addressed blocks in fixed sizes (64KB–4MB) for larger payloads. Protocol: [XFTP](./protocol/xftp.md). Module spec: [`Simplex.FileTransfer.Server`](./spec/modules/Simplex/FileTransfer/Server.md).
- **NTF routers** bridge to platform push services (APNS) for mobile notification delivery. Protocol: [Push Notifications](./protocol/push-notifications.md). Module spec: [`Simplex.Messaging.Notifications.Server`](./spec/modules/Simplex/Messaging/Notifications/Server.md).

#### Running an SMP router

[SMP server](./apps/smp-server/Main.hs) runs on any Linux distribution. OpenSSL is required for initialization.

Initialize: `smp-server init -n <fqdn>` (or `--ip <ip>`). This generates TLS certificates. The CA certificate fingerprint becomes part of the server address: `smp://<fingerprint>@<hostname>[:5223]`.

The server uses in-memory persistence with an optional append-only store log for queue persistence across restarts. Enable with `smp-server init -l` or in `smp-server.ini`. The log is compacted on every restart.

When store log is enabled, undelivered messages are saved on exit (SIGINT only, not SIGTERM) and restored on start. Control this independently with the `restore_messages` setting.

> **Please note:** On initialization, SMP server creates a certificate chain: a self-signed CA certificate ("offline") and a server certificate for TLS ("online"). **Store the CA private key securely and delete it from the server.** If the server TLS credential is compromised, this key can sign a new one while keeping the same server identity. Default location: `/etc/opt/simplex/ca.key`.

See [docs/ROUTERS.md](./docs/ROUTERS.md) for XFTP/NTF router setup, advanced configuration, MacOS notes, and all deployment options (Docker, installation script, building from source, Linode, DigitalOcean).

### SimpleX Client Libraries

[Client libraries](./docs/CLIENT.md) provide low-level protocol access to SimpleX routers. They implement the wire protocols (SMP, XFTP) and handle connection lifecycle, command authentication, and keep-alive.

The [SMP client](./src/Simplex/Messaging/Client.hs) ([module spec](./spec/modules/Simplex/Messaging/Client.md)) offers a functional Haskell API with STM queues for asynchronous event delivery. The [XFTP client](./src/Simplex/FileTransfer/Client.hs) ([module spec](./spec/modules/Simplex/FileTransfer/Client.md)) sends and receives data packets with per-request forward secrecy.

Applications that manage their own encryption and connection logic — IoT devices, sensors, simple data pipelines — can use this layer directly. See [docs/CLIENT.md](./docs/CLIENT.md).

### SimpleX Agent

The [Agent](./docs/AGENT.md) builds duplex encrypted connections on top of the client libraries. It manages:

- Duplex connections from simplex queue pairs
- End-to-end encryption with double ratchet and post-quantum extensions
- File transfer with chunking, encryption, and multi-router distribution
- Queue rotation for metadata privacy
- Push notification subscriptions

The [Agent library](./src/Simplex/Messaging/Agent.hs) ([module spec](./spec/modules/Simplex/Messaging/Agent.md)) communicates via STM queues using the [ACommand](./src/Simplex/Messaging/Agent/Protocol.hs) type — no serialization needed. The Agent implements the [Agent protocol](./protocol/agent-protocol.md) for duplex connections and uses the [PQDR protocol](./protocol/pqdr.md) for end-to-end encryption. Cross-device remote control uses the [XRCP protocol](./protocol/xrcp.md).

See [docs/AGENT.md](./docs/AGENT.md).

## Quick start

Public SMP routers for testing:

`smp://u2dS9sG8nMNURyZwqASV4yROM28Er0luVTx5X1CsMrU=@smp4.simplex.im`

`smp://hpq7_4gGJiilmz5Rf-CswuU5kZGkm_zOIooSw6yALRg=@smp5.simplex.im`

`smp://PQUV2eL0t7OStZOoAsPEV2QYWt4-xilbakvGUGOItUo=@smp6.simplex.im`

## Deploy routers

You can run SMP/XFTP routers on any Linux distribution. OpenSSL is required:

```sh
# Ubuntu
apt update && apt install openssl
```

See [docs/ROUTERS.md](./docs/ROUTERS.md) for Docker, binary installation, building from source, and cloud deployment (Linode, DigitalOcean).

## License

[AGPL v3](./LICENSE)
