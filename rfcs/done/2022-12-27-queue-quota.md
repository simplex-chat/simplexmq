# SMP and SMP agent protocol extensions to manage queue quotas

## Problem

SMP servers define a limit on the number of messages that can be stored on the server. When the sender reaches this limit, they continue trying to send the message with exponential back off, until the server allows it. To reduce the traffic we added expiration on unsent messages of 2 days that:

- adds its own set of problems because of expired control messages - e.g., group fragmentation.
- doesn't solve problem of traffic in active groups with many inactive members - there are still too many retries in queues that reached capacity.

## Solution

Sending agent permanently stops trying to send messages having received `ERR QUOTA` (or, for the period of clients migration, increases TTL much more than in cases of network errors).

Add SMP server event that means "quota reached" (e.g. `QTA` or `MSG QUOTA`) - it will be delivered to the recipient once all messages are retrieved at the same point in message stream where the sender received `ERR QUOTA`. Alternatively, it could be a message flag that is set on the last message in the queue at a point the sender received `ERR QUOTA`.

Add SMP agent message that means "quota available, resume sending" (e.g. `A_QTA` or `A_RESUME`) – the receiving agent will send it via the reply queue to the sending agent that will resume sending messages at this point.

Possibly, increase TTL for local messages to 30 days. That might require separately addressing the problem of permanently failing servers.

We discussed a possible solution of merging all messages to one server into one delivery queue, so that having multiple failing queues on this server will not result in multiple connection attempts, and this proposal also answers the question what to do with the messages when quota is exceeded - the whole queue can be marked as suspended, and processed separately from others - TBD.
