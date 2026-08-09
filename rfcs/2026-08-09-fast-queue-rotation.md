---
Proposed: 2026-08-09
Protocol: agent-protocol v8
Diagram: ./diagrams/duplex-messaging/queue-rotation-fast.svg
---

# Fast queue rotation (SKEY)

## Problem

In the current rotation the peer returns `QKEY` to the initiator over the
initiator's current receiving queue. When that queue's server is unavailable the
rotation cannot complete, so a client cannot move away from a failed server.

## Solution

When both agents support v8, the peer secures the new queue itself with `SKEY`,
as in the fast connection handshake, and sends an empty confirmation to it
instead of returning `QKEY`. This replaces the `QKEY` and `QUSE` exchange. The
initiator's current server is used only to delete the old queue at the end, and
that deletion does not block completion.

Roles: A initiates (its receiving queue moves; A receives on R'); B is the peer
(B holds the sending queue to A, and secures R' and sends to it).

Sequence (as drawn in the diagram):

    A -> R'      : create new queue (messaging mode, SKEY allowed)
    A -> S -> B  : QADD(R')          (over A's sending queue; A's current server untouched)
    B -> R'      : SKEY              (B secures R')
    B -> R'      : confirmation      (empty)
    R' -> A      : confirmation      (A derives R' secret, completes the switch)
    A -> R (old) : delete            (best effort, skipped if the server is down)
    B -> R'      : messages

## Confirmation

The confirmation is the only message a recipient can read on a queue that is not
yet secured, and it is what establishes the queue's shared secret. This is why
it, rather than an ordinary message, carries the rotation: the earlier abandoned
attempt sent the securing message as an ordinary message, which required the
secret it was establishing.

The confirmation body is empty: both parties already know each other, so no
profile or reply queue is sent. The body is sealed by the queue's NaCl box
(keyed by the shared secret being established) and is not additionally encrypted
with the double ratchet, so the rotation does not advance the message ratchet.
No ratchet key parameters are included, as in the SKEY handshake.

No new agent message is defined. Both parties already know which queue is being
replaced — the initiator because it created R' to replace a specific queue, the
peer because `QADD` states the replaced sending-queue address — so no marker is
needed on the wire.

## Per-queue secret

R' secret is a fresh Diffie-Hellman between the peer's queue key, sent in the
confirmation header, and the initiator's R' key. It does not depend on any
current queue, so redundancy (several current queues) is unaffected.

## Compatibility

Fast rotation runs only when the connection's agreed agent protocol version is 8
or higher; the peer chooses it. Otherwise the `QKEY`/`QUSE` exchange is used.

    new A / new B  : fast (QADD, confirmation)
    new A / old B  : slow (old B returns QKEY; new A keeps the QKEY/QUSE handling)
    old A / new B  : slow (agreed version below 8; new B returns QKEY)
    old A / old B  : slow

The recipient does not choose by version; it reacts to whichever message arrives
(`QKEY` or a confirmation on R').

## Dead current server

The initiator completes the switch and stops using the old queue without waiting
for the old queue to be deleted on its server. Deletion is retried a bounded
number of times and then abandoned, so an unavailable current server never
blocks the rotation.
