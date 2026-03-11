# Simplex.Messaging.Transport.Server

> TLS server: socket lifecycle, client acceptance, SNI credential switching, socket leak detection.

**Source**: [`Transport/Server.hs`](../../../../../src/Simplex/Messaging/Transport/Server.hs)

## safeAccept — errno-based retry

`safeAccept` retries `accept()` on specific errno values. The code comment references the POSIX man page: "man accept says: For reliable operation the application should detect the network errors defined for the protocol after accept() and treat them like EAGAIN by retrying." The retry set: `eCONNABORTED, eAGAIN, eNETDOWN, ePROTO, eNOPROTOOPT, eHOSTDOWN, eNONET, eHOSTUNREACH, eOPNOTSUPP, eNETUNREACH`. Any other error is logged and re-thrown.

## SocketState — leak detection

`SocketState = (TVar Int, TVar Int, TVar (IntMap (Weak ThreadId)))` tracks: accepted count, gracefully-closed count, and active client threads. `getSocketStats` computes `socketsLeaked = socketsAccepted - socketsClosed - socketsActive`.

## closeServer — weak thread references

`closeServer` kills active client threads via `Weak ThreadId`. The code: `readTVarIO clients >>= mapM_ (deRefWeak >=> mapM_ killThread)`. `deRefWeak` returns `Nothing` if the thread has already been garbage collected, so the shutdown does not fail on already-dead threads.

## SNI credential switching

`supportedTLSServerParams` selects TLS credentials based on SNI:
- **No SNI**: uses `credential` (the primary server credential)
- **SNI present**: uses `sniCredential` (when configured)

The `sniCredUsed` TVar records whether SNI triggered credential switching. In the SMP server (Server.hs), when `sniUsed` is `True`, the connection is dispatched to the HTTP handler instead of the SMP handler.

## startTCPServer — address resolution

`startTCPServer` resolves the listen address and selects `AF_INET6` first, falling back to `AF_INET`: `select as = fromJust $ family AF_INET6 <|> family AF_INET`.

## Client certificate validation for services

`paramsAskClientCert` enables TLS client certificate requests. In `validateClientCertificate`, an empty chain (`CCEmpty`) returns no error — client certificates are optional, as noted by the code comment: "client certificates are only used for services."
