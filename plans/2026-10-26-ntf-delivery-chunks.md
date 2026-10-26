# Notification delivery in bounded transactions

## Decisions

- Each client's notifiers are delivered in chunks of `ntfDeliveryChunk` notifiers, one transaction per chunk.
- Each chunk's transaction keeps today's checks and effects:
  - the client is current (`currentClient`);
  - the service is still subscribed (`withSubscribed`), for service subscribers;
  - `sndQ` is not full;
  - the chunk's notifications are taken and written as one `sndQ` element.
- Delivery to a client stops at its first failed chunk in the cycle; notifications of that chunk and of later chunks are kept for the next cycle.
- A cycle can fill `sndQ`; the client's command responses wait for free slots (`Server.hs:1202`).
- `ntfDeliveryChunk`:

  | Item | Value |
  |---|---|
  | `ServerConfig` field | `ntfDeliveryChunk` |
  | default | 1000 |
  | INI | not configurable |
  | test servers | 1000 |

- Stats per committed chunk, as today per client:
  - `ntfCount`
  - `msgNtfs`
  - `msgNtfsB`
- One log line per client per cycle at the failed chunk, as today; its count covers that chunk.

## Mechanics

- `Server/Env/STM.hs`: `ntfDeliveryChunk :: Int` in `ServerConfig`.
- `Server/Main.hs`: `ntfDeliveryChunk = 1000`.
- `Server.hs`:
  - `isRight` added to the `Data.Either` import.
  - `runDeliverNtfs`:

    ```
    deliverChunks c flush ntfs = go (toChunks (ntfDeliveryChunk cfg) ntfs)
      go [] = pure ()
      go (ch : chs) = do
        r <- tryAny (atomically $ flush (L.toList ch))
        updateNtfStats c r
        when (isRight r) (go chs)
    deliverQueueNtfs: deliverChunks c (`flushSubscribedNtfs` c) ntfs''
    deliverServiceNtfs: deliverChunks c (withSubscribed . flushSubscribedNtfs) ntfs'
    ```

  - `flushSubscribedNtfs`, `addNtfs`, `updateNtfStats`: unchanged.
- `tests/SMPClient.hs:272`: `ntfDeliveryChunk = 1000` in the test config.
- `tests/ServerTests.hs`:
  - 5 notifiers, messages sent before `NSUB`;
  - `ntfDeliveryChunk = 2` (`smpTest2Cfg`, `updateCfg`);
  - `NMSG` notifier IDs compared as a set;
  - at most 2 `NMSG` per received block;
  - a queue subscriber, and a service subscriber (`testNtfServiceClient`).
- simplex-chat `tests/ChatClient.hs:671`: `ntfDeliveryChunk = 1000`, added with the next simplexmq update.

## Benchmark

- Harness: scratch benchmark of `flushSubscribedNtfs` with concurrent `storeNtf` writers; single-transaction mode and chunked mode.
- Notifiers:
  - 5,000
  - 50,000
  - 500,000
- Writers:
  - 0
  - 4
  - 8
- Chunk:
  - single transaction: 5,000 and 50,000 notifiers; 500,000 from the earlier run
  - 100
  - 1000
- Measured:
  - time to deliver all notifiers
  - writers' throughput
  - transaction restarts
- Result stated in the implementation pull request.
