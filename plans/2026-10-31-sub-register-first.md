# Subscriber registration before the first-message read

## Decisions

- SUB from a client without a service certificate to an active queue not associated with a service: the subscriber is registered in the client thread, before the first message of the queue is read.
- NEW with subscription from such a client: the subscriber is registered in the client thread.
- The registration is `processClientSub`, the code of `serverThread` for one subscription change, called under `mask_`.
- The SUB response includes the first message only when no message of the subscription is marked as delivered.
- Other subscription changes are registered by `serverThread` from `subQ`, as before.

## Before

```mermaid
sequenceDiagram
    participant R as Recipient agent
    participant C as Client thread of R
    participant Q as Message store
    participant T as serverThread
    participant S as Client thread of sender
    R->>C: SUB q
    Note over C: signature verified in receive
    C->>Q: prepareBatchSubs: tryPeekMsgs q
    Q-->>C: empty queue
    S->>Q: SEND m: writeMsg, the queue was empty
    S->>S: tryDeliverMessage: subscriber of q not found
    C->>C: subscribeQueueAndDeliver: Sub of q inserted
    C->>T: CSClient q written to subQ
    C-->>R: SOK
    T->>T: updateSubscribers: R registered in queueSubscribers, END to the previous subscriber
    Note over R,Q: m is returned to R in the response to the next SUB
```

## After

```mermaid
sequenceDiagram
    participant R as Recipient agent
    participant C as Client thread of R
    participant Q as Message store
    participant S as Client thread of sender
    R->>C: SUB q
    Note over C: signature verified in receive
    C->>C: prepareBatchSubs: Sub of q inserted
    C->>C: processClientSub under mask_: R registered in queueSubscribers, END to the previous subscriber
    alt m written after the registration, before the read
        S->>Q: SEND m: writeMsg, the queue was empty
        S->>S: tryDeliverMessage: R found, no message marked as delivered
        S-->>R: MSG m, m marked as delivered
        C->>Q: tryPeekMsgs q
        Q-->>C: m
        C->>C: trySetDelivered: m already marked
        C-->>R: SOK
    else m written after the read
        C->>Q: tryPeekMsgs q
        Q-->>C: empty queue
        C-->>R: SOK
        S->>Q: SEND m: writeMsg, the queue was empty
        S->>S: tryDeliverMessage: R found
        S-->>R: MSG m
    end
    Note over R,C: m written before the registration is returned with SOK, as before
```

## Mechanics

- `Server.hs`:
  - `processClientSub`: the per-change code of `serverThread`, beside it in `smpServer`; `serverThread` calls it for each `subQ` entry.
  - `runClient`, `runClientTransport`, `client`: `processClientSub` for message subscribers passed to the client thread.
  - `prepareBatchSubs`: selected SUBs inserted with `TM.lookupOrInsertIO`; `processClientSub` for each inserted subscription, before `tryPeekMsgs`; the inserted subscriptions returned as the fourth map of the batch result.
  - `subscribeQueueAndDeliver`: an inserted subscription passed to `deliver` as new.
  - `subscribeNewQueue`: `processClientSub` for a client without a service certificate.
  - `deliver`, `trySetDelivered`: the first message marked as delivered and included only when no message is marked.
- `tests/ServerTests.hs`: `SUB and SEND in one block`.
