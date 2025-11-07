# Detecting and fixing state with service subscriptions

## Problem

While service certificates and subscriptions hugely decrease startup time and delivery delays on server restarts, they introduce the risk of losing subscriptions in case of state drifts. They also do not provide efficient mechanism for validating that the list of subscribed queues is in sync.

How can the state drift happen?

There are several possibilities:
- lost broker response would make the broker consider that the queue is associated, but the client won't know it, and will have to re-associate. While in itself it is not a problem, as it'll be resolved, it would make drift detected more frequently (regardless of the detection logic used). That service certificates are used on clients with good connection would make it less likely though.
- server state restored from the backup, in case of some failure. Nothing can be done to recover lost queues, but we may restore lost service associations.
- queue blocking or removal by server operator because of policy violation.
- server downgrade (when it loses all service associations) with subsequent upgrade - the client would think queues are associated, while they are not, and won't receive any messages at all in this scenario.
- any other server-side error or logic error.

In addition to the possibility of the drift, we simply need to have confidence that service subscriptions work as intended, without skipping queues. We ignored this consideration for notifications, as the tolerance to lost notifications is higher, but we can't ignore it for messages.

## Solution

Previously considered approach of sending NIL to all queues without messages is very expensive for traffic (most queues don't have messages), and it is also very expensive to detect and validate drift in the client because of asynchronous / concurrent events.

We cannot read all queues into memory, and we cannot aggregate all responses in memory, and we cannot create database writes on every single service subscription to say 1m queues (a realistic number), as it simply won't work well even at the current scale.

An approach of having an efficient way to detect drift, but load the full list of IDs when drift is detected, also won't work well, as drifts may be common, so we need both efficient way to detect there is diff and also to reconcile it.

### Drift detection

Both client and server would maintain the number of associated queues and the "symmetric" hash over the set of queue IDs. The requirements for this hash algorithm are:
- not cryptographically strong, to be fast.
- 128 bits to minimize collisions over the large set of millions of queues.
- symmetric - the result should not depend on ID order.
- allows fast additions and removals.

In this way, every time association is added or removed (including queue marked as deleted), both peers would recompute this hash in the same transaction.

The client would suspend sending and processing any other commands on the server and the queues of this server until SOKS response is received from this server, to prevent drift. It can be achieved with per-server semaphores/locks in memory. UI clients need to become responsive sooner than these responses are received, but we do not service certificates on UI clients, and chat relays may prevent operations on server queues until SOKS response is received.

SOKS response would include both the count of associated queues (as now) and the hash over all associated queue IDs (to be added). If both count and hash match, the client will not do anything. If either does not match the client would perform full sync (see below).

There is a value from doing the same in notification server as well to detect and "fix" drifts.

The algorithm to compute hashes can be the following.

1. Compute hash of each queue ID using xxHash3_128 ([xxhash-ffi](https://hackage.haskell.org/package/xxhash-ffi) library). They don't need to be stored or loaded at once, initially, it can be done with streaming if it is detected on start that there is no pre-computed hash.
2. Combine hashes using XOR. XOR is both commutative and associative, so it would produce the same aggregate hash irrespective of the ID order.
3. Adding queue ID to pre-computed hash requires a single XOR with ID hash: `new_aggregate = aggregate XOR hash(queue_id)`.
4. Removing queue ID from pre-computed hash also requires the same XOR (XOR is involutory, it undoes itself): `new_aggregate = aggregate XOR hash(queue_id)`.

These hashes need to be computed per user/server in the client and per service certificate in the server - on startup both have to validate and compute them once if necessary.

There can be also a start-up option to recompute hashe(s) to detect and fix any errors.

This is all rather simple and would help detecting drifts.

### Synchronization when drift is detected

The assumption here is that in most cases drifts are rare, and isolated to few IDs (e.g., this is the case with notification server).

But the algorithm should be resilient to losing all associations, and it should not be substantially worse than simply restoring all associations or loading all IDs.

We have `c_n` and `c_hash` for client-side count and hash of queue IDs and `s_n` and `s_hash` for server-side, which are returned in SOKS response to SUBS command.

1. If `c_n /= s_n || c_hash /= s_hash`, the client must perform sync.

2. If `abs(c_n - s_n) / max(c_n, s_n) > 0.5`, the client will request the full list of queues (more than half of the queues are different), and will perform diff with the queues it has. While performing the diff the client will continue block operations with this user/server.

3. Otherwise would perform some algorithm for determining the difference between queue IDs between client and server. This algorithm can be made efficient (`O(log N)`) by relying on efficient sorting of IDs and database loading of ranges, via computing and communicating hashes of ranges, and performing a binary search on ranges, with batching to optimize network traffic.

This algorithm is similar to Merkle tree reconcilliation, but it is optimized for database reading of ordered ranges, and for our 16kb block size to minimize network requests.

The algorithm:
1. The client would request all ranges from the server.
2. The server would compute hashes for N ranges of IDs and send them to the client. Each range would include start_id, optional end_id (for single ID ranges) and XOR-hash of the range. N is determined based on the block size and the range size.
3. The client would perform the same computation for the same ranges, and compare them with the returned ranges from the server, while detecting any gaps between ranges and missing range boundaries.
4. If more than half of the ranges don't match, the client would request the full list. Otherwise it would repeat the same algorithm for each mismatched range and for gaps.

It can be further optimized by merging adjacent ranges and by batching all range requests, it is quite simple.

Once the client determines the list of missing and extra queues it can:
- create associations (via SUB) for missing queues,
- request removal of association (a new command, e.g. BUS) for extra queues on the server.

The pseudocode for the algorightm:

For the server to return all ranges or subranges of requested range:

```haskell
getSubRanges :: Maybe (RecipientId, RecipientId) -> [(RecipientId, Maybe RecipientId, Hash)]
getSubRanges range_ = do
  ((min_id, max_id), s_n) <- case range_ of
    Nothing -> getAssociatedQueueRange -- with the certificate in the client session.
    Just range -> (range,) <$> getAssociatedQueueCount range
    if
      | s_n <= max_N -> reply_with_single_queue_ranges
      | otherwise -> do
          let range_size = s_n `div` max_N
          read_all_ranges -- in a recursive loop, with max_id, range_hash and next_min_id in each step
          reply_ranges
```

We don't need to implement this synchronization logic right now, so not including client logic here, it's sufficient to implement drift detection, and the action to fix the drift would be to disable and to re-enable certificates via some command-line parameter of CLI.
