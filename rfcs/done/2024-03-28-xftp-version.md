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
XFTP client sets it to `Just ["xftp/1"]`.
The exact value is not important as long it is in agreement with the server side, but ALPN RFC insists on it being an IANA-registered identifier.

XFTP server sets `onALPNClientSuggest` TLS hook to pick the protocol when it is provided.
The `tls` library treats SHOULD from the RFC as MUST and does a client-side check that the server responded with one of the client-proposed protocols.

Upon connection, transport implementation invokes `getNegotiatedProtocol` and stores it in `tlsALPN :: Maybe ALPN` field of transport context.
HTTP2 transport implementation using `withHTTP2` passes negotiated "protocol" to client and server setup callbacks where they store it in their respective wrappers along with TLS session ID.
A server request handler then knows by looking at the `sessionALPN` if it should require a "handshake" request first.
A client code that got HTTP2Client with `sessionALPN` set knows if it has to proceed with handshake request.
A handshake request still has to be initiated by a client, so it should be kept minimal, just enough data to pass the initiative to a server.
A reply to that initial request should contain a server version range for the client to pick.
A client then commits to a version, sending its part of a handshake.

In the future ALPN negotiation can be dropped in favor of mandatory handshakes or used to signal further handshake schemes.

The XFTP handshake data types and validation code are cloned from SMP.
Currently they carry version information and session authentication parameters.
Authentication parameters made mandatory as this exchange is guarded by the handshake version.

### Server side

`runHTTP2Server` callback used by `xftpServer` should get access to the session state to track handshakes.
A local `TMap SessionId Handshake` is enough to switch request handlers.
The HTTP2 server framework is extended with a way to signal client disconnection to remove sessions from this map.

The `Handshake` type mimics implicit state in stream based handshakes of SMP and NTF.

```haskell
data Handshake
  = HandshakeSent C.PrivateKeyX25519 -- server private key that will be merged with client public in `THandleAuth`
  | HandshakeAccepted THandleAuth VersionXFTP -- session steady state after handshakes
```

An HTTP2 request without ALPN is treated as legacy and requires no session entry.
Its `Request`s are marked with `THandleParams {thVersion = VersionXFTP 1, ..}`.

An HTTP2 request with ALPN requires a session lookup.
- A lack of entry indicates that a client must send an empty request, to which the server replies with its "server handshake" block and stores its private state in `HandshakeSent`.
- If the session entry contains `HandshakeSent`, then the only valid request content is the "client handshake" block.
  The server validates client handshake (in the same way as SMP) and stores authentication and version in `HandshakeAccepted`
- If the session entry contains `HandshakeAccepted`, then the server just passes it to `THandleParams`.

### Client side

`getXFTPClient` tweaks its transport config to include the ALPN marker and then checks if the client got its `sessionALPN` value.
If there's a value set, it then sends an initial block and checks out the server handshake in response.
After validation, it sends "client handshake" request to finish version negotiation.

```haskell
let tcConfig = (transportClientConfig xftpNetworkConfig) {alpn = Just ["xftp/1"]}
-- ...
http2Client <- liftEitherError xftpClientError $ getVerifiedHTTP2Client -- ...
thVersion <- case sessionALPN http2Client of
  Nothing -> pure $ VersionXFTP 1
  Just proto -> negotiate http2Client proto
```

The resulting `XFTPClient` then contains a negotiated version and can be used to send transmissions with a more recent encoding.

## Block encoding

### Client Hello (request)

A request with an empty body and no padding.

### Server handshake (response)

SMP-encoded and padded to `xftpBlockSize` (~16kb).

```haskell
data XFTPServerHandshake = XFTPServerHandshake
  { xftpVersionRange :: VersionRangeXFTP,
    sessionId :: SessionId, -- validated by client against TLS unique
    authPubKey ::
      ( X.CertificateChain, -- fingerprint validated by client against pre-shared hash
        X.SignedExact X.PubKey -- signature validated by client against server key from TLS
      )
  }
```

### Client handshake (request)

SMP-encoded and padded to `xftpBlockSize` (~16kb).

```haskell
data XFTPClientHandshake = XFTPClientHandshake
  { xftpVersion :: VersionXFTP,
    keyHash :: C.KeyHash, -- validated by server against its own cert fingerprint
    authPubKey :: C.PublicKeyX25519
  }
```

### Server confirmation (response)

A response with an empty body and no padding.
