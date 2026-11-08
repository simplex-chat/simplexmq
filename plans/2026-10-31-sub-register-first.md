# Subscription changes processed in the client thread

## Decisions

- Each subscription change is processed by `processClientSub` under `uninterruptibleMask_`, in the client thread of the connection.
- `serverThread` and `subQ` are removed.
- `processClientSub` takes the place of `serverThread` in `smpServer`; its branch for a disconnected client is removed.
- SUB, from clients with and without a service certificate: the subscriber is registered in `prepareBatchSubs`, after the queue associations and before `tryPeekMsgs`, except for a service client when the queue is associated with its service and the connection has a service count, as on master.
- Duplicate SUB: `delivered` of the subscription is reset in `prepareBatchSubs`, before `tryPeekMsgs`.
- SUB of a blocked queue, or of a queue with a failed association: the subscriber is registered only by a later successful SUB.
- For a new subscription, the first message is marked as delivered once, and it is sent only where it is marked, in one of these:
  - the MSG pushed after SEND
  - the SUB response
  - the MSG sent by `deliverServiceMessages` after SUBS
- After a duplicate SUB, a message pushed before `delivered` is reset is marked and sent again, as on master.
- `qSub` is counted for a new subscription when a message is returned by `tryPeekMsgs`, with these exceptions:
  - two SUBs of one queue in one block
  - an `updateQueueTime` error after the registration
- The service counts of a previous service subscriber are decreased for one queue only while it is registered for the service.
- The subscription changes of each of these commands are processed during that command, in the client thread:
  - SUBS
  - NSUB
  - NSUBS
  - NEW with subscription
  - NKEY
  - NDEL
  - DEL
- The SMP server design diagram and its README section are removed.

## Composition

Processing of one subscription change. Green: added by this pull request. Red: removed by it.

```mermaid
flowchart LR
    C[Client thread of a connection]
    Q[subQ]
    T[serverThread]
    X[Server clients]
    P[processClientSub<br>under uninterruptibleMask_]
    U[updateSubscribers<br>one STM transaction]
    V[endPreviousSubscriptions<br>later STM transactions]
    R[queueSubscribers<br>serviceSubscribers<br>totalServiceSubs<br>subClients<br>maps and counts of clients]
    E[pendingEvents]
    S[sendPendingEvtsThread]
    C -- "removed - change written" --> Q
    Q -- "removed - change read" --> T
    T -- "removed - client read by getServerClient" --> X
    T -- "removed - run" --> U
    T -- "removed - run" --> V
    C -- "added - processClientSub called" --> P
    P -- "added - run" --> U
    P -- "added - run" --> V
    U -- "client registered<br>client added to subClients<br>totalServiceSubs increased<br>entries of the previous subscribers removed or replaced<br>count of the previous service connection swapped to 0<br>client removed from subClients after a deletion without other subscriptions" --> R
    V -- "previous subscriptions removed from client maps<br>previous client removed from subClients without other subscriptions<br>counts decreased<br>delivery threads stopped" --> R
    V -- "END<br>ENDS<br>DELD" --> E
    E -- "events read" --> S
    classDef removed fill:#f4cccc,stroke:#cc0000
    classDef added fill:#d9ead3,stroke:#008800
    class Q,T removed
    class P added
    linkStyle 0,1,2,3,4 stroke:#cc0000
    linkStyle 5,6,7 stroke:#008800
```

## SUB and SEND

SUB of an empty queue and a SEND to it right after `tryPeekMsgs`. Green: added by this pull request. Red: removed by it.

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
        Note over R,Q: added - when m is written after the registration and before tryPeekMsgs, m is returned by tryPeekMsgs, marked as delivered once, after SEND or for the SUB response, and sent only where it is marked
    end
```

## Duplicate SUB

SUB of a queue that is subscribed in this connection, with message m delivered and not acknowledged. Green: added by this pull request. Red: removed by it.

```mermaid
sequenceDiagram
    participant R as Recipient agent
    participant C as Client thread of R
    participant Q as Message store
    R->>C: SUB q
    rect rgba(0, 160, 0, 0.18)
        C->>C: added - prepareBatchSubs, subscribeQueue: delivered of q reset
    end
    C->>Q: prepareBatchSubs: tryPeekMsgs q
    Q-->>C: m
    rect rgba(220, 0, 0, 0.18)
        C->>C: removed - subscribeQueueAndDeliver: delivered of q reset
        C->>C: removed - deliver: m marked by setDelivered and included in the SUB response
    end
    rect rgba(0, 160, 0, 0.18)
        C->>C: added - deliver: m included in the SUB response only when it is marked by trySetDelivered
    end
    C-->>R: SOK, MSG m
