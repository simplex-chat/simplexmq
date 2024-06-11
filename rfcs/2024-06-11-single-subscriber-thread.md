# Single subscriber thread

## Problem

Subscribing to a queue with `subscribeQueue` or `acknowledgeMsg` without a message to deliver will result in a new thread.
A well-connected user can have hundreds of connections on each server in their lists (with some users having multiple thousands per server).
Each thread will block on an empty message queue then attempt to write to client's message queue (blocking if the socket is being slow or about to disconnect).
While Haskell threads are lightweight, they still use some resources for stack, thread state, STM state etc.
Hundreds of thousands of such threads thus consume GBs of memory just to decouple message senders from recipients.

## Solution

It is possible to use a single subscriber thread that will wait for messages on all the subscribed queues using an explicit structure that would signal "read this queue now, it has a message".

Now:

```haskell
data Client = Client
  { clientId :: ClientId,
    subscriptions :: TMap RecipientId (TVar Sub), -- Sub may contain SubThread related to the forked subscriber for that queue.
```

Proposed:

```haskell
data Client = Client
  { clientId :: ClientId,
    subscriptions :: TMap RecipientId (TVar Sub), -- all client subscriptions
    deliveries :: TVar Deliveries, -- subscriptions with a pending message, details below
    subscriber :: TMVar (Maybe (Weak ThreadId)), -- a singleton thread waiting for non-empty deliveries
  -- ...
```

When `sendMessage` inserts a new message (i.e. not getting QUOTA), it can mark the queue as having a new message, so the `subscriber` thread would know that it can read the queue without being blocked on reading.
Triggering such async delivery must be guarded by the same preconditions as the original `forkSub`: the queue has an active subscriber (no GETs were called on it) and all the previous messages had been ACKd.
The preconditions are tracked by the `Sub` state object and async deliveries are only possible in the `SubThread` state which is entered in `forkSub` from the `NoSub` state (i.e. ruling out `SubProhibited` set and kept by `getMessage`).
Additionally, the sender must avoid overwriting the deliveries posted before.

The subscriber waits on a delivery object, which is a priority search queue:

```haskell
type Deliveries = HashPSQ RecipientId SystemTime (QueueRec, TVar Sub, Message)
```

- Unlike the simplest possible collection `Set RecipientId` it is biased to older messages instead of queues with lower IDs.
- Unlike `Map RecipientId (...)` it has the `minView` procedure to split the collection into the oldest element and the rest.
- Unlike `[(QueueRec, TVar Sub, Message)]`, it allows preventing overwrites without inspecting each element.
- Unlike `TMVar` or `TBQueue` it wouldn't block the sender.
- Unlike `TQueue` it only grows up to the number of subscriptions instead of unbounded number of messages to deliver for all the queues.

The values are not strictly required (the `HashPSQ RecipientId SystemTime ()` would suffice), but they're are already used in the `sendMessage` code and attaching them to `RecipientId` obviates the subscriber from issuing a series of transactions to get the data for producing a transmission.
In the happy world of infinite queues and irrelevant latency, the sender could be using those to send transmissions directly. Now this "work item" gets delegated to the subscriber.

So, the subscriber reads the `deliveries` TVar and checks if it has some message to deliver.
The rest of the PSQ get written back and the delivery proceeds as before: write the message out, store it in the `Sub`, and drop the sub state to `NoSub`, preventing further deliveries until ACK.
If the client message queue is full for some reason, the subscriber blocks there and new delivery tasks start to pile up.
Having only one thread waiting to write avoids contention and thrashing when a message leaves the queue, saving some CPU as a bonus.
