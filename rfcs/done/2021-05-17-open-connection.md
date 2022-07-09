# Open connections

## Problem

This proposal describes how to create invitations that can be used multiple times. 

It can be used for:
- an open invitation to join a group.
- an open invitation to connect to a person - e.g. QR code/invitation link on a person's website, or passed from one person to another.
- part of the solution for public DNS-based addresses (when a directory server would map address in some domain name#example.tld to an open invitation).

## Solution

No changes to SMP protocol - a dedicated unsecured SMP queue is used to receive invitations to connect that are sent in encrypted agent message. An unsecured SMP queue is used as an out-of-band channel for establishing another SMP queue.

Additional parameters in commands in SMP agent protocol:

- `NEW` command will have a parameter `INV` or `CON` to create an invitation or a permanent contact connection.

`conn_id? OPEN` (or `PUB`, `NEWPUB`, tbc) - to create an "open"/"public" queue, the response is an invitation in a different format (TBC):
  - should allow multiple servers (probably the original invitation should be extended to support it)
  - should have a marker to indicate it's an open/public queue (probably the original invitation should be extended to include an invitation type).

e.g. `smp:<queue_type>::<server1>/<queue_id1>,<server2>/<queue_id2>::<key1>`

`queue_type`:
  - `prv` - original invitation, should be accepted with KEY SMP message
  - `pub` - open invitation, should be accepted with INV SMP message (to be added to SMP protocol)

```mmd
A ->> AA: oidA? OPEN
AA ->> A: oidA INV pub_inv

...

B ->> BA: cidBA? JOIN pub_inv len CRLF meta_binary CRLF ; change command to require meta, len can be 0 for the current usage ; meta is used to send user profile
BA ->> B: cidBA OK
BA ->> SA ->> AA: INV prv_inv CRLF meta_binary
AA ->> A: oidA CONF invID len meta_binary
A ->> AA cidAB? LET invID

establish connection as usual

BA ->> B: cidBA CON
AA ->> A: cidAB CON
```

That protocol requires addressing the current problem when an invitation cannot be accepted when the party that generated the invitation is not online.

Questions.

1. Do we need to differentiate the semantics of the invitation on the syntax level, or should we allow to just manage it outside of protocol when the receiving agent decides which SMP messages to accept and which to ignore (KEY / INV).