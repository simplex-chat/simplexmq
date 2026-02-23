# XFTP Server Pages Implementation Plan

## Table of Contents
1. [Context](#context)
2. [Executive Summary](#executive-summary)
3. [High-Level Design](#high-level-design)
4. [Detailed Implementation Plan](#detailed-implementation-plan)
5. [Verification](#verification)

---

## 1. Context

The SMP server has a full web infrastructure: server info page, link pages, static site generation, and serving (standalone HTTP/HTTPS or shared TLS port). The XFTP server has none of this — only `httpCredentials` for CORS/browser access to the XFTP protocol.

**Goal:** Add XFTP server pages identical in structure to SMP, with XFTP-specific configuration display and a `/file` page embedding the xftp-web upload/download app.

---

## 2. Executive Summary

**Share SMP's `Static.hs` via `hs-source-dirs`** — XFTP's cabal section references `apps/smp-server/web` for `Static.hs`, while providing its own `Static/Embedded.hs` with XFTP-specific templates. Zero code duplication for serving/rendering logic.

**Key changes (Haskell):**
- Parameterize `Static.hs`: use `E.linkPages` + `E.extraDirs` instead of hardcoded link page list
- Create `apps/xftp-server/web/Static/Embedded.hs` (XFTP templates + xftp-web dist)
- Create `apps/xftp-server/static/index.html` (XFTP server info template)
- Add `xftpServerCLI_` callback pattern (mirrors `smpServerCLI_`)
- Add `[INFORMATION]` section, `[WEB] static_path/http/relay_servers` to XFTP INI parsing/generation
- Update `simplexmq.cabal`: XFTP exe gets `Static`, `Static.Embedded` modules + web deps

**Key changes (TypeScript):**
- `servers.ts`: add `loadServers()` — fetches `./servers.json` at runtime, falls back to baked-in defaults
- `main.ts`: call `await loadServers()` before `initApp()`
- `vite.config.ts`: add `server` mode (empty baked-in servers, CSP placeholder preserved, `base: './'`)

**Reused without duplication:**
- `ServerInformation`, `ServerPublicConfig`, `ServerPublicInfo` types (`src/Simplex/Messaging/Server/Information.hs`)
- `serverPublicInfo` INI parser (`src/Simplex/Messaging/Server/Main.hs`)
- `EmbeddedWebParams`, `WebHttpsParams` types (`src/Simplex/Messaging/Server/Main.hs`)
- All of `Static.hs`: `generateSite`, `serverInformation`, `serveStaticFiles`, `attachStaticFiles`, `staticFiles`, `render`, `section_`, `item_`, `timedTTLText`
- All media assets (CSS, JS, fonts, icons) via `$(embedDir "apps/smp-server/static/media/")`

---

## 3. High-Level Design

### Module Sharing Strategy

```
apps/smp-server/web/Static.hs           ← SHARED (both exes use this)
apps/smp-server/web/Static/Embedded.hs  ← SMP-specific embedded content
apps/xftp-server/web/Static/Embedded.hs ← XFTP-specific embedded content

XFTP cabal hs-source-dirs order:
  1. apps/xftp-server/web  → finds Static/Embedded.hs (XFTP version)
  2. apps/smp-server/web   → finds Static.hs (shared)

GHC searches source dirs in order, first match wins:
  Static.hs       → NOT in xftp-server/web → found in smp-server/web ✓
  Static/Embedded → found in xftp-server/web first ✓
```

**Note:** `Static.hs` imports `Simplex.Messaging.Server (AttachHTTP)` — this SMP module IS exposed in the library, so the XFTP executable can import it. `AttachHTTP` is just a type alias `Socket -> TLS.Context -> IO ()`.

### ServerPublicConfig Mapping (XFTP → existing fields)

| XFTP concept | `ServerPublicConfig` field | Value |
|---|---|---|
| *(not applicable)* | `persistence` | `SPMMemoryOnly` |
| File expiration | `messageExpiration` | `ttl <$> fileExpiration` |
| Stats enabled | `statsEnabled` | `isJust logStats` |
| File upload allowed | `newQueuesAllowed` | `allowNewFiles` |
| Basic auth enabled | `basicAuthEnabled` | `isJust newFileBasicAuth` |

The XFTP `index.html` template uses the same `${...}` variable names but has different label text. The `persistence` row is omitted from the XFTP template entirely.

### `/file` Page Architecture

```
sitePath/
  index.html             ← XFTP server info page (from template)
  media/                 ← shared CSS, JS, fonts, icons
  well-known/            ← AASA, assetlinks
  file/                  ← xftp-web dist (from extraDirs)
    index.html           ← CSP patched at site generation time
    servers.json         ← generated from [WEB] relay_servers
    assets/
      index-xxx.js       ← xftp-web compiled JS bundle
      index-xxx.css      ← styles
      crypto.worker-xxx.js ← encryption Web Worker
```

### Data Flow at Runtime

```
file-server.ini
  ├─ [INFORMATION] → serverPublicInfo → Maybe ServerPublicInfo
  ├─ [WEB] relay_servers → relayServers :: [Text]
  ├─ [WEB] static_path → sitePath
  └─ XFTPServerConfig fields → ServerPublicConfig
       ↓
  ServerInformation {config, information}
       ↓
  generateSite si onionHost sitePath     ← writes index.html + media + file/
       ↓
  writeRelayConfig sitePath relayServers  ← writes file/servers.json, patches CSP
       ↓
  serveStaticFiles EmbeddedWebParams     ← standalone HTTP/HTTPS warp
```

---

## 4. Detailed Implementation Plan

### Step 1: Parameterize `Static.hs`

**File:** `apps/smp-server/web/Static.hs`

1. Add import: `System.FilePath (takeDirectory)`
2. Replace hardcoded link pages with `E.linkPages`; add `E.extraDirs` copying:

```haskell
-- BEFORE:
  createLinkPage "contact"
  createLinkPage "invitation"
  createLinkPage "a"
  createLinkPage "c"
  createLinkPage "g"
  createLinkPage "r"
  createLinkPage "i"

-- AFTER:
  mapM_ createLinkPage E.linkPages
  forM_ E.extraDirs $ \(dir, content) -> do
    createDirectoryIfMissing True $ sitePath </> dir
    forM_ content $ \(path, s) -> do
      createDirectoryIfMissing True $ sitePath </> dir </> takeDirectory path
      B.writeFile (sitePath </> dir </> path) s
```

No change to `serverInformation` — it already uses `E.indexHtml` which resolves per-app via the `Embedded` module.

### Step 2: Update SMP's `Static/Embedded.hs`

**File:** `apps/smp-server/web/Static/Embedded.hs`

Add two new exports to maintain the shared interface:
```haskell
linkPages :: [FilePath]
linkPages = ["contact", "invitation", "a", "c", "g", "r", "i"]

extraDirs :: [(FilePath, [(FilePath, ByteString)])]
extraDirs = []
```

### Step 3: Create XFTP's `Static/Embedded.hs`

**New file:** `apps/xftp-server/web/Static/Embedded.hs`

```haskell
module Static.Embedded where

import Data.FileEmbed (embedDir, embedFile)
import Data.ByteString (ByteString)

indexHtml :: ByteString
indexHtml = $(embedFile "apps/xftp-server/static/index.html")

linkHtml :: ByteString
linkHtml = ""  -- unused: XFTP has no simple link pages

mediaContent :: [(FilePath, ByteString)]
mediaContent = $(embedDir "apps/smp-server/static/media/")  -- reuse SMP media

wellKnown :: [(FilePath, ByteString)]
wellKnown = $(embedDir "apps/smp-server/static/.well-known/")

linkPages :: [FilePath]
linkPages = []

extraDirs :: [(FilePath, [(FilePath, ByteString)])]
extraDirs = [("file", $(embedDir "xftp-web/dist-web/"))]
```

**Build dependency:** `xftp-web/dist-web/` must exist at compile time. Build with `cd xftp-web && npm run build -- --mode server` first.

### Step 4: Create XFTP `index.html` Template

**New file:** `apps/xftp-server/static/index.html`

Copy SMP's `apps/smp-server/static/index.html` with these differences:
- Title: "SimpleX XFTP - Server Information"
- Nav link list: add `<li>` for "/file" ("File transfer")
- Configuration section:
  - **Remove** "Persistence" row
  - "File expiration:" → `${messageExpiration}`
  - "Stats enabled:" → `${statsEnabled}`
  - "File upload allowed:" → `${newQueuesAllowed}`
  - "Basic auth enabled:" → `${basicAuthEnabled}`
- Public information section: identical (same template variables, same structure)
- Footer: identical

### Step 5: Add `xftpServerCLI_` with Callbacks

**File:** `src/Simplex/FileTransfer/Server/Main.hs`

**New imports:**
```haskell
import Simplex.Messaging.Server.Information
import Simplex.Messaging.Server.Main (EmbeddedWebParams (..), WebHttpsParams (..), serverPublicInfo, simplexmqSource)
import Simplex.Messaging.Transport.Client (TransportHost (..))
```

**New function** (mirrors `smpServerCLI_`):
```haskell
xftpServerCLI_ ::
  (ServerInformation -> Maybe TransportHost -> FilePath -> IO ()) ->
  (EmbeddedWebParams -> IO ()) ->
  FilePath -> FilePath -> IO ()
```

**Refactor existing:**
```haskell
xftpServerCLI :: FilePath -> FilePath -> IO ()
xftpServerCLI = xftpServerCLI_ (\_ _ _ -> pure ()) (\_ -> pure ())
```

**In `runServer`, add after `printXFTPConfig`:**

1. Build `ServerPublicConfig` (see mapping table in Section 3)
2. Build `ServerInformation {config, information = serverPublicInfo ini}`
3. Parse web config:
   - `webStaticPath' = eitherToMaybe $ T.unpack <$> lookupValue "WEB" "static_path" ini`
   - `webHttpPort = eitherToMaybe $ read . T.unpack <$> lookupValue "WEB" "http" ini`
   - `webHttpsParams'` = `{port, cert, key}` from `[WEB]` (same pattern as SMP)
   - `relayServers = eitherToMaybe $ T.splitOn "," <$> lookupValue "WEB" "relay_servers" ini`
4. Extract `onionHost` from `[TRANSPORT] host` (same as SMP)
5. Web server logic:
```haskell
case webStaticPath' of
  Just path -> do
    generateSite si onionHost path
    -- Post-process: inject relay server config into /file page
    forM_ relayServers $ \servers -> do
      let fileDir = path </> "file"
          hosts = map (encodeUtf8 . T.strip) $ filter (not . T.null) servers
      -- Write servers.json for xftp-web runtime loading
      B.writeFile (fileDir </> "servers.json") $ "[" <> B.intercalate "," (map (\h -> "\"" <> h <> "\"") hosts) <> "]"
      -- Patch CSP connect-src in file/index.html (inline ByteString replacement)
      let cspHosts = B.intercalate " " $ map (parseXFTPHost . T.strip) $ filter (not . T.null) servers
          marker = "__CSP_CONNECT_SRC__"
      fileIndex <- B.readFile (fileDir </> "index.html")
      let (before, after) = B.breakSubstring marker fileIndex
          patched = if B.null after then fileIndex
                    else before <> cspHosts <> B.drop (B.length marker) after
      B.writeFile (fileDir </> "index.html") patched
    when (isJust webHttpPort || isJust webHttpsParams') $
      serveStaticFiles EmbeddedWebParams {webStaticPath = path, webHttpPort, webHttpsParams = webHttpsParams'}
    runXFTPServer serverConfig
  Nothing -> runXFTPServer serverConfig
```

Where `parseXFTPHost` extracts `https://host:port` from an `xftp://fingerprint@host:port` address.

**Note:** `B.replace` is not in `Data.ByteString.Char8`. Use a simple find-and-replace helper (similar pattern to `item_` in `Static.hs`), or use `Data.ByteString.Search` from `stringsearch` package, or inline a ByteString replacement.

### Step 6: Update XFTP INI Generation

**File:** `src/Simplex/FileTransfer/Server/Main.hs` (in `iniFileContent`)

Add to the generated INI string:

After existing `[WEB]` section:
```ini
[WEB]
# cert: /etc/opt/simplex-xftp/web.crt
# key: /etc/opt/simplex-xftp/web.key
# static_path: /var/opt/simplex-xftp/www
# http: 8080
# relay_servers: xftp://fingerprint@host1,xftp://fingerprint@host2
```

Add new `[INFORMATION]` section (same format as SMP):
```ini
[INFORMATION]
# source_code: https://github.com/simplex-chat/simplexmq
# usage_conditions:
# condition_amendments:
# server_country:
# operator:
# operator_country:
# website:
# admin_simplex:
# admin_email:
# admin_pgp:
# admin_pgp_fingerprint:
# complaints_simplex:
# complaints_email:
# complaints_pgp:
# complaints_pgp_fingerprint:
# hosting:
# hosting_country:
# hosting_type: virtual
```

### Step 7: Update XFTP Entry Point

**File:** `apps/xftp-server/Main.hs`

```haskell
import qualified Static
import Simplex.FileTransfer.Server.Main (xftpServerCLI_)

main = do
  ...
  withGlobalLogging logCfg $ xftpServerCLI_ Static.generateSite Static.serveStaticFiles cfgPath logPath
```

### Step 8: Update `simplexmq.cabal`

**xftp-server executable:**
```cabal
executable xftp-server
  main-is: Main.hs
  other-modules:
      Static
      Static.Embedded
      Paths_simplexmq
  hs-source-dirs:
      apps/xftp-server
      apps/xftp-server/web
      apps/smp-server/web
  build-depends:
      base
    , bytestring
    , directory
    , file-embed
    , filepath
    , network
    , simple-logger
    , simplexmq
    , text
    , unliftio
    , wai
    , wai-app-static
    , warp ==3.3.30
    , warp-tls ==3.4.7
```

**extra-source-files:** Add:
```cabal
    apps/xftp-server/static/index.html
```

### Step 9: Modify xftp-web — Runtime Server Loading

**File:** `xftp-web/web/servers.ts`

```typescript
import {parseXFTPServer, type XFTPServer} from '../src/protocol/address.js'

declare const __XFTP_SERVERS__: string[]
const defaultServers: string[] = __XFTP_SERVERS__

let runtimeServers: string[] | null = null

export async function loadServers(): Promise<void> {
  try {
    const resp = await fetch('./servers.json')
    if (resp.ok) {
      const data: string[] = await resp.json()
      if (Array.isArray(data) && data.length > 0) {
        runtimeServers = data
      }
    }
  } catch { /* fall back to defaults */ }
}

export function getServers(): XFTPServer[] {
  return (runtimeServers ?? defaultServers).map(parseXFTPServer)
}

export function pickRandomServer(servers: XFTPServer[]): XFTPServer {
  return servers[Math.floor(Math.random() * servers.length)]
}
```

**File:** `xftp-web/web/main.ts` — add `loadServers` import and call:

```typescript
import {loadServers} from './servers.js'

async function main() {
  await sodium.ready
  await loadServers()
  initApp()
  window.addEventListener('hashchange', initApp)
}
```

**File:** `xftp-web/web/download.ts` — NO changes needed (uses server addresses from file description in URL hash, not `getServers()`).

### Step 10: Modify xftp-web — Vite `server` Build Mode

**File:** `xftp-web/vite.config.ts`

Add `server` mode handling:
```typescript
if (mode === 'server') {
  define['__XFTP_SERVERS__'] = JSON.stringify([])
  servers = []
} else if (mode === 'development') {
  // ... existing dev logic
} else {
  // ... existing production logic
}
```

CSP plugin: skip replacement in server mode:
```typescript
handler(html) {
  if (isDev) return html.replace(/<meta\s[^>]*?Content-Security-Policy[\s\S]*?>/i, '')
  if (mode === 'server') return html  // leave __CSP_CONNECT_SRC__ placeholder
  return html.replace('__CSP_CONNECT_SRC__', origins)
}
```

Add `base: './'` for server mode (relative asset paths, needed for `/file/` subpath):
```typescript
base: mode === 'server' ? './' : '/',
```

### `servers.json` Format

Generated at site-generation time by the Haskell server:
```json
["xftp://fingerprint1@host1:443", "xftp://fingerprint2@host2:443"]
```

Simple JSON array of XFTP server address strings.

### Fallback Behavior

| Scenario | Upload servers | Download servers |
|---|---|---|
| `relay_servers` configured | From `servers.json` | From file description (URL hash) |
| `relay_servers` not configured | Build-time defaults (empty in server mode) | From file description (URL hash) |
| No `static_path` configured | No `/file` page served | N/A |

---

## 5. Verification

### Build
```bash
# 1. Build xftp-web for server embedding
cd xftp-web && npm run build -- --mode server && cd ..

# 2. Build both servers (fast, no optimization)
cabal build smp-server --ghc-options=-O0
cabal build xftp-server --ghc-options=-O0
```

### Test
```bash
cabal test simplexmq-test --ghc-options=-O0
```

### Manual Smoke Test
1. `cabal run xftp-server -- init -p /tmp/xftp-files -q 10gb`
2. Edit `file-server.ini`: uncomment `static_path`, `http: 8080`, add `relay_servers`
3. `cabal run xftp-server -- start`
4. `curl http://localhost:8080/` → server info HTML
5. `curl http://localhost:8080/file/` → xftp-web HTML
6. `curl http://localhost:8080/file/servers.json` → relay servers JSON

### Files Modified (Summary)

| File | Type | Change |
|---|---|---|
| `apps/smp-server/web/Static.hs` | Modify | `E.linkPages`, `E.extraDirs`, `takeDirectory` import |
| `apps/smp-server/web/Static/Embedded.hs` | Modify | Add `linkPages`, `extraDirs` exports |
| `apps/xftp-server/Main.hs` | Modify | Import Static, use `xftpServerCLI_` |
| `apps/xftp-server/web/Static/Embedded.hs` | **NEW** | XFTP templates + xftp-web dist embedding |
| `apps/xftp-server/static/index.html` | **NEW** | XFTP server info HTML template |
| `src/Simplex/FileTransfer/Server/Main.hs` | Modify | `xftpServerCLI_`, web logic, INI parsing/generation |
| `simplexmq.cabal` | Modify | XFTP exe: modules, deps, source dirs, extra-source-files |
| `xftp-web/web/servers.ts` | Modify | Add `loadServers()` for runtime config |
| `xftp-web/web/main.ts` | Modify | Call `loadServers()` at startup |
| `xftp-web/vite.config.ts` | Modify | `server` mode, conditional `base` |
