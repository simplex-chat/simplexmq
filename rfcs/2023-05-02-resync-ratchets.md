# Re-sync encryption ratchets, queue rotation, message delivery receipts

This is very unfocussed doc outlining several problems that seem somewhat related, and some possible solution approaches.

## Problems

When old database backup is used, the sending client encrypts the messages in a way that the receiving client cannot decrypt them, because it does not store the old keys, and does not try to decrypt ratchet headers using the old keys. When receiving the messages, the client that uses the old database is unable to decrypt them, either the header or the message itself (if more than 500 messages are skipped, or if root ratchet step happened).

The same symptoms happen during the queue rotation, unfortunately, as we do not keep the history of received messages once they are acknowledged, so the client reports these error to the users.

While these are two different problems, to the users they manifest in the same way, so it is difficult to differentiate.

Another ratchet problem that should be solved as well is not deleting unused skipped keys after some time or some number of events, possibly it should be considered at the same time.

While it is tempting to consider delivery receipts as an isolated problem, it is somewhat coupled, as the requests to re-sync ratchets and to re-deliver skipped messages are effectively delivery receipts.

A naive solution to delivery receipts when each message is responded to with a confirmation has two downsides:

- it doubles the traffic.
- in the absense of delays, it also leaks some information about the network latency, that can be used to track user's location.

Both problems can be mitigated by sending delivery receipts with a random delay, to confirm all messages sent, not each one. But this would only reduce the traffic when the sender sends many messages. Alternatively, we could think how to reduce the block size for SMP commands. The challenge is profile pictures and image previews, so to reduce traffic we need to start sending them as XFTP files, potentially with a smaller 64kb chunks (that would also increase preview quality).

## Solution for queue rotation

We need to:
- store and show the rotation status in the UI to prevent attempts to rotate the queue multiple times.
- process multiple message delivery events while there is a redundancy, to avoid errors in terminal.
- differentiate between decryption errors during queue rotation - that would require keeping the messages for some time, at least keeping their IDs and hashes together with some additional status. In this case when duplicate or old message arrives, we can check whether this message was already processed, and do not show error if it was.

## Solution to re-sync ratchets

When we establish that the receiving client is indeed unable to decrypt messages, we should:
- notify the user - it is already happening, but it happens in case of rotation as well.
- optionally, notify another client that message was not decrypted - this effectively becomes a delivery receipt. That could be a separate command triggered by the user in the UI.
- clients can get into this state at the same time, how do we handle concurrent requests? Possibly, we could design these messages so this is irrelevant whether the message is sent in response or not, and calculate the new ratchet keys once the clients have both the sent and received messages. After that both clients can send "ratchet reset" message:
  - EKEY - message containing a new set of keys to initialize the ratchets
  - EREADY - message confirming that the ratchet is ready, already e2e encrypted

The downside of this approach, is that unlike the initial handshake, where the second ratchet key is sent in e2e encrypted response, this message will be sent only encrypted with queue key. We could change this protocol by adding EREPLY message, and the clients would know to ingnore EKEY with bigger hash of the keys, so that the client who sent keys with smaller hash would be processing response from another client (that is if EKEY is received after EKEY is sent).

```
A                B

EKEY 1 ->        <- EKEY 2 (e2e encrypted with per-queue key only)
EKEY 2 <-        -> EKEY 1
1 < 2, wait      2 > 1, reply EREPLY 3 (e2e encrypted with ratchets)
ratchet: 1, 3   ratchet: 3, 1
```

Once ratchets are re-synched the clients could additionally request delivery of skipped messages. As ratchets being out of sync is not the only problem when messages can be lost, it may be managed independently from the ratchet re-sync. This problem seems tied with delivery receipts too, as requesting to re-deliver some messages automatically confirms that some other messages were delivered.

Alternatively, the request for ratchet sync can already contain the ID of the first failed message - that would allow the agent:
- stop sending messages until ratchets are in sync.
- re-deliver failed messages first.
- only then deliver any pending messages.

This approach would probably result in a better UX (no out of order delivery), but requires tracking pending messages that are not attempted to deliver and to also insert old messages in the delivery queue with the old IDs.
