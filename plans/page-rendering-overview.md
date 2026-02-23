# SMP Server Page Generation — Overview

## Table of Contents

1. [Architecture](#architecture)
2. [Call Graph](#call-graph)
3. [Files by Layer](#files-by-layer)
4. [Data Flow: INI → Types → Template → HTML](#data-flow-ini--types--template--html)
5. [INI Configuration](#ini-configuration)
6. [ServerInformation Construction](#serverinformation-construction)
7. [Template Engine](#template-engine)
8. [Template Variables](#template-variables-indexhtml)
9. [Serving Modes and Routing](#serving-modes-and-routing)
10. [Link Pages](#link-pages)
11. [Static Assets](#static-assets)

---

## Architecture

The SMP server generates a static mini-site at startup and serves it via three possible mechanisms: standalone HTTP, standalone HTTPS, or ALPN-multiplexed on the SMP TLS port.

## Call Graph

```
Main.main
  └─ smpServerCLI_(Static.generateSite, Static.serveStaticFiles, Static.attachStaticFiles, ...)
       └─ runServer
            ├─ builds ServerInformation { ServerPublicConfig, Maybe ServerPublicInfo }
            ├─ runWebServer(path, httpsParams, serverInfo)
            │    ├─ generateSite(si, onionHost, path)     ← writes files to disk
            │    │    ├─ serverInformation(si, onionHost)  ← renders index.html
            │    │    │    └─ render(E.indexHtml, substs)
            │    │    │         └─ section_ / item_        ← template engine
            │    │    ├─ copyDir "media" E.mediaContent
            │    │    ├─ copyDir "well-known" E.wellKnown
            │    │    └─ createLinkPage × 7 (contact, invitation, a, c, g, r, i)
            │    │         └─ writes E.linkHtml
            │    └─ serveStaticFiles(EmbeddedWebParams)    ← starts HTTP/HTTPS Warp
            │         └─ staticFiles(path) :: Application
            │              └─ wai-app-static + .well-known rewrite
            └─ [if sharedHTTP] attachStaticFiles(path, action)
                 └─ Warp's serveConnection on ALPN-routed HTTP connections
```

## Files by Layer

| Layer | File | Role |
|---|---|---|
| **Entry** | `apps/smp-server/Main.hs:21` | Wires `Static.*` into `smpServerCLI_` |
| **Orchestration** | `src/.../Server/Main.hs:466-603` | `runServer` — builds `ServerInformation`, calls `runWebServer`, decides `attachStaticFiles` vs standalone |
| **INI parsing** | `src/.../Server/Main.hs:748-779` | `serverPublicInfo` reads `[INFORMATION]` section into `ServerPublicInfo` |
| **INI generation** | `src/.../Server/Main/Init.hs:65-171` | `iniFileContent` generates `[WEB]` section; `informationIniContent` generates `[INFORMATION]` section |
| **Types** | `src/.../Server/Information.hs` | `ServerInformation`, `ServerPublicConfig`, `ServerPublicInfo`, `Entity`, `ServerContactAddress`, `PGPKey`, `HostingType`, etc. |
| **Generation** | `apps/smp-server/web/Static.hs:95-117` | `generateSite` — writes all files to disk |
| **Rendering** | `apps/smp-server/web/Static.hs:119-253` | `serverInformation` — builds substitution pairs; `render`/`section_`/`item_` — template engine |
| **Serving** | `apps/smp-server/web/Static.hs:39-93` | `serveStaticFiles` (standalone Warp), `attachStaticFiles` (shared TLS port), `staticFiles` (WAI app) |
| **Embedding** | `apps/smp-server/web/Static/Embedded.hs` | TH `embedFile`/`embedDir` for `index.html`, `link.html`, `media/`, `.well-known/` |
| **Transport routing** | `src/.../Server.hs:202-219` | `runServer` per-port — routes `sniUsed` TLS connections to `attachHTTP` |
| **Transport type** | `src/.../Server.hs:163` | `type AttachHTTP = Socket -> TLS.Context -> IO ()` |
| **Shared port detection** | `src/.../Server/CLI.hs:374-387` | `iniTransports` — sets `addHTTP=True` when a transport port matches `[WEB] https` |

## Data Flow: INI → Types → Template → HTML

```
smp-server.ini
  │
  ├─ [INFORMATION] section
  │    └─ serverPublicInfo (Main.hs:748)
  │         └─ Maybe ServerPublicInfo
  │
  ├─ [WEB] section
  │    ├─ static_path → webStaticPath'
  │    ├─ http → webHttpPort
  │    └─ https + cert + key → webHttpsParams'
  │
  ├─ [TRANSPORT] section
  │    ├─ host → onionHost detection (find THOnionHost in parsed hosts)
  │    └─ port → iniTransports (sets addHTTP when port == [WEB] https)
  │
  └─ Runtime config (ServerConfig fields)
       └─ ServerPublicConfig { persistence, messageExpiration, statsEnabled, newQueuesAllowed, basicAuthEnabled }
            │
            └─ ServerInformation { config, information }
                 │
                 └─ serverInformation (Static.hs:119)
                      │
                      ├─ substConfig: 5 always-present substitution pairs
                      ├─ substInfo: conditional substitution pairs from ServerPublicInfo
                      └─ onionHost: optional meta tag
                           │
                           └─ render(E.indexHtml, substs)
                                │
                                └─ section_ / item_ engine
                                     │
                                     └─ ByteString → written to sitePath/index.html
```

## INI Configuration

### `[INFORMATION]` Section — parsed by `serverPublicInfo` (Main.hs:748-779)

| INI key | Type | Maps to |
|---|---|---|
| `source_code` | Required (gates entire section) | `ServerPublicInfo.sourceCode` |
| `usage_conditions` | Optional | `ServerConditions.conditions` |
| `condition_amendments` | Optional | `ServerConditions.amendments` |
| `server_country` | Optional, ISO-3166 2-letter | `ServerPublicInfo.serverCountry` |
| `operator` | Optional | `Entity.name` |
| `operator_country` | Optional, ISO-3166 | `Entity.country` |
| `website` | Optional | `ServerPublicInfo.website` |
| `admin_simplex` | Optional, SimpleX address | `ServerContactAddress.simplex` |
| `admin_email` | Optional | `ServerContactAddress.email` |
| `admin_pgp` + `admin_pgp_fingerprint` | Optional, both required | `PGPKey` |
| `complaints_simplex`, `complaints_email`, `complaints_pgp`, `complaints_pgp_fingerprint` | Same structure as admin | `ServerPublicInfo.complaintsContacts` |
| `hosting` | Optional | `Entity.name` |
| `hosting_country` | Optional, ISO-3166 | `Entity.country` |
| `hosting_type` | Optional | `HostingType` (virtual/dedicated/colocation/owned) |

If `source_code` is absent, `serverPublicInfo` returns `Nothing` and the entire information section is omitted.

### `[WEB]` Section — parsed in `runServer` (Main.hs:597-603)

| INI key | Parser | Variable |
|---|---|---|
| `static_path` | `lookupValue` | `webStaticPath'` — if absent, no site generated |
| `http` | `read . T.unpack` | `webHttpPort` — standalone HTTP Warp |
| `https` | `read . T.unpack` | `webHttpsParams'.port` — standalone HTTPS Warp OR shared port |
| `cert` | `T.unpack` | `webHttpsParams'.cert` |
| `key` | `T.unpack` | `webHttpsParams'.key` |

### `[TRANSPORT]` Section — affects serving mode

| INI key | Effect on page serving |
|---|---|
| `host` | Parsed for `.onion` hostnames → `onionHost` → `<x-onionHost>` meta tag |
| `port` | Comma-separated ports. If any matches `[WEB] https`, that port gets `addHTTP=True` |

## ServerInformation Construction

Built in `runServer` (Main.hs:454-465) from runtime `ServerConfig` fields:

```haskell
ServerPublicConfig
  { persistence      -- derived from serverStoreCfg:
                     --   SSCMemory Nothing          → SPMMemoryOnly
                     --   SSCMemory (Just {storeMsgsFile=Nothing}) → SPMQueues
                     --   otherwise                  → SPMMessages
  , messageExpiration -- ttl <$> cfg.messageExpiration
  , statsEnabled      -- isJust logStats
  , newQueuesAllowed  -- cfg.allowNewQueues
  , basicAuthEnabled  -- isJust cfg.newQueueBasicAuth
  }

ServerInformation { config, information }
  -- information = cfg.information :: Maybe ServerPublicInfo (from INI [INFORMATION])
```

## Template Engine

Custom two-pass substitution in `Static.hs:219-253`:

1. **`render`**: Iterates over `[(label, Maybe content)]` pairs, calling `section_` for each.
2. **`section_`**: Finds `<x-label>...</x-label>` markers. If the substitution value is `Just non-empty`, keeps the section and processes inner `${label}` items via `item_`. If `Nothing` or empty, collapses the entire section. If no section markers found, delegates to `item_` on the whole source.
3. **`item_`**: Replaces all `${label}` occurrences with the value.

## Template Variables (index.html)

### Substitution Pairs — built by `serverInformation` (Static.hs:119-190)

**`substConfig`** (always present, derived from `ServerPublicConfig`):

| Label | Value |
|---|---|
| `persistence` | `"In-memory only"` / `"Queues"` / `"Queues and messages"` |
| `messageExpiration` | `timedTTLText ttl` or `"Never"` |
| `statsEnabled` | `"Yes"` / `"No"` |
| `newQueuesAllowed` | `"Yes"` / `"No"` |
| `basicAuthEnabled` | `"Yes"` / `"No"` |

**`substInfo`** (from `Maybe ServerPublicInfo`, with `emptyServerInfo ""` as fallback):

| Label | Source | Conditional |
|---|---|---|
| `sourceCode` | `spi.sourceCode` | Section present if non-empty |
| `noSourceCode` | `Just "none"` if sourceCode empty | Inverse of above |
| `version` | `simplexMQVersion` | Always |
| `commitSourceCode` | `spi.sourceCode` or `simplexmqSource` | Always |
| `shortCommit` | `take 7 simplexmqCommit` | Always |
| `commit` | `simplexmqCommit` | Always |
| `website` | `spi.website` | Section collapsed if Nothing |
| `usageConditions` | `conditions` | Section collapsed if Nothing |
| `usageAmendments` | `amendments` | Section collapsed if Nothing |
| `operator` | `Just ""` (section marker) | Section collapsed if no operator |
| `operatorEntity` | `entity.name` | Inside operator section |
| `operatorCountry` | `entity.country` | Inside operator section |
| `admin` | `Just ""` (section marker) | Section collapsed if no adminContacts |
| `adminSimplex` | `strEncode simplex` | Inside admin section |
| `adminEmail` | `email` | Inside admin section |
| `adminPGP` | `pkURI` | Inside admin section |
| `adminPGPFingerprint` | `pkFingerprint` | Inside admin section |
| `complaints` | Same structure as admin | Section collapsed if no complaintsContacts |
| `hosting` | `Just ""` (section marker) | Section collapsed if no hosting |
| `hostingEntity` | `entity.name` | Inside hosting section |
| `hostingCountry` | `entity.country` | Inside hosting section |
| `serverCountry` | `spi.serverCountry` | Section collapsed if Nothing |
| `hostingType` | `strEncode`, capitalized first letter | Section collapsed if Nothing |

**`onionHost`** (separate):

| Label | Source |
|---|---|
| `onionHost` | `strEncode <$> onionHost` — from `[TRANSPORT] host`, first `.onion` entry |

## Serving Modes and Routing

### Mode Decision (Main.hs:466-477)

```
webStaticPath' = [WEB] static_path from INI
sharedHTTP     = any transport port matches [WEB] https port

case webStaticPath' of
  Just path | sharedHTTP →
    runWebServer path Nothing si        -- generate site, NO standalone HTTPS (shared instead)
    attachStaticFiles path $ \attachHTTP →
      runSMPServer cfg (Just attachHTTP) -- SMP server with HTTP routing callback
  Just path →
    runWebServer path webHttpsParams' si -- generate site, maybe start standalone HTTP/HTTPS
    runSMPServer cfg Nothing             -- SMP server without HTTP routing
  Nothing →
    logWarn "No server static path set"
    runSMPServer cfg Nothing
```

### `runWebServer` (Main.hs:587-596)

1. Extracts `onionHost` from `[TRANSPORT] host` (finds first `THOnionHost`)
2. Extracts `webHttpPort` from `[WEB] http`
3. Calls `generateSite si onionHost webStaticPath` — writes all files
4. If `webHttpPort` or `webHttpsParams` set → calls `serveStaticFiles` (starts standalone Warp)

### Shared Port — ALPN Routing (Server.hs:202-219)

`iniTransports` (CLI.hs:374-387) builds `[(ServiceName, ASrvTransport, AddHTTP)]`:
- For each comma-separated port in `[TRANSPORT] port`, creates a `(port, TLS, addHTTP)` entry
- `addHTTP = True` when `port == [WEB] https`

Per-port `runServer` (Server.hs:202):
- If `httpCreds` + `attachHTTP_` + `addHTTP` all present:
  - Uses `combinedCreds = TLSServerCredential { credential = smpCreds, sniCredential = Just httpCreds }`
  - `runTransportServerState_` with HTTPS TLS params
  - On each connection: if `sniUsed` (client connected using the HTTP SNI credential) → calls `attachHTTP socket tlsContext`
  - Otherwise → normal SMP client handling
- If not: standard SMP transport, no HTTP routing

### `attachStaticFiles` (Static.hs:52-73)

Initializes Warp internal state (`WI.withII`) once, then provides a callback that:
1. Gets peer address from socket
2. Attaches the TLS context as a Warp connection (`WT.attachConn`)
3. Registers a timeout handler
4. Calls `WI.serveConnection` — Warp processes HTTP requests using `staticFiles` WAI app

### `staticFiles` WAI Application (Static.hs:78-93)

- Uses `wai-app-static` (`S.staticApp`) rooted at the generated site directory
- Directory listing disabled (`ssListing = Nothing`)
- Custom MIME type: `apple-app-site-association` → `application/json`
- Path rewrite: `/.well-known/...` → `/well-known/...` (because `staticApp` doesn't allow hidden folders)

## Link Pages

`link.html` is used unchanged for `/contact/`, `/invitation/`, `/a/`, `/c/`, `/g/`, `/r/`, `/i/`. Each path gets a directory with `index.html` = `E.linkHtml`.

Client-side `contact.js`:
1. Reads `document.location` URL
2. Extracts path action (`contact`, `a`, etc.)
3. Rewrites protocol to `https://`
4. Constructs `simplex:` app URI with hostname injection into hash params
5. Sets `mobileConnURIanchor.href` to app URI
6. Renders QR code of the HTTPS URL via `qrcode.js`

## Static Assets

All under `apps/smp-server/static/`, embedded at compile time via `file-embed` TH:

| File | Embedded via | Purpose |
|---|---|---|
| `index.html` | `embedFile` → `E.indexHtml` | Server information page template |
| `link.html` | `embedFile` → `E.linkHtml` | Contact/invitation link page |
| `media/*` | `embedDir` → `E.mediaContent` | CSS, JS, fonts, icons (23 files) |
| `.well-known/*` | `embedDir` → `E.wellKnown` | `apple-app-site-association`, `assetlinks.json` |

Media files include: `style.css`, `tailwind.css`, `script.js`, `contact.js`, `qrcode.js`, `swiper-bundle.min.{css,js}`, `favicon.ico`, `logo-{light,dark}.png`, `logo-symbol-{light,dark}.svg`, `sun.svg`, `moon.svg`, `apple_store.svg`, `google_play.svg`, `f_droid.svg`, `testflight.png`, `apk_icon.png`, `contact_page_mobile.png`, `Gilroy{Bold,Light,Medium,Regular,RegularItalic}.woff2`.

### Cabal Dependencies (smp-server executable, simplexmq.cabal:398-429)

```
other-modules: Static, Static.Embedded
hs-source-dirs: apps/smp-server, apps/smp-server/web
build-depends: file-embed, wai, wai-app-static, warp ==3.3.30, warp-tls ==3.4.7,
               network, directory, filepath, text, bytestring, unliftio, simple-logger
```
