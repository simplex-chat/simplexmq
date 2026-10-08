# Fast rotation: draining the old receive queue

Recipient only. The sender is unchanged.

## Decisions

- New `RcvSwitchStatus` value:

  | constructor      | encoding        |
  |------------------|-----------------|
  | `RSReceivedQEND` | `received_qend` |

  - Stored in `rcv_queues.switch_status`.
  - `canAbortRcvSwitch` returns `False` for it.
- `qEndMsg`, by the queue that delivered `QEND`:
  - the queue named in `QEND`: the named queue is marked deleted, `ICDeleteRcvQueue` is enqueued.
  - the new queue: the named queue is set to `RSReceivedQEND` and stays subscribed.
  - `NSCCreate` and `SWITCH QDRcv SPCompleted`: sent when the named queue had no `RSReceivedQEND`.
- Deletion of an `RSReceivedQEND` queue:
  - trigger: `OK` response to an `ACK` on that queue, without a `GET` lock on it.
  - action: the queue is marked deleted, `ICDeleteRcvQueue` is enqueued.
- Bound, a `cleanupManager` step, for each connection with an `RSReceivedQEND` queue:
  - condition: another receive queue of the connection has an active subscription.
  - `delete_errors + 1 < deleteErrorCount`: `delete_errors` is incremented.
  - otherwise: the queue is deleted as above; the first `DEL` error of `ICDeleteRcvQueue` removes it locally.
- `ackSMPMessage` result, `type QueueDrained = Bool`:
  - `OK`: `True`.
  - `MSG`: `False`; the message is written to `msgQ`.
- Apps: `received_qend` is added to `RcvSwitchStatus`.

## Mechanics

- `Agent/Protocol.hs`: `RSReceivedQEND`.
- `Agent/Store.hs`: `canAbortRcvSwitch`.
- `Client.hs`: `QueueDrained`; `ackSMPMessage` returns it.
- `Agent/Client.hs`: `sendAck` returns `QueueDrained`.
- `Agent/Store/AgentStore.hs`: `getEndedRcvQueueConnIds`:

  ```sql
  SELECT conn_id FROM rcv_queues WHERE switch_status = ? AND deleted = 0
  ```

- `Agent.hs`:
  - `deleteRcvQueueAsync`: `setRcvQueueDeleted`, then `ICDeleteRcvQueue`.
  - `qEndMsg`.
  - `ackQueueMessage`.
  - `cleanupManager`: `expireEndedRcvQueues`.
- Apps:
  - `apps/ios/SimpleXChat/APITypes.swift`
  - `apps/multiplatform/common/src/commonMain/kotlin/chat/simplex/common/model/SimpleXAPI.kt`

## Tests

- `QEND` on the new queue while a message waits on the old queue:
  - the message is delivered;
  - the old queue is deleted after the `ACK` that returns `OK`.
- The same with a recipient restart before the `ACK`.
- Old server stopped: the old queue is deleted by the bound.
