# Agent without waits on slow servers and full queues

## Problem

- One subscriber thread processes received messages, each under the lock of its connection.
- Worker and API threads held that lock across server requests, up to 75 seconds per attempt, so one slow server stopped the messages of all connections.
- An acknowledgement held the lock while it waited for space in msgQ, which only the subscriber drains, after it takes the same lock.
- API calls waited for space in subQ, which the app drains while it holds its own locks.

## Rules

1. A server request is never made under a connection lock; in builds with `conn_lock_checks`, used by the tests with the PostgreSQL agent store, such a request fails.
2. The second locked step reads the connection again; when its state changed, the step is dropped, postponed during ratchet synchronization, or undone.
3. A queue created on a server is recorded under the connection lock or deleted from the server; connection deletion takes the same locks.
4. API threads and lock holders never wait for space in subQ or msgQ.

## Helpers

- `requestAndCommit`: validates the connection under the lock, makes the request, validates again and commits under the lock.
- `recordNewQueue`: records a queue created on a server under the lock, or deletes it from the server.

## Sequence

```mermaid
sequenceDiagram
  participant W as Worker of connection X
  participant L as Lock of X
  participant S as Slow server
  participant Sub as Subscriber
  participant P as Protocol clients
  rect rgb(255,228,228)
  Note over W,P: Before
  W->>L: take
  W->>S: SKEY, confirmation
  Sub--xL: MSG for X waits up to 75 s
  P--xSub: MSG for Y, Z: msgQ full, writers wait
  end
  rect rgb(226,244,226)
  Note over W,P: After
  W->>L: read, validate, release
  W->>S: SKEY, confirmation, without the lock
  Sub->>L: MSG for X waits for database work only
  P->>Sub: MSG for Y, Z processed
  W->>L: read again, validate, write
  end
```

## Changes

- agent, connection locks:
  - `requestAndCommit` in ICDuplexSecure, ICQSecure, ICQSndSecure, ICQDelete and `ackMessage`;
  - `recordNewQueue` in `createRcvQueue`, `createReplyQueue` and `switchDuplexConnection`;
  - request outside the lock in ICAck, ICAckDel, ICAllowSecure, ICDeleteRcvQueue, JOIN of a service request, `setConnShortLink`, `deleteConnShortLink`, `suspendConnection`, `connectReplyQueues`;
  - `acceptContact` under the invitation lock; `serviceRequest_` without the connection lock;
  - deletion under the locks of its connections;
  - a connection whose deletion waits for delivery is not given new queues;
  - the record step of an acknowledgement reads the queue again;
  - a concurrent acknowledgement of a deleted message is dropped;
  - each switch start has an identifier; an abort removes it, a new start replaces it, and a switch whose identifier is no longer current is aborted after its queue is created;
  - the receive queue status is set to Secured under the lock, only from Confirmed;
  - ICQSecure and ICQSndSecure are postponed while the ratchet is not synchronized, resumed after synchronization;
  - SWCH is refused while the ratchet is not synchronized.
- agent, events written without waiting:
  - MSGNTF of `ackMessage`, DEL_CONNS, DEL_USER;
  - errors of `subscribeConnections`, `deleteConnections`, `subscribeAllConnections`, `deleteUser`, `xftpDeleteSndFilesRemote`;
  - the notification command of connection deletion.
- clients:
  - a message in the response to ACK, SUB or GET is written to msgQ without waiting;
  - a command waits for send-queue space only until its response timeout, and is not queued after it ends;
  - a command that ends without a response is removed, except in clients with msgQ, where it is kept for 15 minutes for a late response.
- moved to separate pull requests: the HTTP/2 request timeout, the SUSPENDED event written without waiting.
