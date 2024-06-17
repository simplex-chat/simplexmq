# Faster connection establishment

## Problem

SMP protocol is unidirectional, and to create a connection users have to agree two messaging queues.

V1 of handshake protocol required 5 messages and multiple HELLO sent between the users, which consumed a lot of traffic.

V2 of handshake protocol was optimized to remove multiple HELLO and also REPLY message, thanks to including queue address together with the key to secure this queue into the confirmation message.

This eliminated unnecessary traffic from repeated HELLOs, but still requires 4 messages in total and 2 times of each client being online. It is perceived by the users as "it didn't work" (because they see "connecting" after using the link) or "we have to be online at the same time" (and even in this case it is slow on bad network). This probably something that hurts both usability a lot and creates a lot of churn, as unless people are onboarded by the friends who know how the apps work, they cannot figure out how to connect.

Ideally, we want to have handshake protocol design when an accepting user can send messages straight after using the link (their client says "connected") and the initiating client can send messages as soon as it received confirmation message with the profile.

This RFC proposes modifications to SMP and SMP Agent protocols to reduce the number of required messages to 2 and allows accepting client to send messages straight after receiving HELLO message (to further improve usability we could allow this client queueing messages as pending, to be sent as one batch, without seeing the recipient profile, so we should add an option to enter a temporary alias into the screen where the link is pasted or scanned) and the initiating client can send the messages straight after processing the confirmation.

## Solution

1. Initiating client will add to the invitation link and to the contact address the public key that the receiving client will use to secure the reply queue.
2. Accepting client will create the queue as secured (NEW command is modified as otherwise the client would have to wait for IDS response before being able to secure the queue with KEY). With the old servers we have two options: 1) secure it with a separate command before sending the confirmation with "secured" flag to the initiating client; 2) do not support faster handshake with the old servers.
3. Initiating client secures its queue and sends HELLO with its profile. At this point it can already send messages without waiting for the reply.

See [this sequence diagram](../protocol/diagrams/duplex-messaging/duplex-creating-v6.mmd) for the updated handshake protocol.

## Further improvement

We can further improve handshake protocol with just 1 confirmation message by allowing the sender to secure the queue created by the recipient.

The current protocol design allows additional confirmation step where the initiating client user can confirm the connection having received the profile of the sender. We don't do it in the UI - this confirmation is done automatically, without any conditions.

Instead of requiring the initiating client to secure its queue with sender's key, we can allow that the accepting client to secure it with the additional SKEY command. This would avoid "connecting" state but would introduce "Profile unknown" state where the accepting client does not yet have the profile of the initiating client. In this case we could also use the non-optional alias created during the connection (or have something like "Add alias to be able to send messages immediately" and show warning if the user proceeds without it).

The additional advantage here is that if the queue of the initiating client was removed, the connection will not procede to create additional queue, failing faster.

See [this sequence diagram](../protocol/diagrams/duplex-messaging/duplex-creating-v6a.mmd) for the simplified handshake protocol.
