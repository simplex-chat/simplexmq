# Subscriber registration before the first-message read

## Decisions

- SUB from a client without a service certificate to an active queue not associated with a service: the subscriber is registered in the client thread, before the first message of the queue is read.
- NEW with subscription from such a client: the subscriber is registered in the client thread.
- The registration is `processClientSub`, the code of `serverThread` for one subscription change, called under `mask_`.
- The SUB response includes the first message only when no message of the subscription is marked as delivered.
- Other subscription changes are registered by `serverThread` from `subQ`, as before.

## Sequence

SUB of an empty queue and a SEND to it right after the first-message read. Green: added by this change. Red: removed by it.

```mermaid
sequenceDiagram
    participant R as Recipient agent
    participant C as Client thread of R
    participant Q as Message store
    participant T as serverThread
    participant S as Client thread of sender
    R->>C: SUB q, signature verified in receive
    rect rgba(0, 160, 0, 0.18)
        C->>C: added - prepareBatchSubs: Sub of q inserted
        C->>C: added - processClientSub under mask_: R registered in queueSubscribers, END to the previous subscriber
    end
    C->>Q: prepareBatchSubs: tryPeekMsgs q
    Q-->>C: empty queue
    S->>Q: SEND m: writeMsg, the queue was empty
    rect rgba(220, 0, 0, 0.18)
        S->>S: removed - tryDeliverMessage: subscriber of q not found, m not pushed
    end
    rect rgba(0, 160, 0, 0.18)
        S-->>R: added - tryDeliverMessage: R found, MSG m pushed and marked as delivered
    end
    rect rgba(220, 0, 0, 0.18)
        C->>C: removed - subscribeQueueAndDeliver: Sub of q inserted
        C->>T: removed - CSClient q written to subQ
        T->>T: removed - updateSubscribers: R registered in queueSubscribers, END to the previous subscriber
    end
    C-->>R: SOK
    rect rgba(220, 0, 0, 0.18)
        Note over R,Q: removed - m returned to R only in the response to the next SUB
    end
    rect rgba(0, 160, 0, 0.18)
        Note over R,Q: added - when m is written after the registration and before the read, the read returns m, and trySetDelivered omits it from SOK, as m is marked as delivered
    end
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
