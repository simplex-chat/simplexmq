# SMP queue rotation and redundancy

## Problem

1. Long term usage of the queue allows the servers to analyze long term traffic patterns.

2. If the user changes the configured SMP server(s), the previously created contacts do not migrate to the new server(s).

3. Server can lose messages.

## Solution

Additional messages exchanged by SMP agents to negotiate addition and removal of queues to the connection.

This approach allows for both rotation and redundancy, as changing queue will be done be adding a queue and then removing the existing queue.

The reason for this approach is that otherwise it's non-trivial to switch from one queue to another without losing messages or delivering them out of order, it's easier to have messages delivered via both queues during the switch, however short or long time it is.

### Messages

Additional agent messages required for the protocol:

    QADD_ -> "QA"
    QKEY_ -> "QK"
    QUSE_ -> "QU"
    QTEST_ -> "QT"
    QDEL_ -> "QD"
    QEND_ -> "QE"

`QADD`: add the new queue address(es), the same format as `REPLY` message, encoded as `QA`.

`QKEY`: pass sender's key via existing connection (SMP confirmation message will not be used, to avoid the same "race" of the initial key exchange that would create the risk of intercepting the queue for the attacker), encoded as `QK`.

`QUSE`: instruct the sender to use the new queue with sender's queue ID as parameter, encoded as `QU`.

`QTEST`: send test message to the new connection, encoded as `QT`. Any other message can be sent if available to continue rotation, the absence of this message is not an error.

`QDEL`: instruct the sender to stop using the previous queue, encoded as `QD`

`QEND`: notify the recipient that no messages will be sent to this queue, encoded as `QE`. The recipient will delete this queue.

### Protocol

```
participant A as Alice
participant B as Bob
participant R as Server that has A's receive queue
participant S as Server that has A's send queue (B's receive queue)
participant R' as Server that hosts the new A's receive queue

A ->> R': create new queue
A ->> S ->> B: QADD (R'): snd address of the new queue(s)
B ->> A(R) ->> A: QKEY (R'): sender's key for the new queue(s) (to avoid the race of SMP confirmation for the initial exchange)
A ->> S(R'): secure new queue
A ->> S ->> B: QUSE (R'): instruction to use new queue(s)
B ->> A(R,R') ->> A: QTEST
B ->> A(R,R') ->> A: send all new messages to both queues
A ->> S ->> B: QDEL (R): instruction to delete the old queue
B ->> A(R') -> A: QEND (R): notification that no messages will be sent to the old queue
B ->> R' ->> A: send all new messages to the new queue only
A ->> S(R): DEL: delete the previous queue
```
