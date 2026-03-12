# Simplex.Messaging.Server.Web

> Static site generation, serving (HTTP, HTTPS, HTTP/2), and template rendering for the router info page.

**Source**: [`Web.hs`](../../../../../src/Simplex/Messaging/Server/Web.hs)

## attachStaticFiles — reusing Warp internals for TLS connections

`attachStaticFiles` receives already-established TLS connections (which passed TLS handshake and ALPN check in the SMP transport layer) and runs Warp's HTTP handler on them. It manually calls `WI.withII`, `WT.attachConn`, `WI.registerKillThread`, and `WI.serveConnection` — internal Warp APIs. This couples the router to Warp internals and could break on Warp library updates.

## serveStaticPageH2 — path traversal protection

The H2 static file server uses `canonicalizePath` to resolve symlinks and `..` components, then checks the resolved path is a prefix of `canonicalRoot`. The caller must pre-compute `canonicalRoot` via `canonicalizePath` for the check to work. Without pre-canonicalization, a symlink in the root itself could defeat the protection.

## .well-known path rewriting

Both WAI (`changeWellKnownPath`) and H2 (`rewriteWellKnownH2`) rewrite `/.well-known/` to `/well-known/` because `staticApp` does not serve hidden directories (dot-prefixed). The generated site uses `well-known/` as the physical directory. If one rewrite path is updated without the other, the served files diverge between HTTP/1.1 and HTTP/2.

## section_ / item_ — template rendering

`render` applies substitutions to HTML templates using `<x-label>...</x-label>` section markers and `${label}` item markers. When a substitution value is `Nothing`, the entire section (including content between markers) is removed. `section_` recurses to handle multiple occurrences of the same section. `item_` is a simple find-and-replace. The section end marker is mandatory — a missing end marker calls `error` (crashes).
