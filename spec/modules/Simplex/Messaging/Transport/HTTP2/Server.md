# Simplex.Messaging.Transport.HTTP2.Server

> HTTP/2 server with inactive client expiration. The single-queue server is for testing only.

**Source**: [`Transport/HTTP2/Server.hs`](../../../../../../src/Simplex/Messaging/Transport/HTTP2/Server.hs)

## Inactive client expiration

`runHTTP2ServerWith_` tracks last activity per client via a `TVar SystemTime`. A background thread (`expireInactiveClient`) periodically checks whether the client has been inactive beyond the `ExpirationConfig` threshold. If so, it calls `closeConnection tls`.

The activity timestamp is updated on every HTTP/2 request (before dispatching to the handler).

## getHTTP2Server — testing only

The source comment states: "This server is for testing only, it processes all requests in a single queue." `getHTTP2Server` puts all requests on a single `TBQueue`. `runHTTP2Server` dispatches requests directly via `H.run` without queueing.