```

## Duplicate SUB and SEND

Duplicate SUB of an empty queue, with nothing marked as delivered, and a SEND of m to it before `tryPeekMsgs`. Green: added by this pull request. Red: removed by it.

```mermaid
sequenceDiagram
    participant R as Recipient agent
    participant C as Client thread of R
    participant Q as Message store
    participant S as Client thread of sender
    R->>C: SUB q
    rect rgba(0, 160, 0, 0.18)
        C->>C: added - prepareBatchSubs, subscribeQueue: delivered of q reset
    end
    S->>Q: SEND m: writeMsg, the queue was empty
    S-->>R: tryDeliverMessage: MSG m pushed and marked as delivered
    C->>Q: prepareBatchSubs: tryPeekMsgs q
    Q-->>C: m
    rect rgba(220, 0, 0, 0.18)
        C->>C: removed - subscribeQueueAndDeliver: delivered of q reset
        C-->>R: removed - SOK, MSG m again
    end
    rect rgba(0, 160, 0, 0.18)
        C-->>R: added - SOK only, as m is marked already
    end
```

## SUBS

SUBS of a service connection, and a SEND of m to an empty queue q of the service while its messages are read. Green: added by this pull request. Red: removed by it.

```mermaid
sequenceDiagram
    participant C as Client thread of the service connection
    participant T as serverThread, removed
    participant F as deliverServiceMessages
    participant S as Client thread of sender
    rect rgba(220, 0, 0, 0.18)
        C->>T: removed - CSService written to subQ, service registered by serverThread
    end
    rect rgba(0, 160, 0, 0.18)
        C->>C: added - processClientSub: service registered
    end
    C->>F: deliverServiceMessages forked
    S->>S: SEND m: writeMsg, the queue was empty
    F->>F: foldRcvServiceMessages: m of q read, Sub of q inserted
    S-->>C: tryDeliverMessage: Sub of q found, MSG m pushed and marked as delivered
    rect rgba(220, 0, 0, 0.18)
        F-->>C: removed - m marked by setDelivered, MSG m sent again
    end
    rect rgba(0, 160, 0, 0.18)
        F->>F: added - trySetDelivered: m marked already, MSG omitted, counted in rcvServicesSubDuplicate
    end
```

## Service counts

A SUB by which the association of queue q with service S is removed, and SUBS from a new connection N of S. O is the previous connection of S. Green: added by this pull request. Red: removed by it.

```mermaid
sequenceDiagram
    participant D as Client thread of the SUB
    participant N as Client thread of N
    participant G as Registries
    D->>G: updateSubscribers: O recorded for CSAEndServiceSub S q
    N->>G: updateSubscribers: N registered for S, the count of O swapped to 0
    N->>G: endPreviousSubscriptions: the swapped count subtracted from totalServiceSubs
    rect rgba(220, 0, 0, 0.18)
        D->>G: removed - endServiceQueueSub: the count of O and totalServiceSubs decreased for q again
    end
    rect rgba(0, 160, 0, 0.18)
        D->>G: added - endServiceQueueSub: O not registered for S, counts unchanged
    end
```

## Mechanics

- `Server.hs`:
  - `processClientSub`: `serverThread` in its place, for one change of the client of the calling thread, under `uninterruptibleMask_`.
  - `CSAEndServiceSub`: the service ID added.
  - `endServiceQueueSub`: the counts decreased only while the previous client is registered for the service.
  - `smpServer`: the two `serverThread` threads removed.
  - `runClient`: `processSubs`, the pair of `processClientSub` for message and notification subscribers, passed through `runClientTransport` to `client`.
  - `client`: `processSub` and `processNtfSub` from the pair.
  - `prepareBatchSubs`: one `runExceptT` block:
    - queue associations
    - `subscribeQueue` for each SUB of a queue that is not blocked, when its association is unchanged or changed successfully
    - `tryPeekMsgs`
    - the `subscribeQueue` results returned as the fourth map of the batch result
  - `subscribeQueue`: the first part of the former `subscribeQueueAndDeliver`.
  - `deliverSubMsg`: the second part of the former `subscribeQueueAndDeliver`; the `subscribeQueue` result passed to `deliver`.
  - `sharedSubscribeQueue`: moved from `processCommand` to `client`; the service ID of the client and the queue ID added as parameters; `processSub` or `processNtfSub` passed in place of the server subscribers.
  - `processSub` or `processNtfSub` called with the client and the subscription change where the change was written to `subQ`:
    - `sharedSubscribeService`
    - `subscribeNewQueue`
    - `addQueueNotifier_`
    - `deleteQueueNotifier_`
    - `delQueueAndMsgs`
  - `deliver`: `qSub` counted before `trySetDelivered`; the first message included only when it is marked by `trySetDelivered`.
  - `deliverServiceMessages`: MSG sent only when the message is marked by `trySetDelivered`.
- `Env/STM.hs`: `subQ` removed from `ServerSubscribers`.
- `README.md`: the section "SMP server design" removed.
- `design/server.gv`, `design/server.svg`: removed.
- `tests/ServerTests.hs`:
  - `should deliver message sent in the same block as SUB`
  - `should deliver message sent in the same block as SUB to the new connection`
  - `should deliver message once for two SUBs in the same block`
  - `should deliver message sent in the same block as service SUB`
  - `should deliver message after SUB while delivery waits for full send queue`: the message recorded before or after SOK.
