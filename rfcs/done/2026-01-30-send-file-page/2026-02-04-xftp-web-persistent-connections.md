# XFTPClientAgent Pattern

## TOC
1. Executive Summary
2. Changes: client.ts
3. Changes: agent.ts
4. Changes: test/browser.test.ts
5. Verification

## Executive Summary

Add `XFTPClientAgent` — a per-server connection pool matching the Haskell pattern. The agent caches `XFTPClient` instances by server URL. All orchestration functions (`uploadFile`, `downloadFile`, `deleteFile`) take `agent` as first parameter and use `getXFTPServerClient(agent, server)` instead of calling `connectXFTP` directly. Connections stay open on success; the caller creates and closes the agent.

`connectXFTP` and `closeXFTP` stay exported (used by `XFTPWebTests.hs` Haskell tests). The `browserClients` hack, per-function `connections: Map`, and `getOrConnect` are deleted.

## Changes: client.ts

**Add** after types section: `XFTPClientAgent` interface, `newXFTPAgent`, `getXFTPServerClient`, `closeXFTPServerClient`, `closeXFTPAgent`.

**Delete**: `browserClients` Map and all `isNode` browser-cache checks in `connectXFTP` and `closeXFTP`.

**Revert `closeXFTP`** to unconditional `c.transport.close()` (browser transport.close() is already a no-op).

`connectXFTP` stays exported (backward compat) but becomes a raw low-level function — no caching.

## Changes: agent.ts

**Imports**: replace `connectXFTP`/`closeXFTP` with `getXFTPServerClient`/`closeXFTPAgent` etc.

**Re-export** from agent.ts: `newXFTPAgent`, `closeXFTPAgent`, `XFTPClientAgent`.

**`uploadFile`**: add `agent: XFTPClientAgent` as first param. Replace `connectXFTP` → `getXFTPServerClient`. Remove `finally { closeXFTP }`. Pass `agent` to `uploadRedirectDescription`.

**`uploadRedirectDescription`**: change from `(client, server, innerFd)` to `(agent, server, innerFd)`. Get client via `getXFTPServerClient`.

**`downloadFile`**: add `agent` param. Delete local `connections: Map`. Replace `getOrConnect` → `getXFTPServerClient`. Remove finally cleanup. Pass `agent` to `downloadWithRedirect`.

**`downloadWithRedirect`**: add `agent` param. Same replacements. Remove try/catch cleanup. Recursive call passes `agent`.

**`deleteFile`**: add `agent` param. Same pattern.

**Delete**: `getOrConnect` function entirely.

## Changes: test/browser.test.ts

Create agent before operations, pass to upload/download, close in finally.

## Verification

1. `npx vitest --run` — browser round-trip test passes
2. No remaining `browserClients`, `getOrConnect`, or per-function `connections: Map` locals
3. `connectXFTP` and `closeXFTP` still exported (XFTPWebTests.hs compat)
4. All orchestration functions take `agent` as first param
