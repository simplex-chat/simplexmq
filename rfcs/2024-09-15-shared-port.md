# Sharing protocol ports with HTTPS

Some networks block all ports other than web ports, including port 5223 used for SMP protocol by default. Running SMP servers on a common web port 443 would allow them to work on more networks. The servers would need to provide an HTTPS page for browsers (and probes).

## Problem

Browsers and tools rely on system CA bundles instead of certificate pinning.
The crypto parameters used by HTTPS are different from what the protocols use.
Public certificate providers like LetsEncrypt can only sign specific types of keys and Ed25519 isn't one of them.

This means a server should distinguish browser and protocol clients and adjust its behavior to match.

## Solution

`tls` package has a server hook that allows producing a different set of `TLS.Credentials` according to a client-provided "Server Name Indication" extension.

Since LE certificates are only handed out to domain names, TLS client will be sending the SNI.
However client transports are constructed over connected sockets and the SNI wouldn't be present unless explicitly requested.
When a client sends SNI, then it's a browser and a web credentials should be used.
Otherwise it's a protocol client to be offered the self-signed ca, cert and key.

When a transport colocated with a HTTPS, its ALPN list should be extended with `h2 http/1.1`.
The browsers will send it, and it should be checked before running transport client.
If HTTP ALPN is detected, then the client connection is served with HTTP `Application` instead (the same "server information" page).

If some client connects to server IP, doesn't send SNI and doesn't send ALPN, it will look like a pre-handshake client.
In that case a server will send its handshake first.
This can be mitigated by delaying its handshake and letting the probe to issue its HTTP request.

## Implementation plan

An unmodified client should be able to use protocols on port 443 right away.

The switchover happens inside `runTransportServerState` before `runClient`:

```haskell
runServer (tcpPort, ATransport t) = do
  -- ...
  runTransportServerState_ ss started tcpPort serverParams tCfg $ \socket h -> do -- expose raw socket for warp-tls internals to attach
    negotiated <- getSessionALPN
    if allowHTTP t && isHTTP negotiated -- only attempt the switch for the TLS transport
      then runHTTP socket (tlsContext h)-- ... collect data and produce values needed to run WAI Application
      else runClient serverSignKey t h `runReaderT` env -- performs serverHandshake etc as usual
```

The web app and server live outside, so `runHttp` has to be provided by the `runSMPServer` caller.
Additonally, Warp is using its `InternalInfo` object that's scoped to `withII` bracket.

```haskell
  runServer ini = do
    -- ...

    runWebServer ini ServerInformation {config, information} $ if sharedHttps then Nothing else webHttpsParams -- suppress serving https
    if sharedHttps
      then withRunHTTP staticFilesPath \attachStatic -> runSMPServer cfg (Just attachStatic) -- provide wrapped application runner
      else runSMPServer cfg Nothing
```

### Upstream

The implementation relies on a few modification to upstream code:
- `warp-tls`: The library provides `httpOverTls`, but it wants to do handshake itself.
  Since we have to do the handshake to switch on ALPN, the setup function has to be split.
  This is a resonable change that may be upstreamed and nothing blocks us from using the recent version.
- `warp`: Only the re-export of `serveConnection` is needed.
  Unfortunately the most recent `warp` version can't be used right away due to dependency cascade around `http-5` and `auto-update-2`.
  So a fork containing the backported re-export has to be used until the dependencies are refreshed.


### TLS.ServerParams

When a server has port sharing enabled, a new set of TLS params is loaded and combined with transport params:

```haskell
newEnv config = do
  -- ...
  tlsServerParams <- loadTLSServerParams caCertificateFile certificateFile privateKeyFile (alpn transportConfig)
  sharedServerParams <- forM ((,) <$> sharedHttpsCredentials config <*> alpn transportConfig) $ \((chain, key), alpn) ->
    let ca = Nothing -- It is possible to provide CA certificate, but it is typical for web server to use combined certificate chains
    loadHTTPSServerParams tlsServerParams ca chain key alpn
```

`loadHTTPSServerParams` extends params with:
1. `onALPNClientSuggest` hook gets `["h2", "http/1.1"]` added to the ALPN list which is now required.
2. `onServerNameIndication` hook added, which upon detecting client SNI prepends the web credentials.
3. `sharedCredentials = T.Credentials []` should be done to prevent transport credentials confusing browsers.
    But that aborts key exchange somewhere in tls internals, so disabled for now.
    As a workaround, another set of dummy credentials can be provided in the hope that any sane browser would reject them.
    Like, RC4 ciphers, "impossible" digest combination, etc.

### supportedParameters

TLS certificate chains provided by LetsEncrypt use ECDSA/P256 and that requires extending `supportedParameters` with things disabled in transports:

```haskell
    browserCiphers =
      [ TE.cipher_TLS13_AES128CCM8_SHA256
      , TE.cipher_ECDHE_ECDSA_AES128CCM8_SHA256
      , TE.cipher_ECDHE_ECDSA_AES256CCM8_SHA256
      ]
    browserGroups =
      [ T.P256
      ]
    browserSigs =
      [ (T.HashSHA256, T.SignatureECDSA),
        (T.HashSHA384, T.SignatureECDSA)
      ]
```

This may not be enough for other certificate providers.

## Configuration

> XXX: This is for the current implementation and should be updated.

Web certificate chain is picked up from the WEB section:

```ini
[TRANSPORT]
port: 443

[WEB]
https: 443
cert: /etc/opt/simplex/web.cert
key: /etc/opt/simplex/web.key

# Alternatively, with a proper access configuration, the paths can point to the LE creds directly:
# cert: /etc/letsencrypt/live/smp.hostname.tld/fullchain.pem
# key: /etc/letsencrypt/live/smp.hostname.tld/privkey.pem
```

When `TRANSPORT.port` matches `WEB.https` the transport server becomes shared.

Perhaps a more desirable option would be explicit configuration resulting in additional transported to run:

```ini
[TRANSPORT]
port: 5223 ; pure protocol transport
# control_port: 5224
shared_port: 443 ; variant 1: register in TRANSPORT

[WEB]
https: 443
cert: /etc/opt/simplex/web.cert
key: /etc/opt/simplex/web.key
# transport: on ; variant 2:
```

## Caveats

Serving static files and the protocols togother may pose a problem for those who currently use dedicated web servers as they should switch to embedded http handlers.

As before, using embedded HTTP server is increasing attack surface.

Users who want to run everything on a single host will have to add and extra IP address and bind servers to specific IPs instead of 0.0.0.0.
An amalgamated server binary can be provided that would contain both SMP and XFTP servers, where transport will dispatch connections by handshake ALPN.

## Alternative: Use transports routable with reverse-proxies

An "industrial" reverse proxy may do the ALPN routing, serving HTTP by itself and delegating `smp` and `xftp` to protocol servers.
Same with the `websockets`.

Since this in effect does TLS termination, the protocol servers will have to rely on credentials from protocol handshakes.
