# Faster connection establishment

## Problem

SMP protocol is unidirectional, and to create a connection users have to agree two messaging queues.

V1 of handshake protocol required 5 messages and multiple HELLO sent between the users, which consumed a lot of traffic.

V2 of handshake protocol was optimized to remove multiple HELLO and also REPLY message, thanks to including queue address together with the key to secure this queue into the confirmation message.

This eliminated unnecessary traffic from repeated HELLOs, but still requires 4 messages in total and 2 times of each client being online. It is perceived by the users as "it didn't work" (because they see "connecting" after using the link) or "we have to be online at the same time" (and even in this case it is slow on bad network). This hurts usability and creates churn of the new users, as unless people are onboarded by the friends who know how the app works, they cannot figure out how to connect.

Ideally, we want to have handshake protocol design when an accepting user can send messages straight after using the link (their client says "connected") and the initiating client can send messages as soon as it received confirmation message with the profile.

This RFC proposes modifications to SMP and SMP Agent protocols to reduce the number of required messages to 2 and allows accepting client to send messages straight after using the link (and sending the confirmation), before receiving the profile of the initiating client in the second message, and the initiating client can send the messages straight after processing the confirmation and sending its own confirmation.

## Solution

The current protocol design allows additional confirmation step where the initiating client can confirm the connection having received the profile of the sender. We don't use it in the UI - this confirmation is done automatically and unconditionally.

Instead of requiring the initiating client to secure its queue with sender's key, we can allow the accepting client to secure it with the additional SKEY command. This would avoid "connecting" state but would introduce "Profile unknown" state where the accepting client does not yet have the profile of the initiating client. In this case we could also use the non-optional alias created during the connection (or have something like "Add alias to be able to send messages immediately" and show warning if the user proceeds without it).

The additional advantage here is that if the queue of the initiating client was removed, the connection will not procede to create additional queue, failing faster.

These are the proposed changes:

1. Modify NEW command to add flag allowing sender to secure the queue (it should not be allowed if queue is created for the contact address).
2. Include flag into the invitation link URI and in reply address encoding that queue(s) can be secured by the sender (to avoid coupling with the protocol version and preserve the possibility of the longer handshakes).
3. Add SKEY command to SMP protocol to allow the sender securing the message queue.
4. This command has to be supported by SMP proxy as well, so that the sender does not connect to the recipient's server directly.
5. Accepting client will secure the messaging queue before sending the confirmation to it.
6. Initiating client will secure the messaging queue before sending the confirmation.

See [this sequence diagram](../protocol/diagrams/duplex-messaging/duplex-creating-fast.mmd) for the updated handshake protocol.

Changes to threat model: the attacker who compromised TLS and knows the queue address can block the connection, as the protocol no longer requires the recipient to decrypt the confirmation to secure the queue.

Possibly, "fast connection" should be an option in Privacy & security settings.

## Queue rotation

It is possible to design a faster connection rotation protocol that also uses only 2 instead of 4 messages, QADD and SMP confirmation (to agree per-queue encryption) - it would require to stop delivery to the old queue as soon as QSEC message is sent, without any additional test messages.

It would also require sending a new message envelope with the DH key in the public header instead of the usual confirmation message or a normal message.

## Implementation questions

Currently we store received confirmations in the database, so that the client can confirm them. This becomes unnecessary.
