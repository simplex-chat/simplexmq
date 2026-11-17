# Web certificates reloaded when their files change

## Problem

smp-server and xftp-server read the web certificate (`[WEB] cert` and `key`) once, at start: `newEnv` (`Server/Env/STM.hs`), `newXFTPServerEnv` (`FileTransfer/Server/Env.hs`) and warp-tls in `serveStaticFiles` (`Server/Web.hs`). A renewed Let's Encrypt certificate is served only after a restart, so a server that runs longer than 60 days after the last renewal serves an expiring and then expired certificate to browsers and web clients.

## Decisions

- Scope: the web credential of smp-server and xftp-server, on both paths that serve it:
  - SNI on the protocol port (`TLSServerCredential.sniCredential`);
  - the separate HTTPS port of the static site (warp-tls in `serveStaticFiles`).
- The protocol credential (`server.crt`, `server.key`) is unchanged: it is read at start only.
- `ReloadableCredential` holds the web credential's files (`credentialFiles`) and the credential in use (`currentCredential :: TVar T.Credential`); `TLSServerCredential.sniCredential` holds it, and `onServerNameIndication` reads the `TVar` at each handshake.
- warp-tls takes the credential from `tlsServerHooks.onServerNameIndication`, which reads the same kind of `TVar`; tls tries the hook's credentials before the shared ones.
- `reloadCredential` replaces the credential in its `TVar` when the files, parsed at each interval, differ from the credential in use:
  - the files are parsed by `loadCredential`, which `loadServerCredential` also uses at start;
  - the checks below are applied only to files that differ from the credential in use, by `checkReloadedCredential`, which turns an exception from a check into a rejection;
  - `checkKeyPair`: the private key must belong to the leaf certificate; an RSA key signs a fixed message that the certificate's key verifies, and Ed25519, Ed448 and ECDSA keys on named curves are compared with the public key computed from the private key; other key types are rejected;
  - smp-server also requires the RSA key of at least 4096 bits that it requires at start (`checkHTTPSCredentials`);
  - xftp-server accepts any key type at start, and only RSA, Ed25519, Ed448 and named-curve ECDSA keys on reload;
  - a rejection is logged with its reason, and the previous credential stays in use.
- The Env types hold `httpServerCreds :: Maybe ReloadableCredential`.
- The check interval is `credentialCheckInterval`, 60 seconds by default: in `TransportServerConfig` for SNI, and in `WebHttpsParams` with the check `checkCredential` for the separate HTTPS port.
- `withCredentialReload` runs each reload thread with the listener that reads its `TVar` (`race_`), so they stop together: around the SMP listener of the port that serves HTTPS, around xftp-server's `runHTTP2Server`, and in `runHTTPSServer` for the separate port.

## Composition

Green: added. Red: removed.

```mermaid
flowchart LR
    F[web.crt, web.key]
    E[newEnv, newXFTPServerEnv<br>serveStaticFiles]
    V[TVar T.Credential]
    R[reloadCredential<br>every credentialCheckInterval]
    H[onServerNameIndication<br>at each handshake]
    C[Credential loaded once]
    F -- "read at start" --> E
    E -- "added - written" --> V
    E -- "removed - kept" --> C
    C -- "removed - returned" --> H
    F -- "added - parsed, key pair checked, compared" --> R
    R -- "added - replaced" --> V
    V -- "added - read" --> H
    classDef removed fill:#f4cccc,stroke:#cc0000
    classDef added fill:#d9ead3,stroke:#008800
    class C removed
    class V,R added
    linkStyle 2,3 stroke:#cc0000
    linkStyle 1,4,5,6 stroke:#008800
```

## Copy of a renewed certificate

The certificate copier writes `web.crt` before `web.key`.

```mermaid
sequenceDiagram
    participant J as Copier job
    participant F as web.crt, web.key
    participant R as reloadCredential
    participant V as TVar
    J->>F: new web.crt
    R->>F: files parsed
    R->>R: new certificate, old key: key pair rejected, logged once
    J->>F: new web.key
    R->>F: files parsed
    R->>R: key pair accepted, differs from the credential in use
    R->>V: new credential written
```

## Tests

Each test copies the fixture files into its test directory and replaces them there.

- Transport: a TLS server with an SNI credential `TVar` and `reloadCredential`; a client with SNI receives `web.crt`, then, after the files are replaced, `web2.crt`.
- Key pair: the new certificate with the old key is not served; after the new key is written, the new certificate is served.
- smp-server with the shared HTTPS port, and xftp-server with SNI: the served certificate changes after the files are replaced, without a restart.
- Static site on a separate HTTPS port: the same.
- Key types: smp-server rejects an RSA 2048 and an ECDSA P-256 certificate and keeps the current one; xftp-server serves the ECDSA P-256 certificate.
- A deleted key file: the current certificate is still served.
- Key pair check: for RSA, ECDSA, Ed448 and Ed25519, a matching pair is accepted and a pair of the same type with another key is rejected; a DSA certificate is rejected as an unsupported key type.
- Fixtures, signed by `web_ca` and generated as `tests/fixtures/README.md` states: `web2` (RSA 4096), `web_rsa2048`, `web_ecdsa` and `web_ecdsa2.key` (P-256), `web_dsa`.
