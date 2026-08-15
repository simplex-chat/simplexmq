---
Proposed: 2026-08-09
Protocol: agent-protocol v8
Diagram: ../protocol/diagrams/duplex-messaging/queue-rotation-fast.svg
---

# Fast queue rotation

## Problem

In the current rotation the peer returns `QKEY` to the initiator over the initiator's current
receiving queue. When that queue's server is unavailable the rotation cannot complete, so a client
cannot move away from a failed server.

## Solution

Both the current rotation and v8 add a queue, deliver to both queues while the rotation is in
progress, and remove the old queue; the recipient drops duplicates in both. The main difference is where
the new queue's secret is established. In the current rotation it is established over the current
queue, by `QKEY`, so it cannot complete when the current server is down. In v8 the peer establishes the
new queue's secret over the new queue itself — a confirmation it sends on R' — so establishing the
secret no longer depends on the current queue, and the rotation completes even when the current server
is down.

v8 also starts writing to both queues earlier: from the moment the queue is added, including the
current queue's not-yet-delivered backlog. So the initiator adds the new queue with `QADD`; from that
point the peer writes every message to both the current queue and R'. Once R' is secured the peer
writes new messages to it alone, while the current queue delivers whatever was already scheduled on it
and a final `QEND`, and is then removed. Because the recipient drops duplicates, neither the order of
arrival nor which queue carries a message matters, provided each message arrives on at least one queue
— with one exception, the confirmation, which is always the first message on R'. A dead new queue does
not stop delivery either, because the current queue keeps delivering until R' is secured.

Roles: A initiates (its receiving queue rotates; A receives on the new queue R'). B is the peer (B
holds the sending queue to A, secures R', and delivers to both).

Sequence:

    A -> R'       : create new queue (messaging mode, SKEY allowed)
    A -> S -> B   : QADD(R')          (over A's sending queue; A's current server untouched)
    B             : from QADD, schedule every message and the current backlog on both queues
    B -> current  : deliver the scheduled messages (R' holds its copies while securing)
    B -> R'       : SKEY              (authorize B as sender)
    B -> R'       : confirmation      (empty; establishes R' secret; first message on R')
    B -> R'       : deliver R''s held copies (A dedups), then new messages to R' only
    B -> current  : deliver the remaining tail, then QEND(current)
    B -> R'       : QEND(current)
    A             : on QEND, delete the current queue; keep receiving on R'

## Confirmation

The confirmation is the only message a recipient can read on a queue that is not yet secured, and it
establishes the queue's shared secret without depending on the current queue. Because a data message
that reached R' before the confirmation could not be read, the confirmation is the first message the
peer sends on R', and the peer does not start ordinary delivery on R' until the confirmation has been
sent.

The confirmation body is empty: both parties already know each other, so no profile or reply queue is
sent. It is sealed by the queue's box (keyed by the shared secret being established) and is not
additionally encrypted with the double ratchet, so rotation does not advance the message ratchet.

## Termination

`QEND` names a queue to remove and is delivered on both queues. On receipt the recipient deletes the
named queue; on send the peer removes its sending queue of that address. `QEND` is a general
queue-removal message — the peer can remove either queue with it — so on the wire a rotation is the
addition of a queue (`QADD`) and the later removal of the replaced one (`QEND`), each an ordinary
operation on the queue set rather than a `QTEST`-style completion. Delivering `QEND` on the removed
queue is best effort; the copy on the surviving queue removes it and reaches the recipient even when
the removed server is dead.

## Per-queue secret

R' secret is a fresh Diffie-Hellman between the peer's queue key, sent in the confirmation header, and
the initiator's R' key. It does not depend on any current queue, so redundancy of current queues is
unaffected.

## Compatibility

Fast rotation runs only when the connection's agreed agent protocol version is 8 or higher; the peer
chooses it. Otherwise the `QKEY`/`QUSE` exchange is used. `QEND` is defined at version 8 and is only
sent during fast rotation, so peers below version 8 never receive it.

    new A / new B  : fast (QADD, confirmation on R', QEND)
    new A / old B  : slow (old B returns QKEY; new A keeps the QKEY/QUSE handling)
    old A / new B  : slow (agreed version below 8; new B returns QKEY)
    old A / old B  : slow

The recipient does not choose by version; it reacts to whichever message arrives — `QKEY`, or a
confirmation on R' followed later by `QEND`.

## Dead current server

The initiator keeps reading messages on the new queue and removes the current queue when `QEND`
arrives there, without waiting for the current server. Nothing is lost, because every message is
scheduled on the new queue; the only cleanup that a dead current server delays is the deletion
of its queue, which is retried a bounded number of times and then abandoned.
