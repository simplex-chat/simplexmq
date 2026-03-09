Revision 1, 2026-03-09

# SimpleX Network: Security

This document describes the cryptographic primitives and threat model for the SimpleX network. For a general introduction, see [SimpleX: messaging and application platform](./overview-tjr.md).

## Table of contents

- [Encryption primitives](#encryption-primitives)
- [Threat model](#threat-model)
  - [Global assumptions](#global-assumptions)
  - [A passive adversary able to monitor the traffic of one user](#a-passive-adversary-able-to-monitor-the-traffic-of-one-user)
  - [A passive adversary able to monitor a set of senders and recipients](#a-passive-adversary-able-to-monitor-a-set-of-senders-and-recipients)
  - [SimpleX Messaging Protocol router](#simplex-messaging-protocol-router)
  - [SimpleX Messaging Protocol router that proxies messages](#simplex-messaging-protocol-router-that-proxies-messages)
  - [An attacker who obtained a user's decrypted chat database](#an-attacker-who-obtained-a-users-decrypted-chat-database)
  - [A user's contact](#a-users-contact)
  - [An attacker who observes an introduction message](#an-attacker-who-observes-an-introduction-message)
  - [An attacker with Internet access](#an-attacker-with-internet-access)


## Encryption primitives

- **Router command authorization**: X25519 DH-based authenticated encryption (SMP v7+), providing sender deniability. Ed25519 signatures used for recipient commands and notifier commands.

- **Per-queue key agreement**: Curve25519 DH exchange to agree:
  - the shared secret between router and recipient (to encrypt message bodies — avoids shared ciphertext in sender and recipient traffic),
  - the shared secret between sender and recipient (to encrypt messages end-to-end in each queue — avoids shared ciphertext in redundant queues).

- **SMP-layer encryption**: [NaCl crypto_box](https://nacl.cr.yp.to/box.html) (curve25519xsalsa20poly1305) for message body encryption between router and recipient, and for e2e per-queue encryption.

- **Certificate validation**: SHA256 to validate router offline certificates.

- **End-to-end encryption**: [Double ratchet](https://signal.org/docs/specifications/doubleratchet/) protocol:
  - Curve448 keys for shared secret agreement via [X3DH](https://signal.org/docs/specifications/x3dh/) with 2 ephemeral keys per side,
  - optional [SNTRUP761](https://ntruprime.cr.yp.to/) post-quantum KEM running in parallel with the DH ratchet (see [PQDR](./pqdr.md)), providing post-quantum forward secrecy,
  - AES-GCM AEAD cipher,
  - SHA512-based HKDF for key derivation.


## Threat model

### Global assumptions

- A user protects their local database and key material.
- The user's application is authentic, and no local malware is running.
- The cryptographic primitives in use are not broken.
- A user's choice of routers is not directly tied to their identity or otherwise represents distinguishing information about the user.
- The user's client uses 2-hop onion message routing.


### A passive adversary able to monitor the traffic of one user

*can:*

- identify that and when a user is using SimpleX.

- determine which routers the user receives messages from.

- observe how much traffic is being sent, and make guesses as to its purpose.

*cannot:*

- see who sends messages to the user and who the user sends messages to.

- determine the routers used by users' contacts.


### A passive adversary able to monitor a set of senders and recipients

*can:*

- identify who and when is using SimpleX.

- learn which SMP routers are used as receive queues for which users.

- learn when messages are sent and received.

- perform traffic correlation attacks against senders and recipients within the monitored set, frustrated by the number of users on the routers.

- observe how much traffic is being sent, and make guesses as to its purpose.

*cannot, even in case of a compromised transport protocol:*

- perform traffic correlation attacks with any increase in efficiency over a non-compromised transport protocol.


### SimpleX Messaging Protocol router

*can:*

- learn when a queue recipient is online.

- know how many messages are sent via the queue (some may be noise or non-content messages).

- learn which messages would trigger notifications even if a user does not use [push notifications](./push-notifications.md).

- correlate queues to a single user via re-used transport connection, IP address, or connection timing regularities.

- learn a recipient's IP address, track them through other IP addresses they use to access the same queue, and infer information (e.g. employer) based on IP addresses, as long as Tor is not used.

- drop all future messages inserted into a queue, detectable only over other, redundant queues.

- lie about queue state to the recipient and/or sender (e.g. suspended or deleted when it is not).

- spam a user with invalid messages.

*cannot:*

- undetectably add, duplicate, or corrupt individual messages.

- undetectably drop individual messages, so long as a subsequent message is delivered.

- learn the contents or type of messages.

- distinguish noise messages from regular messages except via timing regularities.

- compromise the users' end-to-end encryption with an active attack.

- learn a sender's IP address, track them through other IP addresses they use to access the same queue, and infer information (e.g. employer) based on IP addresses, even if Tor is not used (provided messages are sent via proxy SMP router).

- perform senders' queue correlation (matching multiple queues to a single sender) via either a re-used transport connection, user's IP Address, or connection timing regularities, unless it has additional information from the proxy SMP router (provided messages are sent via proxy SMP router).


### SimpleX Messaging Protocol router that proxies messages

*can:*

- learn a sender's IP address, as long as Tor is not used.

- learn when a sender with a given IP address is online.

- know how many messages are sent from a given IP address and to a given destination SMP router.

- drop all messages from a given IP address or to a given destination router.

- unless the destination SMP router detects repeated public DH keys of senders, replay messages to a destination router within a single session, causing either duplicate message delivery (which will be detected and ignored by the receiving clients), or, when receiving client is not connected to SMP router, exhausting capacity of destination queues used within the session.

*cannot:*

- perform queue correlation (matching multiple queues to a single user), unless it has additional information from the destination SMP router.

- undetectably add, duplicate, or corrupt individual messages.

- undetectably drop individual messages, so long as a subsequent message is delivered.

- learn the contents or type of messages.

- learn which messages would trigger notifications.

- learn the destination queues of messages.

- distinguish noise messages from regular messages except via timing regularities.

- compromise the user's end-to-end encryption with another user via an active attack.

- compromise the user's end-to-end encryption with the destination SMP routers via an active attack.


### An attacker who obtained a user's decrypted chat database

*can:*

- see the history of all messages exchanged with communication partners.

- see shared profiles of contacts and groups.

- surreptitiously receive new messages sent via existing queues; until communication queues are rotated or the Double-Ratchet advances forward.

- prevent the user from receiving all new messages — either surreptitiously by emptying the queues regularly or overtly by deleting them.

- send messages from the user to their contacts; recipients will detect it as soon as the user sends the next message, because the previous message hash won't match (and potentially won't be able to decrypt them in case they don't keep the previous ratchet keys).

*cannot:*

- impersonate a sender and send messages to the user whose database was stolen. Doing so requires also compromising the router (to place the message in the queue, that is possible until the Double-Ratchet advances forward) or the user's device at a subsequent time (to place the message in the database).

- undetectably communicate at the same time as the user with their contacts. Doing so would result in the contact getting different messages with repeated IDs.

- undetectably monitor message queues in realtime without alerting the user they are doing so, as a second subscription request unsubscribes the first and notifies the second.


### A user's contact

*can:*

- spam the user with messages.

- forever retain messages from the user.

*cannot:*

- cryptographically prove to a third-party that a message came from a user. Since SMP v7, sender command authorization uses DH-based authenticated encryption (not signatures), providing cryptographic deniability at the transport layer in addition to the double ratchet's deniability at the e2e layer.

- prove that two contacts they have is the same user.

- collaborate with another of the user's contacts to confirm they are communicating with the same user.


### An attacker who observes an introduction message

*can:*

- Impersonate the recipient (Bob) to the sender (Alice).

*cannot:*

- Impersonate the sender (Alice) to the recipient (Bob).


### An attacker with Internet access

*can:*

- Denial of Service SimpleX messaging routers.

- spam a user's public "contact queue" with connection requests.

*cannot:*

- send messages to a user who they are not connected with.

- enumerate queues on a SimpleX router.
