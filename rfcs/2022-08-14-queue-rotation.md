# SMP queue rotation

## Problem

1. Long term usage of the queue allows the servers to analyse long term traffic patterns.

2. If the user changes the configured SMP server(s), the previously created contacts do not migrate to the new server(s).

## Solution

Additional messages exchanged by SMP agents to negotiate migration of the queues to the new server. I considered combining this with queue redundancy, but it increases scope and adds a lot of complexity before it is needed.

The proposed approach separates queue rotation from any queue redundancy that may be added in the future.

### Messages

Additional agent messages required for the protocol:

`SWITCH`: notify the sender that the queue has to be rotated to the new one, includes the address (server, sender ID and DH key) of the new queue. Encoded as `S`.

`KEYS`: pass sender's server key and DH key via existing connection (SMP confirmation message will not be used, to avoid the same "race" of the initial key exchange that would create the risk of intercepting the queue for the attacker), encoded as `K`.

`USE`: instruct the sender to use the new queue with sender's queue ID as parameter, encoded as `U`.

### Protocol

```
participant A as Alice
participant B as Bob
participant R as Server that has A's receive queue
participant S as Server that has A's send queue (B's receive queue)
participant R' as Server that hosts the new A's receive queue

A ->> R': create new queue without subscription
A ->> S ->> B: SWITCH (R'): address of the new queue
B ->> R ->> A: KEYS (R'): sender's key for the new queue (to avoid the race of SMP confirmation for the initial exchange)
B ->> R ->> A: continue sending new messages to the old queue
A ->> R': secure queue
A ->> S ->> B: USE (R'): instruction to use new queue
B ->> R' ->> A: HELLO: to validate that the sender can send messages to the new queue before switching to it
A ->> R: suspend queue, receive all messages
A ->> R: delete queue
A ->> R': subscribe to the new queue
B ->> R' ->> A: once sending fails with AUTH error, start sending new (and any undelivered) messages to the new queue
```

It will also require extending SMP protocol:

- allow creating the queue without subscribing to it (to avoid processing the messages that can arrive out of order).
- add message flag / meta-data indicating that this is the last message and the server has no more messages available (so that the recipient knows when it's safe to delete the queue).
