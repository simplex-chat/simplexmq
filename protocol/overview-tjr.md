Revision 1, 2022-01-01

Evgeny Poberezkin

# SimpleX: messaging and application platform

## Table of contents

- [Introduction](#introduction)
  - [What is SimpleX](#what-is-simplex)
  - [SimpleX objectives](#simplex-objectives)
  - [In Comparison](#in-comparison)
- [Technical Details](#technical-details)
  - [Trust in Servers](#trust-in-servers)
  - [Client -> Server Communication](#client---server-communication)
  - [SimpleX Messaging Protocol](#simplex-messaging-protocol)
  - [SimpleX Agents](#simplex-agents)
  - [Encryption Primitives Used](#encryption-primitives-used)
- [Threat model](#threat-model)
- [Acknowledgements](#acknowledgements)

## Introduction

#### What is SimpleX

SimpleX as a whole is a platform upon which applications can be built. [SimpleX Chat](https://github.com/simplex-chat/simplex-chat) is one such application that also serves as an example and reference application.

 - [SimpleX Messaging Protocol](https://github.com/simplex-chat/simplexmq/blob/master/protocol/simplex-messaging.md) (SMP) is a protocol to send messages in one direction to a recipient, relying on a server in-between. The messages are delivered via uni-directional queues created by recipients.

 - SMP runs over a transport protocol (shown below as TLS) that provides integrity, server authentication, confidentiality, and transport channel binding.

 - A SimpleX Server is one of those servers.

 - The SimpleX Network is the term used for the collective of SimpleX Servers that facilitate SMP.

 - SimpleX Client libraries speak SMP to SimpleX Servers and provide a low-level API not generally intended to be used by applications.

 - SimpleX Agents interface with SimpleX Clients to provide a more high-level API intended to be used by applications. Typically they are embedded as libraries, but are designed so they can also be abstracted into local services.


*Diagram showing the SimpleX Chat app, with logical layers of the chat application interfacing with a SimpleX Agent library, which in turn interfaces with a SimpleX Client library. The Client library in turn speaks the Messaging Protocol to a SimpleX Server.*

```
  User's Computer                 Internet                    Third-Party Server
------------------     |   ----------------------     |   -------------------------
                       |                              |
   SimpleX Chat        |                              |
                       |                              |
+----------------+     |                              |
|    Chat App    |     |                              |
+----------------+     |                              |
|  SimpleX Agent |     |                              |
+----------------+    -------------- TLS ----------------    +----------------+
| SimpleX Client | ------ SimpleX Messaging Protocol ------> | SimpleX Server |
+----------------+    -----------------------------------    +----------------+
                       |                              |
```

#### SimpleX objectives

1. Provide messaging infrastructure for distributed applications. This infrastructure needs to have the following qualities:

   - Security against passive and active (man-in-the-middle) attacks: the parties should have reliable end-to-end encryption and be able to detect the presence of an active attacker who modified, deleted or added messages.

   - Privacy: protect against traffic correlation attacks to determine the contacts that the users communicate with.

   - Reliability: the messages should be delivered even if some participating network servers or receiving clients fail, with “at least once” delivery guarantee.

   - Integrity: the messages sent in one direction are ordered in a way that sender and recipient agree on; the recipient can detect when a message was removed or changed.

   - Asynchronous delivery: it should not be required that both communicating parties (client devices, services or applications) are online for reliable message delivery.

   - Low latency: the delay introduced by the network should not be higher than 100ms-1s in addition to the underlying TCP network latency.

2. Provide better communication security and privacy than the alternative instant messaging solutions.  In particular SimpleX provides better privacy of metadata (who talks to whom and when) and better security against active network attackers and malicious servers.

3. Balance user experience with privacy requirements, prioritizing experience of mobile device users.

#### In Comparison

SimpleX network has a design similar to P2P networks, but unlike most P2P networks it consists of clients and servers without depending on any centralized component.
In comparison to more traditional messaging applications (e.g. WhatsApp, Signal, Telegram) the key differences of SimpleX network are:

- participants do not need to have globally unique addresses to communicate, instead they use redundant unidirectional (simplex) messaging queues, with a separate set of queues for each contact.

- connection requests are passed out-of-band, non-optionally protecting key exchange against man-in-the-middle attack.

- simple message queues provided by network servers are used by the clients to create more complex communication scenarios, such as duplex one-to-one communication, transmitting files, group communication without central servers, and content/communication channels.

- servers do not store any user information (no user profiles or contacts, or messages once they are delivered), and primarily use in-memory persistence.

- users can change servers with minimal disruption - even after an in-use server disappears, simply by changing the configuration on which servers the new queues are created.

## Technical Details

#### Trust in Servers

Clients communicate directly with servers (but not with other clients) using SimpleX Messaging Protocol (SMP) running over some transport protocol that provides integrity, server authentication, confidentiality, and transport channel binding. By default, we assume this transport protocol is TLS.

Users use multiple servers, and choose where to receive their messages. Accordingly, they send messages to their communication partners' chosen servers.

Although end-to-end encryption is always present, users place a degree of trust in servers. This trust decision is very similar to a user's choice of email provider; however the trust placed in a SimpleX server is significantly less. Notably, there is no re-used identifier or credential between queues on the same (or different) servers. While a user *may* re-use a connection to fetch from multiple queues, or connect to a server from the same IP address, both are choices a user may opt into to break the promise of un-correlatable queues.

Users may trust a server because:

- They deploy and control the servers themselves from the available open-source code. This has the trade-offs of strong trust in the server but limited metadata obfuscation to a passive network observer. Techniques such as noise traffic, traffic mixing (incurring latency), and using an onion routing transport protocol can mitigate that latter.

- They use servers from a trusted commercial provider. The more clients the provider has, the less metadata about the communication times is leaked to the network observers.

- Users trust their contacts and the servers they chose.

By default, servers do not retain access logs, and permanently delete messages and queues when requested.  Messages persist only in memory until they cross a threshold of time, typically on the order of days.[0] There is still a risk that a server maliciously records all queues and messages (even though encrypted) sent via the same transport connection to gain a partial knowledge of the user’s communications graph and other meta-data.

SimpleX supports measures (managed transparently to the user at the agent level) to mitigate the trust placed in servers.  These include rotating the queues in use between users, noise traffic, and supporting overlay networks such as Tor.

[0] While configurable by servers, a minimum value is enforced by the default software. SimpleX Agents provide redundant routing over queues to mitigate against message loss.


#### Client -> Server Communication

Utilizing TLS grants the SimpleX Messaging Protocol (SMP) server authentication and metadata protection to a passive network observer. But SMP does not rely on the transport protocol for message confidentiality or client authentication. The SMP protocol itself provides end-to-end confidentiality, authentication, and integrity of messages between communicating parties.

Servers have long-lived, self-signed, offline certificates whose hash is pre-shared with clients over secure channels - either provided with the client library or provided in the secure introduction between clients.  The offline certificate signs an online certificate used in the transport protocol handshake. [0]

If the transport protocol's confidentiality is broken, incoming and outgoing messages to the server cannot be correlated by message contents. Additionally, because of encryption at the SMP layer, impersonating the server is not sufficient to pass (and therefore correlate) a message from a sender to recipient - the only attack possible is to drop the messages. Only by additionally *compromising* the server can one pass and correlate messages.

It's important to note that the SMP protocol does not do server authentication. Instead we rely upon the fact that an attacker who tricks the transport protocol into authenticating the server incorrectly cannot do anything with the SMP messages except drop them.

After the connection is established, the client sends blocks of a fixed size 16Kb, and the server replies with the blocks of the same size to reduce metadata observable to a network adversary. The protocol has been designed to make traffic correlation attacks difficult, adapting ideas from Tor, remailers, and more general onion and mix networks. It does not try to replace Tor though - SimpleX servers can be deployed as onion services and SimpleX clients can communicate with servers over Tor to further improve participants privacy.

By using fixed-size blocks, oversized for the expected content, the vast majority of traffic is uniform in nature. When enough traffic is transiting a server simultaneously, the server acts as a (very) low-latency mix node.  We can't rely on this behavior to make a security claim, but we have engineered to take advantage of it when we can. As mentioned, this holds true even if the transport connection is compromised.

The protocol does not protect against attacks targeted at particular users with known identities - e.g., if the attacker wants to prove that two known users are communicating, they can achieve it. At the same time, it substantially complicates large-scale traffic correlation, making determining the real user identities much less effective.

[0] Future versions of SMP may add support for revocation lists of certificates, presently this risk is mitigated by the SMP protocol itself.


#### SimpleX Messaging Protocol

SMP is initialized with an in-person or out-of-band introduction message, where Alice provides Bob with details of a server (including IP, port, and hash of the long-lived offline certificate), a queue ID, and Alice's public key for her receiving queue. These introductions are similar to the PANDA key-exchange, in that if observed, the adversary can race to establish the communication channel instead of the intended participant. [0]

Because queues are uni-directional, Bob provides an identically-formatted introduction message to Alice over Alice's now-established receiving queue.

When setting up a queue, the server will create separate sender and recipient queue IDs (provided to Alice during set-up and Bob during initial connection). Additionally, during set-up Alice will perform a DH exchange with the server to agree upon a shared secret. This secret will be used to re-encrypt Bob's incoming message before Alice receives it, creating the anti-correlation property earlier-described should the transport encryption be compromised.

[0] Users can additionally create public 'contact queues' that are only used to receive connection requests.  

#### SimpleX Agents

SimpleX agents provide higher-level operations compared to SimpleX Clients, who are primarily concerned with creating queues and communicating with servers using SMP.  Agent operations include:

- Managing sets of bi-directional, redundant queues for communication partners

- Providing end-to-end encryption of messages

- Rotating queues periodically with communication partners

- Noise traffic

#### Encryption Primitives Used

- Ed448 to sign/verify commands to SMP servers (Ed25519 is also supported via client/server configuration).
- Curve25519 for DH exchange to agree:
  - the shared secret between server and recipient (to encrypt message bodies - it avoids shared cipher-text in sender and recipient traffic)
  - the shared secret between sender and recipient (to encrypt messages end-to-end in each queue - it avoids shared cipher-text in redundant queues).
- [NaCl crypto_box](https://nacl.cr.yp.to/box.html) encryption scheme (curve25519xsalsa20poly1305) for message body encryption between server and recipient and for E2E per-queue encryption.
- SHA256 to validate server offline certificates.
- [double ratchet](https://signal.org/docs/specifications/doubleratchet/) protocol for end-to-end message encryption between the agents:
  - Curve448 keys to agree shared secrets required for double ratchet initialization (using [X3DH](https://signal.org/docs/specifications/x3dh/) key agreement with 2 ephemeral keys for each side),
  - AES-GCM AEAD cipher,
  - SHA512-based HKDF for key derivation.

## Threat Model

#### Global Assumptions

 - A user protects their local database and key material
 - The user's application is authentic, and no local malware is running
 - The cryptographic primitives in use are not broken
 - A user's choice of servers is not directly tied to their identity or otherwise represents distinguishing information about the user.

#### A passive adversary able to monitor the traffic of one user

*can:*

 - identify that and when a user is using SimpleX

 - block SimpleX traffic

 - determine which servers the user communicates with

 - observe how much traffic is being sent, and make guesses as to its purpose.

*cannot:*

 - see who sends messages to the user and who the user sends the messages to

#### A passive adversary able to monitor a set of senders and recipients

 *can:*

 - identify who and when is using SimpleX

 - learn which SimpleX Messaging Protocol servers are used as receive queues for which users

 - learn when messages are sent and received

 - perform traffic correlation attacks against senders and recipients and correlate senders and recipients within the monitored set, frustrated by the number of users on the servers

 - observe how much traffic is being sent, and make guesses as to its purpose

*cannot, even in case of a compromised transport protocol:*

 - perform traffic correlation attacks with any increase in efficiency over a non-compromised transport protocol

#### SimpleX Messaging Protocol server

*can:*

- learn when a queue recipient or sender is online

- know how many messages are sent via the queue (although some may be noise)

- perform queue correlation (matching multiple queues to a single user) via either a re-used transport connection, user's IP Address, or connection timing regularities

- learn a user's IP address, track them through other IP addresses they use to access the same queue, and infer information (e.g. employer) based on the IP addresses, as long as Tor is not used.

- drop all future messages inserted into a queue, detectable only over other, redundant queues

- lie about the state of a queue to the recipient and/or to the sender  (e.g. suspended or deleted when it is not).

- spam a user with invalid messages

*cannot:*

- undetectably add, duplicate, or corrupt individual messages

- undetectably drop individual messages, so long as a subsequent message is delivered

- learn the contents of messages

- distinguish noise messages from regular messages except via timing regularities

- compromise the user's end-to-end encryption with an active attack

#### An attacker who obtained Alice's (decrypted) chat database

*can:*

- see the history of all messages exchanged by Alice with her communication partners

- see shared profiles of contacts and groups

- surreptitiously receive new messages sent to Alice via existing queues; until communication queues are rotated or the Double-Ratchet advances forward

- prevent Alice from receiving all new messages sent to her - either surreptitiously by emptying the queues regularly or overtly by deleting them

- send messages from the user to their contacts; recipients will detect it as soon as the user sends the next message, because the previous message hash won’t match (and potentially won’t be able to decrypt them in case they don’t keep the previous ratchet keys).

*cannot:*

- impersonate a sender and send messages to the user whose database was stolen. Doing so requires also compromising the server (to place the message in the queue, that is possible until the Double-Ratchet advances forward) or the user's device at a subsequent time (to place the message in the database).

- undetectably communicate at the same time as Alice with her contacts. Doing so would result in the contact getting different messages with repeated IDs.

- undetectably monitor message queues in realtime without alerting the user they are doing so, as a second subscription request unsubscribes the first and notifies the second.

#### A user’s contact

*can:*

- spam the user with messages

- forever retain messages from the user

*cannot:*

- cryptographically prove to a third-party that a message came from a user (assuming the user’s device is not seized)

- prove that two contacts they have is the same user

- cannot collaborate with another of the user's contacts to confirm they are communicating with the same user

#### An attacker who observes Alice showing an introduction message to Bob

*can:*

 - Impersonate Bob to Alice

*cannot:*

 - Impersonate Alice to Bob

#### An attacker with Internet access

*can:*

- Denial of Service SimpleX messaging servers

- spam a user's public “contact queue” with connection requests

*cannot:*

- send messages to a user who they are not connected with

- enumerate queues on a SimpleX server


## Acknowledgements

Efim Poberezkin contributed to the design and implementation of [SimpleX Messaging Protocol](https://github.com/simplex-chat/simplexmq/blob/master/protocol/simplex-messaging.md) and [SimpleX Agent Protocol](https://github.com/simplex-chat/simplexmq/blob/master/protocol/agent-protocol.md) since 2019.

Adam Langley's [Pond](https://github.com/agl/pond) inspired some of the recent improvements and the structure of this document.
