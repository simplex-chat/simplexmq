---
Proposed: 2026-08-09
Protocol: agent-protocol v8
Diagram: ./diagrams/duplex-messaging/queue-rotation-fast.svg
---

# Fast queue rotation (redundant delivery)

## Problem

In the current rotation the peer returns `QKEY` to the initiator over the initiator's current
receiving queue. When that queue's server is unavailable the rotation cannot complete, so a client
cannot move away from a failed server.

## Solution

When both agents support v8, rotation is redundant delivery rather than a switch. The initiator adds
a new queue with `QADD`; from that point the peer writes every message to both the current queue and
the new queue, and secures the new queue in parallel. Once the new queue is secured the peer writes
new messages to it alone, while the current queue delivers whatever was already scheduled on it and a
final `QEND`, and is then removed. The recipient already drops duplicate messages, so the order of
delivery and which queue delivers a given message do not matter, provided every message arrives on at
least one queue. There is no boundary and no flip.

Rotation away from a dead current server works because every message is also scheduled on the new
queue: the recipient reads it there. A dead new queue does not stop delivery either, because the
current queue keeps delivering until the new one is secured.

Roles: A initiates (its receiving queue rotates; A receives on the new queue R'). B is the peer (B
holds the sending queue to A, secures R', and delivers to both).

Sequence (as drawn in the diagram):

    A -> R'      : create new queue (messaging mode, SKEY allowed)
    A -> S -> B  : QADD(R')          (over A's sending queue; A's current server untouched)
    B            : from now, schedule every message on both the current queue and R'
    B -> both    : messages          (current queue and R', duplicates dropped by A)
    B -> R'      : SKEY              (B secures R')
    B -> R'      : confirmation      (empty; establishes R' secret; first message on R')
    B           : R' secured — new messages now go to R' only
    B -> current : remaining tail, then QEND(current)
    B -> R'      : QEND(current), then new messages
    A            : on QEND, delete the current queue; keep receiving on R'

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
queue-removal message — the peer can remove either queue with it — so rotation is the addition of a
queue (`QADD`) followed by the removal of a queue (`QEND`), with no distinct switch step. Delivering
`QEND` on the removed queue is best effort; the copy on the surviving queue removes it and reaches the
recipient even when the removed server is dead.

## Per-queue secret

R' secret is a fresh Diffie-Hellman between the peer's queue key, sent in the confirmation header, and
the initiator's R' key. It does not depend on any current queue, so redundancy of current queues is
unaffected.

## Compatibility

Fast rotation runs only when the connection's agreed agent protocol version is 8 or higher; the peer
chooses it. Otherwise the `QKEY`/`QUSE` exchange is used. `QEND` is defined at version 8 and is only
sent during fast rotation, so peers below version 8 never receive it.

    new A / new B  : fast (QADD, confirmation, redundant delivery, QEND)
    new A / old B  : slow (old B returns QKEY; new A keeps the QKEY/QUSE handling)
    old A / new B  : slow (agreed version below 8; new B returns QKEY)
    old A / old B  : slow

The recipient does not choose by version; it reacts to whichever message arrives — `QKEY`, or a
confirmation on R' followed later by `QEND`.

## Dead current server

The initiator keeps reading messages on the new queue and removes the current queue when `QEND`
arrives there, without waiting for the current server. Nothing is lost, because every message is
scheduled on the new queue as well; the only cleanup that a dead current server delays is the deletion
of its queue, which is retried a bounded number of times and then abandoned.
