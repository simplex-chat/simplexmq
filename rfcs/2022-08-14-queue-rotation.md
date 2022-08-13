# SMP queue rotation

## Problem

1. Long term usage of the queue allows the servers to analyse long term traffic patterns.

2. If the user changes the configured SMP server(s), the previously created contacts do not migrate to the new server(s).

## Solution

Additional messages exchanged by SMP agents to negotiate migration of the connection to other receiving queue.

### Messages

Only two additional message is required:

`NEW` agent message to add the new queue address(es), having the same format as `REPLY` message, encoded as `N`.

`USE` agent message to remove the queue with sender's queue ID as parameter, encoded as `U`.

### Protocol

```
participant A as Alice
participant B as Bob
participant S as Server

A ->> S: createnew queue
A ->> S ->> B: NEW queue, sent to B's receive queue
B ->> S: confirm queue
A ->> S: secure queue
A ->> S ->> B: USE queue, sent to B's receive queue
B ->> S ->> A: HELLO
A ->> S: delete previous queue
```

The problem with the above protocol is that during switching from one queue to another the messages can be delivered out of order. One of the ways to avoid it is by having additional messages in the protocol so that the receiving client can communicate to the sending the last message it received via the queue, and the sending client will start sending to the new queue starting from this message. That would require sending agent to stop deleting sent messages as soon as it received NEW message and only delete them once the switch is complete.

Another approach would be considering queue rotation and redundancy as one problem and manage out-of-order delivery on the recipient side - e.g. if the message is delivered with the gap, there could be timeout before it's delivered to the user, and further timeout before integrity violation is reported, and also deduplication of messages - in this case all messages during the switch would be sent to both queues until the original queue is deleted.
