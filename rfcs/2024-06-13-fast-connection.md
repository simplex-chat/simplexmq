# Faster connection establishment

## Problem

SMP protocol is unidirectional, and to create a connection users have to agree two messaging queues.

V1 of handshake protocol required 5 messages and multiple HELLO sent between the users, which consumed a lot of traffic.

V2 of handshake protocol was optimized to remove multiple HELLO and also REPLY message, thanks to including queue address together with the key to secure this queue into the confirmation message.

This eliminated unnecessary traffic from repeated HELLOs, but still requires 4 messages in total and 2 times of each client being online. It is perceived by the users as "it didn't work" (because they see "connecting" after using the link) or "we have to be online at the same time" (and even in this case it is slow on bad network). This probably something that hurts both usability a lot and creates a lot of churn, as unless people are onboarded by the friends who know how the apps work, they cannot figure out how to connect.

Ideally, we want to have handshake protocol design when an accepting user can send messages straight after using the link (their client says "connected") and the initiating client can send messages as soon as it received confirmation message with the profile.

This RFC proposes modifications to SMP and SMP Agent protocols to reduce the number of required messages to 3 and allows accepting client to send messages straight after receiving HELLO message (to further improve usability we could allow this client queueing messages as pending, to be sent as one batch, without seeing the recipient profile, so we should add an option to enter a temporary alias into the screen where the link is pasted or scanned) and the initiating client can send the messages straight after processing the confirmation.

## Solution

1. Initiating client will add to the invitation link the public key that the receiving client will use to secure the queue.
2. Accepting client will create the queue as secured straight away (NEW command is modified as otherwise the client would have to wait for IDS response before being able to secure the queue) or with the old server will secure it before sending to the confirmation with "secured" flag to the initiating client.
3. Initiating client secures its queue and sends HELLO with its profile. At this point it can already send messages without waiting for the reply.
