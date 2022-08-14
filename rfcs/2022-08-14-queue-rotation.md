# SMP queue rotation and redundancy

## Problem

1. Long term usage of the queue allows the servers to analyse long term traffic patterns.

2. If the user changes the configured SMP server(s), the previously created contacts do not migrate to the new server(s).

3. Server can lose messages.

## Solution

Additional messages exchanged by SMP agents to negotiate addition and removal of queues to the connection.

This approach allows for both rotation and redundancy, as changing queue will be done be adding a queue and then removing the existing queue.

The reason for this approach is that otherwise it's non-trivial to switch from one queue to another without losing messages or delivering them out of order, it's easier to have messages delivered via both queues during the switch, however short or long time it is.

### Messages

Additional agent messages required for the protocol:

`ADD`: add the new queue address(es), the same format as `REPLY` message, encoded as `A`.

`KEY`: pass sender's key via existing connection (SMP confirmation message will not be used, to avoid the same "race" of the initial key exchange that would create the risk of intercepting the queue for the attacker), encoded as `K`.

`USE`: instruct the sender to use the new queue with sender's queue ID as parameter, encoded as `U`.

`DEL`: instruct the sender to stop using the previous queue, encoded as `X`

### Protocol

```
participant A as Alice
participant B as Bob
participant R as Server that has A's receive queue
participant S as Server that has A's send queue (B's receive queue)
participant R' as Server that hosts the new A's receive queue

A ->> R': create new queue
A ->> S ->> B: ADD (R'): address of the new queue
B ->> R ->> A: KEY (R'): sender's key for the new queue (to avoid the race of SMP confirmation for the initial exchange)
A ->> R': secure queue
A ->> S ->> B: USE (R'): instruction to use new queue
B ->> R' ->> A: HELLO
B ->> R,R' ->> A: send all new messages to both queues
A ->> S: DEL (R): the previous queue deleted
B ->> R' ->> A: send all new messages to the new queue only
```
