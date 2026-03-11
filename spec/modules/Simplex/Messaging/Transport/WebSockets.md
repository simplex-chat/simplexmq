# Simplex.Messaging.Transport.WebSockets

> WebSocket transport implementation over TLS, with strict message framing.

**Source**: [`Transport/WebSockets.hs`](../../../../../src/Simplex/Messaging/Transport/WebSockets.hs)

## cGet — strict size check (unlike TLS)

`cGet` throws `TEBadBlock` if the received WebSocket message length doesn't equal `n`. This differs from the TLS `cGet` which uses `getBuffered` to accumulate partial reads.

## WebSocket options

- `connectionCompressionOptions = NoCompression`
- `connectionFramePayloadSizeLimit = SizeLimit $ fromIntegral smpBlockSize` (16384)
- `connectionMessageDataSizeLimit = SizeLimit 65536`
