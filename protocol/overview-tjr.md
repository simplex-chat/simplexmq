Revision 4, 2026-03-09

Evgeny Poberezkin

# SimpleX: messaging and application platform

## Table of contents

- [Introduction](#introduction)
  - [What is SimpleX](#what-is-simplex)
  - [Network model](#network-model)
  - [Applications](#applications)
  - [SimpleX objectives](#simplex-objectives)
  - [In Comparison](#in-comparison)
- [Technical Details](#technical-details)
  - [Trust in Routers](#trust-in-routers)
  - [Client -> Router Communication](#client---router-communication)
  - [2-hop Onion Message Routing](#2-hop-onion-message-routing)
  - [SimpleX Messaging Protocol](#simplex-messaging-protocol)
  - [SimpleX Agents](#simplex-agents)
- [Security](#security)
- [Acknowledgements](#acknowledgements)


## Introduction

#### What is SimpleX

SimpleX as a whole is a platform upon which applications can be built. [SimpleX Chat](https://github.com/simplex-chat/simplex-chat) is one such application that also serves as an example and reference application.

 - [SimpleX Messaging Protocol](./simplex-messaging.md) (SMP) is a protocol to send messages in one direction to a recipient, relying on a router in-between. The messages are delivered via uni-directional queues created by recipients.

 - SMP protocol allows to send message via a SMP router playing proxy role using 2-hop onion routing (referred to as "private routing" in messaging clients) to protect transport information of the sender (IP address and session) from the router chosen (and possibly controlled) by the recipient.

 - SMP runs over a transport protocol (shown below as TLS) that provides integrity, server authentication, confidentiality, and transport channel binding.

 - A SimpleX router is one of those routers.

 - The SimpleX Network is the term used for the collective of SimpleX routers that facilitate SMP.

 - SimpleX Client libraries speak SMP to SimpleX routers and provide a low-level API not generally intended to be used by applications.

 - SimpleX Agents interface with SimpleX Clients to provide a more high-level API intended to be used by applications. Typically they are embedded as libraries, but can also be abstracted into local services.

 - SimpleX Agents communicate with other agents inside e2e encrypted envelopes provided by SMP protocol - the syntax and semantics of the messages exchanged by the agent are defined by [SMP agent protocol](./agent-protocol.md)


*Diagram showing the SimpleX Chat app, with logical layers of the chat application interfacing with a SimpleX Agent library, which in turn interfaces with a SimpleX Client library. The Client library in turn speaks the Messaging Protocol to a SimpleX router.*

```
  User's Computer                 Internet                    Third-Party Router
------------------     |   ----------------------     |   -------------------------
                       |                              |
   SimpleX Chat        |                              |
                       |                              |
+----------------+     |                              |
|    Chat App    |     |                              |
+----------------+     |                              |
|  SimpleX Agent |     |                              |
+----------------+    -------------- TLS ----------------    +----------------+
| SimpleX Client | ------ SimpleX Messaging Protocol ------> | SimpleX router |
+----------------+    -----------------------------------    +----------------+
                       |                              |
```

#### Network model

SimpleX is a general-purpose packet routing network built on top of the Internet. Network endpoints — end-user devices, automated services, AI-enabled applications, IoT devices — exchange data packets through SimpleX network nodes (SMP routers), which accept, buffer, and deliver packets. Each router operates independently and can be operated by any party on standard computing hardware.

SimpleX routers use resource-based addressing: each address identifies a resource on a router, similar to how the World Wide Web addresses resources via URLs. Internet routers, by comparison, use endpoint-based addressing, where IP addresses identify destination devices. Because of this design, SimpleX network participants do not need globally unique addresses to communicate.

SimpleX network has two resource-based addressing schemes:

- *Messaging queues* ([SMP](./simplex-messaging.md)). A queue is a unidirectional, ordered sequence of fixed-size data packets (16,384 bytes each). Each queue has a resource address on a specific router, gated by cryptographic credentials that separately authorize sending and receiving.

- *Data packets* ([XFTP](./xftp.md)). A data packet is an individually addressed block in one of the standard sizes. Each packet has a unique resource address on a specific router, gated by cryptographic credentials. Data packet addressing is more efficient for delivery of larger payloads than queues.

Packet delivery follows a two-router path. The sending endpoint submits a packet to a first router, which forwards it to a second router, where the receiving endpoint retrieves it. The sending endpoint's IP address is known only to the first router; the receiving endpoint's IP address is known only to the second router. See [2-hop Onion Message Routing](#2-hop-onion-message-routing) for details.

Routers buffer packets between submission and retrieval — from seconds to days, enabling asynchronous delivery when endpoints are online at different times. Packets are removed after delivery or after a configured expiration period.


#### Applications

Applications currently using SimpleX network:

- **SimpleX Chat** — a peer-to-peer messenger using SimpleX network as a transport layer, in the same way that communication applications use WebRTC, Tor, i2p, or Nym. All communication logic — contacts, conversations, groups, message formats, end-to-end encryption — runs on endpoint devices.

- **IoT devices** — using the SimpleX queue protocol directly for sensor data collection and device control.

- **AI-based services** — automated services built on the SimpleX Chat application core.

- **Secure monitoring and control systems** — applications for equipment monitoring and control, including robotics, using the network for command delivery and telemetry collection.

[SimpleGo](https://simplego.dev), developed by an independent organization, is a microcontroller-based device running a SimpleX Chat-compatible messenger directly on a microcontroller without a general-purpose operating system. Running over 20 days on a single battery charge, it demonstrates the energy efficiency of resource-based addressing: the device receives packets without continuous polling. A microcontroller-based router implementation that functions simultaneously as a WiFi router is also in development.


#### SimpleX objectives

1. Provide messaging infrastructure for distributed applications. This infrastructure needs to have the following qualities:

   - Security against passive and active (man-in-the-middle) attacks: the parties should have reliable end-to-end encryption and be able to detect the presence of an active attacker who modified, deleted or added messages.

   - Privacy: protect against traffic correlation attacks to determine the contacts that the users communicate with.

   - Reliability: the messages should be delivered even if some participating network routers or receiving clients fail, with "at least once" delivery guarantee.

   - Integrity: the messages sent in one direction are ordered in a way that sender and recipient agree on; the recipient can detect when a message was removed or changed.

   - Asynchronous delivery: it should not be required that both communicating parties (client devices, services or applications) are online for reliable message delivery.

   - Low latency: the delay introduced by the network should not be higher than 100ms-1s in addition to the underlying TCP network latency.

2. Provide better communication security and privacy than the alternative instant messaging solutions. In particular SimpleX provides better privacy of metadata (who talks to whom and when) and better security against active network attackers and malicious routers.

3. Balance user experience with privacy requirements, prioritizing experience of mobile device users.


#### In Comparison

SimpleX network has a design similar to P2P networks, but unlike most P2P networks it consists of clients and routers without depending on any centralized component.
In comparison to more traditional messaging applications (e.g. WhatsApp, Signal, Telegram) the key differences of SimpleX network are:

- participants do not need to have globally unique addresses to communicate, instead they use redundant unidirectional (simplex) messaging queues, with a separate set of queues for each contact.

- connection requests are passed out-of-band, non-optionally protecting key exchange against man-in-the-middle attack.

- simple message queues provided by network routers are used by the clients to create more complex communication scenarios, such as duplex one-to-one communication, transmitting files, group communication without central routers, and content/communication channels.

- routers do not store any user information (no user profiles or contacts, or messages once they are delivered), and primarily use in-memory persistence.

- users can change routers with minimal disruption - even after an in-use router disappears, simply by changing the configuration on which routers the new queues are created.


## Technical Details

#### Trust in Routers

Clients communicate directly with routers (but not with other clients) using SimpleX Messaging Protocol (SMP) running over some transport protocol that provides integrity, server authentication, confidentiality, and transport channel binding. By default, we assume this transport protocol is TLS.

Users use multiple routers, and choose where to receive their messages. Accordingly, they send messages to their communication partners' chosen routers either directly, if this is a known/trusted router, or via another SMP router providing proxy functionality to protect IP address and session of the sender.

Although end-to-end encryption is always present, users place a degree of trust in routers they connect to. This trust decision is very similar to a user's choice of email provider; however the trust placed in a SimpleX router is significantly less. Notably, there is no re-used identifier or credential between queues on the same (or different) routers. While a user *may* re-use a transport connection to fetch messages from multiple queues, or connect to a router from the same IP address, both are choices a user may opt into to break the promise of un-correlatable queues.

Users may trust a router because:

- They deploy and control the routers themselves from the available open-source code. This has the trade-offs of strong trust in the router but limited metadata obfuscation to a passive network observer. Techniques such as noise traffic, traffic mixing (incurring latency), and using an onion routing transport protocol can mitigate that.

- They use routers from a trusted commercial provider. The more clients the provider has, the less metadata about the communication times is leaked to the network observers.

By default, routers do not retain access logs, and permanently delete messages and queues when requested. Messages persist in memory or in a database until they cross a threshold of time, typically on the order of days.[0] There is still a risk that a router maliciously records all queues and messages (even though encrypted) sent via the same transport connection to gain a partial knowledge of the user's communications graph and other meta-data.

SimpleX supports measures (managed transparently to the user at the agent level) to mitigate the trust placed in routers.  These include rotating the queues in use between users, noise traffic, supporting overlay networks such as Tor, and isolating traffic to different queues to different transport connections (and Tor circuits, if Tor is used).

[0] While configurable by routers, a minimum value is enforced by the default software. SimpleX Agents can provide redundant routing over queues to mitigate against message loss.


#### Client -> Router Communication

Utilizing TLS grants the SimpleX Messaging Protocol (SMP) server authentication and metadata protection to a passive network observer. But SMP does not rely on the transport protocol for message confidentiality or client authentication. The SMP protocol itself provides end-to-end confidentiality, authentication, and integrity of messages between communicating parties.

Routers have long-lived, self-signed, offline certificates whose hash is pre-shared with clients over secure channels - either provided with the client library or provided in the secure introduction between clients, as part of the router address.  The offline certificate signs an online certificate used in the transport protocol handshake. [0]

If the transport protocol's confidentiality is broken, incoming and outgoing messages to the router cannot be correlated by message contents. Additionally, because of encryption at the SMP layer, impersonating the router is not sufficient to pass (and therefore correlate) a message from a sender to recipient - the only attack possible is to drop the messages. Only by additionally *compromising* the router can one pass and correlate messages.

It's important to note that the SMP protocol does not do server authentication. Instead we rely upon the fact that an attacker who tricks the transport protocol into authenticating the router incorrectly cannot do anything with the SMP messages except drop them.

After the connection is established, the client sends blocks of a fixed size 16KB, and the router replies with the blocks of the same size to reduce metadata observable to a network adversary. The protocol has been designed to make traffic correlation attacks difficult, adapting ideas from Tor, remailers, and more general onion and mix networks. It does not try to replace Tor though - SimpleX routers can be deployed as onion services and SimpleX clients can communicate with routers over Tor to further improve participants privacy.

By using fixed-size blocks, oversized for the expected content, the vast majority of traffic is uniform in nature. When enough traffic is transiting a router simultaneously, the router acts as a low-latency mix node. We can't rely on this behavior to make a security claim, but we have engineered to take advantage of it when we can. As mentioned, this holds true even if the transport connection is compromised.

The protocol does not protect against attacks targeted at particular users with known identities - e.g., if the attacker wants to prove that two known users are communicating, they can achieve it by observing their local traffic. At the same time, it substantially complicates large-scale traffic correlation, making determining the real user identities much less effective.

[0] Future versions of SMP may add support for revocation lists of certificates, presently this risk is mitigated by the SMP protocol itself.


#### 2-hop Onion Message Routing

As SimpleX Messaging Protocol routers providing messaging queues are chosen by the recipients, in case senders connect to these routers directly the router owners (who potentially can be the recipients themselves) can learn senders' IP addresses (if Tor is not used) and which other queues on the same router are accessed by the user in the same transport connection (even if Tor is used).

While the clients support isolating the messages sent to different queues into different transport connections (and Tor circuits), this is not practical, as it consumes additional traffic and system resources.

To mitigate this problem SimpleX Messaging Protocol routers support 2-hop onion message routing when the SMP router chosen by the sender forwards the messages to the routers chosen by the recipients, thus protecting both the senders IP addresses and sessions, even if connection isolation and Tor are not used.

The design of 2-hop onion message routing prevents these potential attacks:

- MITM by proxy (SMP router that forwards the messages).

- Identification by the proxy which and how many queues the sender sends messages to (as messages are additionally e2e encrypted between the sender and the destination SMP router).

- Correlation of messages sent to different queues via the same user session (as random correlation IDs and keys are used for each message).

See more details about 2-hop onion message routing design in [SimpleX Messaging Protocol](./simplex-messaging.md#proxying-sender-commands)

Also see [Security](./security.md)


#### SimpleX Messaging Protocol

SMP is initialized with an in-person or out-of-band introduction message, where Alice provides Bob with details of a router (including IP address or host name, port, and hash of the long-lived offline certificate), a queue ID, and Alice's public keys to agree e2e encryption. These introductions are similar to the PANDA key-exchange, in that if observed, the adversary can race to establish the communication channel instead of the intended participant. [0]

Because queues are uni-directional, Bob provides an identically-formatted introduction message to Alice over Alice's now-established receiving queue.

When setting up a queue, the router will create separate sender and recipient queue IDs (provided to Alice during set-up and Bob during initial connection). Additionally, during set-up Alice will perform a DH exchange with the router to agree upon a shared secret. This secret will be used to re-encrypt Bob's incoming message before Alice receives it, creating the anti-correlation property earlier-described should the transport encryption be compromised.

[0] Users can additionally create public 'contact queues' that are only used to receive connection requests.


#### SimpleX Agents

SimpleX agents provide higher-level operations compared to SimpleX Clients, who are primarily concerned with creating queues and communicating with routers using SMP.  Agent operations include:

- Managing sets of bi-directional, redundant queues for communication partners

- Providing end-to-end encryption of messages

- Rotating queues periodically with communication partners

- Noise traffic


## Security

For encryption primitives, threat model, and detailed security analysis, see [Security](./security.md).

SimpleX provides these security properties:

- **End-to-end encryption** with forward secrecy via double ratchet protocol, with optional post-quantum protection.

- **No shared identifiers** across connections — contacts cannot prove they communicate with the same user.

- **Sender deniability** — neither routers nor recipients can cryptographically prove message origin.

- **Transport metadata protection** — fixed-size blocks, 2-hop onion routing, and connection isolation frustrate traffic correlation.

- **Out-of-band key exchange** — connection requests passed outside the network protect against MITM attacks.


## Acknowledgements

Efim Poberezkin contributed to the design and implementation of [SimpleX Messaging Protocol](https://github.com/simplex-chat/simplexmq/blob/master/protocol/simplex-messaging.md) and [SimpleX Agent Protocol](https://github.com/simplex-chat/simplexmq/blob/master/protocol/agent-protocol.md) since 2019.

Adam Langley's [Pond](https://github.com/agl/pond) inspired some of the recent improvements and the structure of this document.
