# SimpleX: messaging and application network

## Table of contents

- [SimpleX objectives](#simplex-objectives)
- [SimpleX network](#simplex-network)
- [Threat model](#threat-model)

## SimpleX objectives

1. Provide *messaging infrastructure* (COMMENT the idea here is that servers on their own or agents+servers can be used for applications other than chat, but also that chat will be used to build the applications upon, e.g. with interactive chat widgets that can distribute some part of their state and respond to commands - something similar to what I did in the past for content publishing... In the context of this doc it's the former) for distributed applications. This infrastructure needs to have the following qualities:

   - Security against passive and active (man-in-the-middle) attacks: the parties should have reliable end-to-end encryption and be able to identify and to some extent compensate for the presence of the active attacker who may modify, delete or add messages.
  
   - Privacy: *network server operators should have no ability to read or modify messages without detection* (COMMENT redundant), and it should be impossible or hard to infer the contacts the users communicate with. Non-malicious network operators should retain no record of participants communications.
  
   - Reliability: the messages should be delivered even if some participating network servers or receiving clients fail, with “at least once” delivery guarantee.
  
   - Integrity: the messages sent in one direction are ordered in a way that sender and recipient agree on; the recipient can detect when a message was removed or changed.
  
   - Asynchronous delivery: it should not be required that both communicating parties (client devices, services or applications) are online for reliable message delivery.
  
   - Low latency: the delay introduced by the network should not be higher than 100ms-1s in addition to the underlying TCP network latency.
  
2. Provide better communication privacy, in particular meta-data privacy (who talks to whom and when), and security, in particular security against active attacks, than the alternative instant messaging solutions.

3. Balance user experience with privacy requirements, prioritizing experience of mobile device users.

## SimpleX network

### Overview

SimpleX network provides asynchronous messaging infrastructure that aims to deliver on the above objectives and to avoid the disadvantages of the alternative solutions.

The key differences of SimpleX network are:

- participants do not need to have globally unique addresses to communicate, instead they use redundant unidirectional (simplex) messaging queues, with a separate set of queues for each contact.

- connection requests are passed out-of-band, non-optionally protecting key exchange against man-in-the-middle attack.

- message queues provided by network servers are used by the clients to create more complex communication scenarios, such as duplex one-to-one communication, transmitting files, group communication without central servers and content/communication channels (requiring a separate type of server to host them, which is out of scope of this document).

- servers do not store any user information (no user profiles, contacts or messages, once they are delivered), and can use in-memory persistence only.

- users can change server provider(s) without losing their communication contacts, simply by changing the configuration on which servers the new queues are created.

SimpleX network has design similar to P2P networks, but unlike most P2P networks it consists of clients and servers, without dependency on any centralized component. Servers provide anonymous unidirectional message queues in order to:

- continuously accept messages for the recipients, even when they are offline.

- provide recipient anonymity, as the messaging queues do not identify the users, and different addresses of the same queue are used for senders and recipients to provide additional protection against server traffic correlation, in case transport connections are compromised.

Coincidentally, SimpleX network reminds [Pond messenger](https://github.com/agl/pond) design, the main differences are:

- Clients can receive messages via multiple servers (in Pond users use one home server and it serves as a user permanent address),

- Clients do not need to poll servers to receive messages, the messages from subscribed queues are delivered via an open transport connection as they are received by the servers, resulting in low latency of message delivery.

The protocol has been designed to make traffic correlation attacks difficult, adapting ideas from Tor, remailers, and more general onion and mix networks. It does not try to replace Tor though, and Tor can be used both as a transport layer by the clients, and the servers can deployed as Tor hidden services to further improve participants privacy.

By using fixed-size blocks, oversized for the expected content, the vast majority of traffic is uniform in nature. Traffic correlation is an attack that can be improved with machine learning models, trading false positives or false negatives. When enough traffic is transiting a server simultaneously, the server acts a (very) low-latency mix node.  We can't rely on this behavior to make a security claim, but we have engineered to take advantage of it when we can. This holds true even if the transport connection (TLS generally) is compromised as the incoming and outgoing traffic has no identifiers or cipher-text in common.

The protocol does not protect against attacks targeted at particular users with known identities - e.g., if the attacker wants to prove that two known users are communicating, they can achieve it. At the same time, it substantially complicates large-scale traffic correlation, making determining the real user identities much less effective than with any alternative solution known to us.

### SimpleX servers

Clients communicate with servers (but not with other clients) using SimpleX Messaging Protocol (SMP) running over some transport protocol that provides server authentication, confidentiality with forward secrecy, integrity and transport channel binding (to prevent SMP commands replay).

Users can use multiple servers. They choose the servers they use to receive the messages through, and they communicate with the servers chosen by the recipients to send messages.

It is assumed that users have some degree of trust to the servers, for one of the following reasons:

- They deploy and control the servers themselves from the available open-source code. The advantage of self-deployed servers is that users have full control of server information and activity, but the downside is that it is easier to correlate incoming and outgoing messages by observing server traffic, assuming small number of messages sent via user-hosted servers and irregular communication time. It can be mitigated by:

  - sending noise traffic.

  - future protocol versions can add configurable per queue message delivery delays (compromising on one of the design objectives of low latency).

  - using SMP servers via an onion routing or mix network.

- They use servers from the trusted commercial providers. The more clients the provider has, the more ineffective it becomes to use the meta-data about the communication times to correlate the sent and received traffic of the server. Even if transport confidentiality is compromised, there is no additional meta-data to correlate by, as the incoming and outgoing traffic is uniform in nature, having fixed size blocks and no identifiers or cipher-text in common.

- To some extent, users trust their contacts and the servers they chose that the users send messages to. The client applications could further improve user trust to the servers chosen by their contacts by supporting either the list of servers that are “allowed to send to” or “prohibited to send to” (e.g., known trusted or compromised servers, certain IP ranges, server geographical locations etc.).

If users use the free servers deployed by the volunteers, there is a risk that the server code can maliciously record all queues and messages (even though encrypted) sent via the same transport connection and to gain a partial knowledge of the user’s communications graph and other meta-data. User clients can mitigate it by using some overlay network that protects the privacy of TCP connections, e.g., Tor, and by sending noise traffic between the end users.

The servers authorize users to access (send/receive/etc.) their message queues via a digital signature of transmissions using a unique key pair different for each queue sender and recipient, so no information that is required for the server to authorize users allows to aggregate user communications across multiple queues.

### Transport

SimpleX network does not rely on transport or overlay network for server or client authentication. SMP protocol itself must provide integrity, forward secure confidentiality of communicating parties and mutual authentication even if transport protocol (but not the server) is compromised by the active attacker.

To protect against MITM attack on the transport, the clients should verify server self-signed certificate during TLS handshake by validating its pre-shared hash of the certificate in the server address (either as part of client configuration or passed in SMP connection request).

Clients use TLS1.3 protocol to connect to the server, restricting supported cryptographic protocols as defined in SimpleX Messaging Protocol.

After TCP transport connection is established, and the server is authenticated, the client sends blocks of a fixed size 16Kb, and the server replies with the blocks of the same size. When the actual message is smaller, it should be padded before encryption, and if it is larger, it can be split to chunks by the client application. The first blocks from the client and the server should include protocol version so that the party with the higher version can confirm compatibility and the transport channel identifier as described in SMP protocol.

Client can terminate the server transport connection without losing any messages – removal of the message from the server and the delivery of the next message happens when the client acknowledges the message reception (normally, after it is persisted in the client’s database).

Depending on the privacy requirements of the users, the client can use a separate transport connection per queue, or receive messages from multiple queues via a single transport connection, for efficiency. In our implementations this configuration will be available to the end users. At the same time, we will aim to minimize available user choices that affect security and privacy, making all options as clear as possible, and present them under a single "privacy slider", analogous to Tor's security slider.

### Server implementation

- does not store user access logs.

- does not store messages after the client has received them.

- permanently removes queues after they are deleted by the users

- only stores messages in transit in server operating memory; as *clients are expected to use multiple servers to deliver each message* (AMENDED based on the comment) , the message loss in one of the servers is acceptable.

### SimpleX clients and agents

Clients are assumed to be running on the trusted devices and can use the locally encrypted storage for messages, contacts, groups and other resources.

SimpleX clients implementing application-level protocols communicate with SimpleX servers via agents. SimpleX agents can be accessed in one of the following ways:

- via TCP network using trusted network connection or an overlay transport network.

- via local port (when the agent runs on the same device as a separate process).

- via agent library, when the agent logic is included directly into the client application.

The last option is the most secure, as it reduces the number of attack vectors in comparison with other options. The current implementation of SimpleX Chat uses this approach.

SimpleX agents provide the following operations:

- Creating and managing bi-directional (duplex) client connections and delivering messages via redundant groups of SimpleX queues.

- Exchanging keys and providing end-to-end encryption. The current prototype uses RSA cryptography with ad-hoc hybrid encryption scheme, we are currently switching it to X3DH for key exchange and double ratchet protocol for E2E encryption.

Communication between the client and the agent and the communication between the agents (via end-to-end encrypted messages delivered via SMP protocol) is described by SimpleX Agent Protocol.

Bi-directional client connections consist of multiple “send” and multiple “receive” queues (for redundancy) that agents use to send and receive messages; each queue should be used for limited amount of time, the rotation of queues is negotiated using SimpleX Agent Protocol.

There are two ways that SimpleX network users can establish the connection:

- Users communicate the initial connection invitation out-of-band, via link or via QR code. This out-of-band communication is assumed secure against active attacks and insecure against passive attacks. Once the connection is established that users are assumed to have confirmed out-of-band, the connection can no longer be compromised even if out-of-band invitation was obtained by the attacker. This out-of-band invitation does not contain any personal information, only the address of the queue and public key for the key exchange for end-to-end encryption.

- Users can create a “contact queue(s)” on SMP servers that would be used to receive connection requests. The important distinction with commonly used addressing systems is that this queue is only used to pass the connection request and not for subsequent messages. So, while it is possible to spam users who created such contact queues with connection requests, they can be removed without disrupting the communication with the existing contacts.

The reply queue addresses and the key exchange for the reply queues is negotiated via the direct queue.

### Message encryption

Messages are encrypted end-to-end using double ratchet protocol. Once the sending client deletes messages it won’t be able to decrypt them again. While messages are numbered within the queue, this only reveals to the servers how messages have been exchanged in a given queue that has a limited lifetime, so the total number of messages exchanged between contacts is not revealed.

The next queue to use is negotiated between agents in encrypted messages, and in most cases, it will be on another server (unless the client is configured to use one server, which is not recommended).

### Client storage

It is assumed that the client device and the storage is trusted, but clients can implement storage encryption using a user-provided passphrase.

## Threat model

### Assumptions

User protects their information and keys.

SimpleX Chat software is authentic.

User device is not compromised, excluding the scenarios below where it is explicitly stated it is compromised.

Used cryptographic primitives are not compromised.

The used servers are not directly tied to someone's identity or have and distinguishing information about the users.

### SimpleX Messaging Protocol server

**can:**

- learn a user's IP address, track them through other IP addresses they use to access to same queue, and infer information (e.g. employer) based on the IP addresses, as long as Tor is not used.

- learn when a queue recipient or sender is online via transmission times.

- lie about the state of a queue to the recipient and/or to the sender  (e.g. suspended or deleted when it is not).

- prevent message delivery.

- correlate multiple queues to a single user in case they are accessed via the same transport connection or from the same IP address.

- correlate multiple queues to a single user based on the time they are accessed.

- know how many messages is sent via the queue, clients can mitigate it with noise traffic.

- add, drop, duplicate or corrupt messages, but it will be detected by the client on SimpleX Agent Protocol level. Using multiple servers to deliver each message mitigates the loss of messages.

**cannot:**

- decrypt messages

- compromise e2e encryption with MITM attack (as server is only used to pass one of two keys in DH exchange, the first key is passed out-of-band)

### A passive adversary able to monitor a set of senders and recipients

**can:**

- learn who is using SimpleX Chat.

- learn when messages are sent and received.

- learn which SimpleX Messaging Protocol servers are used.

- in case of low traffic on the servers, correlate senders and recipients within the monitored set by the time messages sent and received.

- observe the approximate size of the files transmitted – to O(log log M) of file size precision.

**cannot, even in case of compromised transport protocol:**

- correlate senders and recipients by the content of messages (as different queue IDs are used for senders and recipients, with additional encryption layer in the delivered messages).

### A passive adversary able to monitor the traffic of one user

**can:**

- observe when a user is using SimpleX Chat.

- learn when messages are sent and received.

- block SimpleX Chat traffic.

- determine which servers the user communicates with.

- observe the approximate size of files transmissions and receptions.

**cannot:**

- see who sends messages to the user and who the user sends the messages to

### An attacker who obtained user’s decrypted chat database

**can:**

- see the history of all messages

- see shared profiles of contacts and groups

- receive new user messages, but the user will be alerted that an unknown device is connected to their message queues, as long as they are online at the same time, as message queues only allow one active subscription, and when any client subscribes to the queue, currently subscribed client is unsubscribed and notified.

- remove user messages from the queue, but the user will detect it when they receive the next message, as the number and the hash of the previous message won’t match.

- remove user messages from the queue continuously, preventing a user from receiving any messages and detecting that some messages are missing, but the user would detect it by the absence of status updates from their contacts that can be regularly sent even when no user-created messages are sent by their contacts.

- delete user’s message queues, so the contacts won’t be able to send messages.

- send messages from the user to their contacts, but the recipients will detect it as soon as the user sends the next message, because the previous message hash won’t match (and potentially won’t be able to decrypt them in case they don’t keep the previous ratchet keys).

**cannot:**

- impersonate a sender and send messages to the user whose database was stolen without also compromising the server (to place the message in the queue) or the user's device at a subsequent time (to place the message in the database).

### A user’s contact

**can:**

- spam the user with messages.

- forever retain messages from the user.

**cannot:**

- cryptographically prove to a third-party that a message came from a user (assuming a user’s device is not seized)

- prove that two contacts they have is the same user. Implementation should take care to only use correct cryptographic keys associated with a given queue (or connection, for E2E keys) for this claim to hold true.

- two contacts cannot confirm if they are communicating with the same user.

### An attacker with Internet access

**can:**

- DoS SimpleX messaging servers.

- spam the user who created a “contact queue” (queue for accepting connection requests) by sending multiple connection requests.

**cannot:**

- send messages to the user who they are not connected with.
