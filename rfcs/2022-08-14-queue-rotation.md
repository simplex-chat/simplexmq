# SMP queue rotation

## Problem

1. Long term usage of the queue allows the servers to analyse long term traffic patterns.

2. If the user changes the configured SMP server(s), the previously created contacts do not migrate to the new server(s).

## Solution

Additional messages exchanged by SMP agents to negotiate migration of the queues to the new server. I considered combining this with queue redundancy, but it increases scope and adds a lot of complexity before it is needed.

The proposed approach separates queue rotation from any queue redundancy that may be added in the future.

### Messages

Additional agent messages required for the protocol:

`QNEW`: notify the sender that the queue has to be rotated to the new one, includes the address (server, sender ID and DH key) of the new queue. Encoded as `QN`.

`QKEYS`: pass sender's server key and DH key via existing connection (SMP confirmation message will not be used, to avoid the same "race" of the initial key exchange that would create the risk of intercepting the queue for the attacker), encoded as `QK`.

`QREADY`: instruct the sender that the new is ready to use with sender's queue address as parameter, encoded as `QR` - sender will send HELLO to the new queue.

`QHELLO`: sender sends to the new queue to confirm it's working, encoded as `QH`

`QSWITCH`: instruct the sender to use the new queue with sender's queue ID as parameter, encoded as `QR` - sent after receiving `QHELLO`.

### Protocol

```
participant A as Alice
participant B as Bob
participant R as Server that has A's receive queue
participant S as Server that has A's send queue (B's receive queue)
participant R' as Server that hosts the new A's receive queue

A ->> R': create new queue
A ->> S ->> B: QNEW (R'): address of the new queue
B ->> R ->> A: QKEYS (R'): sender's key for the new queue (to avoid the race of SMP confirmation for the initial exchange)
B ->> R ->> A: continue sending new messages to the old queue
A ->> R': secure queue
A ->> S ->> B: QREADY (R'): instruction to use new queue
B ->> R' ->> A: QHELLO: to validate that the sender can send messages to the new queue before switching to it
A ->> S ->> B: QSWITCH (R'): instruction to start using the new queue
B ->> R' ->> A: the first message received to the new queue before the old one is drained and deleted should not be processed, it should be stored in the agent memory (and not acknowledged) and only processed once the old queue is drained.
A ->> R: suspend queue, receive all messages
A ->> R: delete queue
B ->> R' ->> A: once sending fails with AUTH error, start sending new (and any undelivered) messages to the new queue
```

It will also require extending SMP protocol:

- add message flag / meta-data indicating that this is the last message and the server has no more messages available (so that the recipient knows when it's safe to delete the queue). Alternatively it can be NUL message that is sent after the last suspended message is received and in response to OFF command.
- when queue is suspended the server should return the remaining message count. It should be ok to suspend the queue again, so that if the agent is restarted and the queue status is suspended it can be suspended again to check the number of remaining messages.
