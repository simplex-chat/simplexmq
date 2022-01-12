# SimpleXMQ

[![GitHub build](https://github.com/simplex-chat/simplexmq/workflows/build/badge.svg)](https://github.com/simplex-chat/simplexmq/actions?query=workflow%3Abuild)
[![GitHub release](https://img.shields.io/github/v/release/simplex-chat/simplexmq)](https://github.com/simplex-chat/simplexmq/releases)

📢 SimpleXMQ v1 is released - with many security, privacy and efficiency improvements, new functionality - see [release notes](https://github.com/simplex-chat/simplexmq/releases/tag/v1.0.0).

**Please note**: v1 is not backwards compatible, but it has the version negotiation built into all protocol layers for forwards compatibility of this version and backwards compatibility of the future versions, that will be backwards compatible for at least two versions back.

If you have a server deployed please deploy a new server to a new host and retire the previous version once it is no longer used.

## Message broker for unidirectional (simplex) queues

SimpleXMQ is a message broker for managing message queues and sending messages over public network. It consists of SMP server, SMP client library and SMP agent that implement [SMP protocol](https://github.com/simplex-chat/simplexmq/blob/master/protocol/simplex-messaging.md) for client-server communication and [SMP agent protocol](https://github.com/simplex-chat/simplexmq/blob/master/protocol/agent-protocol.md) to manage duplex connections via simplex queues on multiple SMP servers.

SMP protocol is inspired by [Redis serialization protocol](https://redis.io/topics/protocol), but it is much simpler - it currently has only 10 client commands and 8 server responses.

SimpleXMQ is implemented in Haskell - it benefits from robust software transactional memory (STM) and concurrency primitives that Haskell provides.

## SimpleXMQ roadmap

- SimpleX service protocol and application template - to enable users building services and chat bots that work over SimpleX protocol stack. The first such service will be a notification service for a mobile app.
- SMP queue redundancy and rotation in SMP agent connections.
- SMP agents synchronization to share connections and messages between multiple agents (it would allow using multiple devices for [simplex-chat](https://github.com/simplex-chat/simplex-chat)).

## Components

### SMP server

[SMP server](https://github.com/simplex-chat/simplexmq/blob/master/apps/smp-server/Main.hs) can be run on any Linux distribution without any dependencies, including low power/low memory devices. It uses in-memory persistence with an optional append-only log of created queues that allows to re-start the server without losing the connections. This log is compacted on every server restart, permanently removing suspended and removed queues.

To enable the queue logging, uncomment `enable: on` option in `smp-server.ini` configuration file that is created the first time the server is started.

To initialize the server use `smp-server init` command - it will generate keys and certificates for TLS transport. The fingerprint of offline certificate is used as part of the server address to protect client/server connection against man-in-the-middle attacks: `smp://<fingerprint>@<hostname>:5223`.

SMP server implements [SMP protocol](https://github.com/simplex-chat/simplexmq/blob/master/protocol/simplex-messaging.md).

#### Running SMP server on MacOS

SMP server requires OpenSSL library for initialization. On MacOS OpenSSL library may be replaced with LibreSSL, which doesn't support required algorithms. Before initializing SMP server verify you have OpenSSL installed:

```sh
openssl version
```

If it says "LibreSSL", please install original OpenSSL:

```sh
brew update
brew install openssl
echo 'PATH="/opt/homebrew/opt/openssl@3/bin:$PATH"' >> ~/.zprofile # or follow whatever instructions brew suggests
. ~/.zprofile # or restart your terminal to start a new session
```

Now `openssl version` should be saying "OpenSSL". You can now run `smp-server init` to initialize your SMP server.

### SMP client library

[SMP client](https://github.com/simplex-chat/simplexmq/blob/master/src/Simplex/Messaging/Client.hs) is a Haskell library to connect to SMP servers that allows to:
- execute commands with a functional API.
- receive messages and other notifications via STM queue.
- automatically send keep-alive commands.

### SMP agent

[SMP agent library](https://github.com/simplex-chat/simplexmq/blob/master/src/Simplex/Messaging/Agent.hs) can be used to run SMP agent as part of another application and to communicate with the agent via STM queues, without serializing and parsing commands and responses.

Haskell type [ACommand](https://github.com/simplex-chat/simplexmq/blob/master/src/Simplex/Messaging/Agent/Protocol.hs) represents SMP agent protocol to communicate via STM queues.

See [simplex-chat](https://github.com/simplex-chat/simplex-chat) terminal UI for the example of integrating SMP agent into another application.

[SMP agent executable](https://github.com/simplex-chat/simplexmq/blob/master/apps/smp-agent/Main.hs) can be used to run a standalone SMP agent process that implements plaintext [SMP agent protocol](https://github.com/simplex-chat/simplexmq/blob/master/protocol/agent-protocol.md) via TCP port 5224, so it can be used via telnet. It can be deployed in private networks to share access to the connections between multiple applications and services.

## Using SMP server and SMP agent

You can either run your own SMP server locally or deploy using [Linode StackScript](https://cloud.linode.com/stackscripts/748014), or try local SMP agent with the deployed servers:

<!-- TODO update -->

`smp://u2dS9sG8nMNURyZwqASV4yROM28Er0luVTx5X1CsMrU=@smp4.simplex.im`
`smp://hpq7_4gGJiilmz5Rf-CswuU5kZGkm_zOIooSw6yALRg=@smp5.simplex.im`
`smp://PQUV2eL0t7OStZOoAsPEV2QYWt4-xilbakvGUGOItUo=@smp6.simplex.im`

It's the easiest to try SMP agent via a prototype [simplex-chat](https://github.com/simplex-chat/simplex-chat) terminal UI.

[<img alt="Linode" src="https://raw.githubusercontent.com/simplex-chat/simplexmq/master/img/linode.svg" align="right" width="200">](https://cloud.linode.com/stackscripts/748014)

## Deploy SMP server on Linode

\* You can use free credit Linode offers when [creating a new account](https://www.linode.com/) to deploy an SMP server.

Deployment on Linode is performed via StackScripts, which serve as recipes for Linode instances, also called Linodes. To deploy SMP server on Linode:

- Create a Linode account or login with an already existing one.
- Open [SMP server StackScript](https://cloud.linode.com/stackscripts/748014) and click "Deploy New Linode".
- You can optionally configure the following parameters:
    - [SMP Server store log](#SMP-server) flag for queue persistence on server restart (recommended).
    - [Linode API token](https://www.linode.com/docs/guides/getting-started-with-the-linode-api#get-an-access-token) for attaching server info as tags to Linode (server address, fingerprint, version) and adding A record to your 2nd level domain (Note: 2nd level e.g. `example.com` domain should be [created](https://cloud.linode.com/domains/create) in your account prior to deployment). The API token access scope should be read/write access to "linodes" (to create tags), and "domains" (to add A record for the 3rd level domain, e.g. `smp`).
    - Domain name to use instead of Linode ip address, e.g. `smp.example.com`.
- Choose the region and plan according to your requirements (for regular use Shared CPU Nanode should be sufficient).
- Provide ssh key to be able to connect to your Linode via ssh. If you haven't provided a Linode API token this step is required to login to your Linode and get the server's fingerprint either from the welcome message or from the file `/etc/opt/simplex/fingerprint` after server starts. See [Linode's guide on ssh](https://www.linode.com/docs/guides/use-public-key-authentication-with-ssh/) .
- Deploy your Linode. After it starts wait for SMP server to start and for tags to appear (if a Linode API token was provided). It may take up to 5 minutes depending on the connection speed on the Linode. Connecting Linode IP address to provided domain name may take some additional time.
- Get `address` and `fingerprint` either from Linode tags (click on a tag and copy it's value from the browser search panel) or via ssh.
- Great, your own SMP server is ready! If you provided FQDN use `smp://<fingerprint>@<fqdn>` as SMP server address in the client, otherwise use `smp://<fingerprint>@<ip_address>`.

Please submit an [issue](https://github.com/simplex-chat/simplexmq/issues) if any problems occur.

[<img alt="DigitalOcean" src="https://raw.githubusercontent.com/simplex-chat/simplexmq/master/img/digitalocean.png" align="right" width="300">](https://marketplace.digitalocean.com/apps/simplex-server)

## Deploy SMP server on DigitalOcean

\* When creating a DigitalOcean account you can use [this link](https://try.digitalocean.com/freetrialoffer/) to get free credit. (You would still be required either to provide your credit card details or make a confirmation pre-payment with PayPal)

To deploy SMP server use [SimpleX Server 1-click app](https://marketplace.digitalocean.com/apps/simplex-server) from DigitalOcean marketplace:

- Create a DigitalOcean account or login with an already existing one.
- Click 'Create SimpleX server Droplet' button.
- Choose the region and plan according to your requirements (Basic plan should be sufficient).
- Finalize Droplet creation.
- Open "Console" on your Droplet management page to get SMP server fingerprint - either from the welcome message or from `/etc/opt/simplex/fingerprint`. Alternatively you can manually SSH to created Droplet, see [instruction](https://docs.digitalocean.com/products/droplets/how-to/connect-with-ssh/).
- Great, your own SMP server is ready! Use `smp://<fingerprint>@<ip_address>` as SMP server address in the client.

Please submit an [issue](https://github.com/simplex-chat/simplexmq/issues) if any problems occur.

## SMP server design

![SMP server design](https://raw.githubusercontent.com/simplex-chat/simplexmq/master/design/server.svg)

## SMP agent design

![SMP agent design](https://raw.githubusercontent.com/simplex-chat/simplexmq/master/design/agent2.svg)

## License

[AGPL v3](https://github.com/simplex-chat/simplexmq/blob/master/LICENSE)
