# Simplex.Messaging.Transport.HTTP2.Client

> Thread-safe HTTP/2 client with request queuing, connection lifecycle, and timeout management.

**Source**: [`Transport/HTTP2/Client.hs`](../../../../../../src/Simplex/Messaging/Transport/HTTP2/Client.hs)

## sendRequest vs sendRequestDirect — thread safety

`sendRequest` is thread-safe: it puts the request on a `TBQueue` and waits for the response via a `TMVar`. A single background thread (`process`) dequeues and sends requests sequentially through the HTTP/2 session.

`sendRequestDirect` bypasses the queue and calls `sendReq` directly. The source comment warns: "this function should not be used until HTTP2 is thread safe, use sendRequest."

## attachHTTP2Client — runs on both client and server TLS

The source comment states: "HTTP2 client can be run on both client and server TLS connections." `attachHTTP2Client` takes a `TLS p` where `p` can be `TClient` or `TServer`, allowing an HTTP/2 client session to run on an existing server-side TLS connection.

## Connection timeout and async lifecycle

`getVerifiedHTTP2ClientWith` starts the HTTP/2 session in an `async` and waits up to `connTimeout` for the session to establish (signal via `TMVar`). If the timeout fires, the async is cancelled. If the session establishes successfully, the `action` field holds the async handle — `closeHTTP2Client` cancels it with `uninterruptibleCancel`.
