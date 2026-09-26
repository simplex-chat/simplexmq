## Root cause: every subscription batch rebuilds the set of subscribed connections

Resubscribing a session allocates and discards a fresh `Set ConnId` covering *all* of that
session's active subscriptions, once per batch. On clients with many queues per session this
dominates both the CPU and the allocation of a reconnection, and it happens again on every
network change.

`subscribeSessQueues_` (`Agent/Client.hs`) needs to know which connections were already
subscribed, so that only newly subscribed ones are reported `UP`. It obtained that by folding
the session's whole subscription map:

```haskell
Just . S.fromList . map qConnId . M.elems <$> atomically (SS.getActiveSubs tSess $ currentSubs c)
```

`activeSubs` is keyed by `RecipientId` and holds every subscribed queue of the session, so this
walks all of them and builds a set of the same size — to answer a membership question about at
most `subsBatchSize` connections.

### Cost

`subscribeQueues` chunks the queues into batches of `subsBatchSize` (1350 by default) and calls
`subscribeSessQueues_` per batch. `activeSubs` grows as the resubscription proceeds, so batch *k*
folds roughly *k* × 1350 entries: resubscribing *N* queues in one session costs on the order of
*N²* / 2700 entry traversals, and allocates a `Set` of up to *N* elements per batch.

For a session holding 50k queues that is ~0.9M traversals per resubscription and ~37 sets of up
to 50k elements — tens of MB of short-lived allocation, repeated for each session. Under the
non-moving collector this allocation is also promotion pressure, which is what makes a
reconnection storm visible as resident memory rather than only as CPU.

Sessions are keyed `(userId, server, Nothing)` in `TSMSession` mode, so a client with many
connections concentrates its queues into few sessions and hits the worst case rather than
avoiding it.

## Fix

Maintain the connection index incrementally instead of deriving it per batch.

`SessSubs` gains `activeConns :: TMap ConnId Int` alongside `activeSubs`, and `getActiveConns`
reads it directly. `subscribeSessQueues_` then tests membership against that map.

A connection can hold more than one subscribed queue, so the index counts them rather than
storing a set: `incActiveConn` on a queue becoming active, `decActiveConn` when it stops, and the
entry is removed when its count reaches zero. That keeps "connection has at least one active
subscription" exact under partial subscription and partial failure.

It is maintained at every site that mutates `activeSubs`, and nowhere else:

| site | change |
|---|---|
| `addActiveSub'` | increments, but only when the queue was not already active |
| `batchAddActiveSubs` | increments for the queues actually added (`M.difference` against the previous map) |
| `deleteSub` | decrements for the queue if it was active |
| `batchDeleteSubs` | decrements for the removed queues that were active (`M.restrictKeys`) |
| `setSubsPending_` | clears the index with `activeSubs`, since all subscriptions become pending |

The guards matter: re-adding an already-active queue, or deleting one that was only pending,
must not move the count, otherwise the index drifts from `activeSubs` and connections are
reported `UP` twice or not at all.

## Behaviour

Unchanged. The same connections are reported `UP`, and the session-closing condition that
previously tested `S.null cs` now tests `M.null cs` over the same information.
