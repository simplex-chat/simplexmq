# Subscription changes processed in the client thread

## Decisions

- Each subscription change is processed by `processClientSub` under `uninterruptibleMask_`, in the client thread of the command.
- `serverThread` and `subQ` are removed.
- The branch for a disconnected client is removed from `processClientSub`.
- SUB, from clients with and without a service certificate: the subscriber is registered in `prepareBatchSubs`, after the queue associations and before `tryPeekMsgs`.
- Duplicate SUB: `delivered` of the subscription is reset in `prepareBatchSubs`, before `tryPeekMsgs`.
- SUB of a blocked queue, or of a queue with a failed association: the subscriber is registered only by a later successful SUB.
- The first message of a subscription is marked as delivered once, and it is sent only where it is marked:
  - in the MSG pushed after SEND
  - in the SUB response
  - in the MSG sent by `deliverServiceMessages` after SUBS
- `qSub` is counted for a new subscription when `tryPeekMsgs` returns a message, except for two SUBs of one queue in one block.
- The service counts of a previous service subscriber are decreased for one queue only while it is registered for the service.
- Changes of these commands are processed while the command is processed:
  - SUBS
  - NSUB
  - NSUBS
  - NEW with subscription
  - NKEY
  - NDEL
  - DEL

## Composition

Processing of one subscription change. Green: added by this change. Red: removed by it.

```mermaid
flowchart LR
    C[Client thread of a connection]
    Q[subQ]
    T[serverThread]
    X[Server clients]
    P[processClientSub]
    U[updateSubscribers<br>one STM transaction]
    V[endPreviousSubscriptions<br>later STM transactions]
    R[queueSubscribers<br>serviceSubscribers<br>totalServiceSubs<br>subClients<br>maps and counts of clients]
    E[pendingEvents]
    S[sendPendingEvtsThread]
    C -- "removed - change written" --> Q
    Q -- "removed - change read" --> T
    T -- "removed - client read by getServerClient<br>connected checked" --> X
    T -- "removed - run" --> U
    T -- "removed - run" --> V
    C -- "added - call under uninterruptibleMask_" --> P
    P -- "added - run" --> U
    P -- "added - run" --> V
    U -- "registration<br>entries of the previous subscribers removed or replaced<br>count of the previous service connection swapped to 0" --> R
    V -- "previous subscriptions removed from client maps<br>counts decreased<br>delivery threads stopped" --> R
    V -- "END<br>ENDS<br>DELD" --> E
    E -- "events read" --> S
    classDef removed fill:#f4cccc,stroke:#cc0000
    classDef added fill:#d9ead3,stroke:#008800
    class Q,T removed
    class P added
    linkStyle 0,1,2,3,4 stroke:#cc0000
    linkStyle 5,6,7 stroke:#008800
```

## Sequence

SUB of an empty queue and a SEND to it right after `tryPeekMsgs`. Green: added by this change. Red: removed by it.

```mermaid
sequenceDiagram
    participant R as Recipient agent
    participant C as Client thread of R
    participant Q as Message store
    participant T as serverThread, removed
    participant S as Client thread of sender
    R->>C: SUB q, signature verified in receive
    rect rgba(0, 160, 0, 0.18)
        C->>C: added - prepareBatchSubs, subscribeQueue: Sub of q inserted
        C->>C: added - updateSubscribers under uninterruptibleMask_: R registered in queueSubscribers
        C->>C: added - endPreviousSubscriptions: END queued for the previous subscriber
    end
    C->>Q: prepareBatchSubs: tryPeekMsgs q
    Q-->>C: empty queue
    S->>Q: SEND m: writeMsg, the queue was empty
    rect rgba(220, 0, 0, 0.18)
        S->>S: removed - tryDeliverMessage: R not found, m not pushed to R
    end
    rect rgba(0, 160, 0, 0.18)
        S-->>R: added - tryDeliverMessage: R found, MSG m pushed and marked as delivered
    end
    rect rgba(220, 0, 0, 0.18)
        C->>C: removed - subscribeQueueAndDeliver: Sub of q inserted
        C->>T: removed - CSClient q written to subQ
        T->>T: removed - updateSubscribers: R registered in queueSubscribers
        T->>T: removed - endPreviousSubscriptions: END queued for the previous subscriber
    end
    C-->>R: SOK
    rect rgba(220, 0, 0, 0.18)
        Note over R,Q: removed - m returned to R only in the response to the next SUB
    end
    rect rgba(0, 160, 0, 0.18)
        Note over R,Q: added - when m is written after the registration and before tryPeekMsgs, m is returned by tryPeekMsgs, and m is sent once, pushed or in the SUB response, where it is marked as delivered first
    end
```

## Service counts

A SUB by which the association of queue q with service S is removed, and SUBS from a new connection N of S. O is the previous connection of S.

```mermaid
sequenceDiagram
    participant D as Client thread of the SUB
    participant N as Client thread of N
    participant G as Registries
    D->>G: updateSubscribers: O recorded for CSAEndServiceSub S q
    N->>G: updateSubscribers: N registered for S, the count of O swapped to 0
    N->>G: endPreviousSubscriptions: the swapped count subtracted from totalServiceSubs
    D->>G: endServiceQueueSub: O not registered for S, counts unchanged
```

## Mechanics

- `Server.hs`:
  - `processClientSub`: top level; the registration code of `serverThread`, for the client of the calling thread, under `uninterruptibleMask_`.
  - `CSAEndServiceSub`: the service ID added.
  - `endServiceQueueSub`: the counts decreased only while the previous client is registered for the service.
  - `smpServer`: `serverThread` removed.
  - `client`: `processSub` and `processNtfSub` are `processClientSub` for message and notification subscribers.
  - `prepareBatchSubs`: one `runExceptT` block:
    - queue associations
    - `subscribeQueue` for each SUB of a queue that is not blocked and has no failed association
    - `tryPeekMsgs`
    - the `subscribeQueue` results returned as the fourth map of the batch result
  - `subscribeQueue`: the first part of the former `subscribeQueueAndDeliver`.
  - `deliverSubMsg`: the second part of the former `subscribeQueueAndDeliver`; the `subscribeQueue` result passed to `deliver`.
  - `sharedSubscribeQueue`: moved from `processCommand` to `client`; `processSub` or `processNtfSub` passed in place of the server subscribers.
  - `processSub` or `processNtfSub` in place of the entry written to `subQ`:
    - `sharedSubscribeService`
    - `subscribeNewQueue`
    - `addQueueNotifier_`
    - `deleteQueueNotifier_`
    - `delQueueAndMsgs`
  - `deliver`: `qSub` counted before `trySetDelivered`; the first message included only when it is marked by `trySetDelivered`.
  - `deliverServiceMessages`: MSG sent only when the message is marked by `trySetDelivered`.
- `Env/STM.hs`: `subQ` removed from `ServerSubscribers`.
- `tests/ServerTests.hs`:
  - `should deliver message sent in the same block as SUB`
  - `should deliver message once for two SUBs in the same block`
  - `should deliver message sent in the same block as service SUB`
  - `should deliver message after SUB while delivery waits for full send queue`: the message recorded before or after SOK.
