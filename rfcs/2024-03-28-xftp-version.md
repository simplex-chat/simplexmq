# XFTP version agreement

## Problem

XFTP is using HTTP2 protocol for encoding requests and responses.
Unlike SMP which has a connection handshake initiated by a server and signals available versions XFTP/HTTP2 is almost entirely client-driven.
So, a client can only try to guess which protocol versions are supported by a server by sending a probe/hello request first.
Determining the endpoint for such a request is an implicit version agreement by itself.
Sending such a request to an old server would error out and requiring it from old clients would break them.

## Solution

The TLS layer used by the XFTP server has an optional [ALPN](https://datatracker.ietf.org/doc/html/rfc7301) extension which allows the client and server to negotiate protocols and store the decision in TLS session context.
Unless a client and a server run ALPN-aware versions, they would default to the old "unversioned" protocol.

TLS extension content is a 65kb chunk, but ALPN standard breaks it into 254b-sized chunks making it unusable for things like key exchange.
The exchange is still client-driven: the client proposes a list, and then a server callback picks one.
In effect, this makes it usable only to signal that some application-level handshake is desired and supported.

## Implementation

ALPN can be used to negotiate for any TLS-based protocol, but the description will focus on XFTP.

TransportClientConfig gets a new `alpn :: Maybe [ALPN]` field so a TLS transport can use it during TLS client creation.
XFTP client sets it to `Just ["xftp/1.1"]`.
The exact value is not important as long it is in agreement with the server side, but ALPN RFC insists on it being an IANA-registered identifier.

XFTP server sets `onALPNClientSuggest` TLS hook to pick the protocol when it is provided.

Upon connection, transport implementation invokes `getNegotiatedProtocol` and stores it in `tlsALPN :: Maybe ALPN` field of transport context.
HTTP2 transport implementation using `withHTTP2` passes negotiated "protocol" to client and server setup callbacks where they store it in their respective wrappers along with TLS session ID.
A server request handler then knows by looking at the `sessionALPN` if it should require a "handshake" request first.
A client code that got HTTP2Client with `sessionALPN` set knows if it has to proceed with handshake request.
A handshake request still has to be initiated by a client, so it should be kept minimal, just enough data to pass the initiative to a server.
A reply to that initial request should contain a server version range for the client to pick.
A client then commits to a version, sending its part of a handshake.

In the future ALPN negotiation can be dropped in favor of mandatory handshakes or used to signal further handshake schemes.

### Server side

`runHTTP2Server` callback used by `xftpServer` should get access to the session state to track handshakes.
A local `TMap SessionId Handshake` is enough to switch request handlers.

```haskell
data Handshake = HandshakeSent | HandshakeAccepted VersionXFTP
```

An HTTP2 request without ALPN is treated as legacy and requires no session entry.
Its `Request`s are marked with `THandleParams {thVersion = VersionXFTP 1, ..}`.

An HTTP2 request with ALPN requires a session lookup.
A lack of entry indicates that a client must send a "hello" block, to which the server replies with its "server handshake" block and marks the session with `HandshakeSent`.
If the session entry contains `HandshakeSent`, then the only valid request content is the "client handshake" block containing the client-chosen version.
The server sets the session version and `THandleParams {thVersion}` contains the negotiated version.
If the session entry contains `HandshakeAccepted`, then the server just passes it to `THandleParams`.

### Client side

`getXFTPClient` tweaks its transport config to include the ALPN marker and then checks if the client got its `sessionALPN` value.
If there's a value set, it then sends an initial block and checks out the server handshake in response.
After that, it sends "client handshake" request to finish version negotiation.

```haskell
let tcConfig = (transportClientConfig xftpNetworkConfig) {alpn = Just ["xftp/1.1"]}
-- ...
http2Client <- liftEitherError xftpClientError $ getVerifiedHTTP2Client -- ...
thVersion <- case sessionALPN http2Client of
  Nothing -> pure $ VersionXFTP 1
  Just proto -> negotiate http2Client proto
```

The resulting `XFTPClient` then contains a negotiated version and can be used to send transmissions with a more recent encoding.

## Block encoding

TBD

### Client Hello (request)

Can be added to existing v1 `FileCommand`, like `PING`, for transmission to be indistinguishable from other v1 commands (XXX: marked for which party?).
However, using ALPN is already giving up this information unless e.g. `xftp/1.0` is set to be a valid negotiated version for the current (v1) protocol.

### Server handshake (response)

- Should contain server version range.
- Can contain things like PQ initiation params.

### Client handshake (request)

- Should contain exact XFTPVersion.
- Can contain things like PQ initiation params.
