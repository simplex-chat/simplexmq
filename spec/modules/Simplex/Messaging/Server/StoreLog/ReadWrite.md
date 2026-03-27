# Simplex.Messaging.Server.StoreLog.ReadWrite

> Store log replay (read) and snapshot (write) for STM queue store.

**Source**: [`ReadWrite.hs`](../../../../../../src/Simplex/Messaging/Server/StoreLog/ReadWrite.hs)

## readQueueStore — error-tolerant replay

Log replay (`readQueueStore`) processes each line independently. Parse errors are printed to stdout and skipped. Operation errors (e.g., queue not found during `SecureQueue` replay) are logged and skipped. A deleted queue encountered during replay (`queueRec` is `Nothing`) logs a warning but does not fail. This means a corrupted log line only loses that single operation, not the entire store.

## NewService ID validation

During replay, `getCreateService` may return a different `serviceId` than the one stored in the log (if the service cert already exists with a different ID). This is logged as an error but does not abort replay — the store continues with the ID it assigned. This handles the case where a store log was manually edited or partially corrupted.

## writeQueueStore — services before queues

`writeQueueStore` writes services first, then queues. Order matters: when the log is replayed, service IDs must already exist before queues reference them via `rcvServiceId`/`ntfServiceId`.
