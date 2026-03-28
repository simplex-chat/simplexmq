# Subscription performance

No protocol changes. This is an implementation RFC addressing subscription performance bottlenecks in both the SMP router and the agent.

## Problem

Subscribing large numbers of queues is slow. A messaging client with ~300K queues per router across 3 routers takes over 1 hour to subscribe. For comparison, the NTF server with ~1M queues per router across 12 routers took 20-30 minutes (prior to NTF client services, now in master).

Even on fast networks (cloud VMs), a client with 1.1M active subscriptions needed ~1.5M attempts (commands sent) to fully subscribe - ~36% retry rate caused by the timeout cascade described below.

### Root causes

#### 1. Router: per-command processing in batches

Batch verification and queue lookups are already done efficiently for the whole batch in `Server.hs`. But `processCommand` is called per-command in a loop - each SUB does its own individual DB query for message peek/delivery. With ~135 SUBs per batch (current SMP version), that's 135 individual DB queries per batch instead of 1 batched query.

For 300K queues, that's ~2200 batches x 135 queries = ~300K individual DB queries on the router, which is the dominant bottleneck when using PostgreSQL storage.

NSUB is cheaper because it just registers for notifications without message delivery - no per-queue DB query.

#### 2. Agent: all queues read and sent at once

`getUserServerRcvQueueSubs` reads all queues for a `(userId, server)` pair in one query with no LIMIT. For 300K queues, the entire result set is loaded into memory, then all ~2200 batches are queued to send without waiting for responses.

The NTF server agent uses cursor-style reading with configurable batch sizes (900 subs per chunk, 90K per DB fetch) and waits for each chunk to be processed before fetching the next.

#### 3. No backpressure on sends

`nonBlockingWriteTBQueue` bypasses the `sndQ` bound by forking a thread when the queue is full. All batches are queued immediately, and all their response timers start simultaneously. A 30-second per-response timeout means later batches time out not because the router is slow to respond to them specifically, but because they're waiting in the router's receive queue behind thousands of earlier commands.

This causes cascading timeouts: timed-out responses trigger `resubscribeSMPSession`, which retries all pending subs. Three consecutive timeouts can trigger connection drop via the monitor thread, causing a full reconnection and retry of everything.

## Solution

### Part 1: Router - batched command processing

Move the per-command processing loop inside command handlers so that commands of the same type within a batch can be processed together.

Current flow:
```
receive batch -> verify all -> lookup queues all -> for each command: processCommand (individual DB query)
```

Proposed flow:
```
receive batch -> verify all -> lookup queues all -> group by command type -> process group:
  SUB group: one batched message peek query for all queues
  NSUB group: batch registration (already cheap, but can batch DB writes)
  other commands: process individually as before
```

For SUB, the batched processing would:
1. Collect all queue IDs from the SUB group
2. Perform a single DB query to peek messages for all queues
3. Distribute results back to individual responses

This reduces ~135 DB queries per batch to 1, cutting router-side DB load by ~100x for subscriptions.

Commands where batching doesn't matter (SEND, ACK, KEY, etc.) continue to be processed individually.

### Part 2: Agent - cursor-based subscription with backpressure

Replace the all-at-once fetch-and-send pattern with cursor-style batching, similar to what the NTF server agent does.

Changes to `subscribeUserServer`:
1. Fetch queues in fixed-size batches (e.g., configurable, default ~1000) using LIMIT/OFFSET or cursor-based pagination.
2. Send each batch and wait for responses before sending the next.
3. Remove the use of `nonBlockingWriteTBQueue` for subscription batches - use blocking writes or structured backpressure so response timers don't start until the batch is actually sent.

This ensures:
- Memory usage is bounded (not 300K queue records in memory at once)
- Response timeouts are meaningful (timer starts when the router receives the batch, not when it's queued locally)
- Retries are scoped to the failed batch, not all pending subs
- Works on slow/lossy networks by naturally pacing sends

### Part 3: Response timeout for batches

The current per-response 30-second timeout doesn't account for batch processing time. Options:

1. **Stagger deadlines**: later responses in a batch get proportionally more time. The `rcvConcurrency` field was designed for this but is never used.
2. **Per-batch timeout**: instead of timing individual responses, timeout the entire batch with a budget proportional to batch size.
3. **No timeout for subscription responses**: since subscriptions are sent as batches with backpressure (Part 2), and the connection is monitored by pings, individual response timeouts may not be needed. A subscription that doesn't get a response will be retried on reconnect.

## Priority and ordering

Part 1 (router batching) gives the biggest improvement and is independent of Parts 2/3.

Part 2 (agent cursor + backpressure) eliminates the retry cascade and is critical for slow networks.

Part 3 (timeout handling) is a refinement that can be addressed after Parts 1 and 2.
