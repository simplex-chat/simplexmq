# Plan: Browser ↔ Haskell File Transfer Tests

## Table of Contents
1. Goal
2. Current State
3. Implementation
4. Success Criteria
5. Files
6. Order

## 1. Goal
Run browser upload/download tests in headless Chromium via Vitest, proving fetch-based transport works in real browser environment.

## 2. Current State
- `client.ts`: Transport abstraction done — http2 for Node, fetch for browser ✓
- `agent.ts`: Uses `node:crypto` (randomBytes) and `node:zlib` (deflateRawSync/inflateRawSync) — **won't run in browser**
- `XFTPWebTests.hs`: Cross-language tests exist (Haskell calls TS via Node.js) ✓

## 3. Implementation

### 3.1 Make agent.ts isomorphic

| Current (Node.js only) | Isomorphic replacement |
|------------------------|------------------------|
| `import crypto from "node:crypto"` | Remove import |
| `import zlib from "node:zlib"` | `import pako from "pako"` |
| `crypto.randomBytes(32)` | `crypto.getRandomValues(new Uint8Array(32))` |
| `zlib.deflateRawSync(buf)` | `pako.deflateRaw(buf)` |
| `zlib.inflateRawSync(buf)` | `pako.inflateRaw(buf)` |

Note: `crypto.getRandomValues` available in both browser and Node.js (globalThis.crypto).

### 3.2 Vitest browser mode setup

`package.json` additions:
```json
"devDependencies": {
  "vitest": "^3.0.0",
  "@vitest/browser": "^3.0.0",
  "playwright": "^1.50.0",
  "@types/pako": "^2.0.3"
},
"dependencies": {
  "pako": "^2.1.0"
}
```

`vitest.config.ts`:
```typescript
import {defineConfig} from 'vitest/config'
import {readFileSync} from 'fs'
import {createHash} from 'crypto'

// Compute fingerprint from ca.crt (same as Haskell's loadFileFingerprint)
const caCert = readFileSync('../tests/fixtures/ca.crt')
const fingerprint = createHash('sha256').update(caCert).digest('base64url')
const serverAddr = `xftp://${fingerprint}@localhost:7000`

export default defineConfig({
  define: {
    'import.meta.env.XFTP_SERVER': JSON.stringify(serverAddr)
  },
  test: {
    browser: {
      enabled: true,
      provider: 'playwright',
      instances: [{browser: 'chromium'}],
      headless: true,
      providerOptions: {
        launch: {ignoreHTTPSErrors: true}
      }
    },
    globalSetup: './test/globalSetup.ts'
  }
})
```

### 3.3 Server startup

`test/globalSetup.ts`:
```typescript
import {spawn, ChildProcess} from 'child_process'
import {resolve, join} from 'path'
import {mkdtempSync, writeFileSync, copyFileSync} from 'fs'
import {tmpdir} from 'os'

let server: ChildProcess | null = null

export async function setup() {
  const fixtures = resolve(__dirname, '../../tests/fixtures')

  // Create temp directories
  const cfgDir = mkdtempSync(join(tmpdir(), 'xftp-cfg-'))
  const logDir = mkdtempSync(join(tmpdir(), 'xftp-log-'))
  const filesDir = mkdtempSync(join(tmpdir(), 'xftp-files-'))

  // Copy certificates to cfgDir (xftp-server expects ca.crt, server.key, server.crt there)
  copyFileSync(join(fixtures, 'ca.crt'), join(cfgDir, 'ca.crt'))
  copyFileSync(join(fixtures, 'server.key'), join(cfgDir, 'server.key'))
  copyFileSync(join(fixtures, 'server.crt'), join(cfgDir, 'server.crt'))

  // Write INI config file
  const iniContent = `[STORE_LOG]
enable: off

[TRANSPORT]
host: localhost
port: 7000

[FILES]
path: ${filesDir}

[WEB]
cert: ${join(fixtures, 'web.crt')}
key: ${join(fixtures, 'web.key')}
`
  writeFileSync(join(cfgDir, 'file-server.ini'), iniContent)

  // Spawn xftp-server with env vars
  server = spawn('cabal', ['exec', 'xftp-server', '--', 'start'], {
    env: {
      ...process.env,
      XFTP_SERVER_CFG_PATH: cfgDir,
      XFTP_SERVER_LOG_PATH: logDir
    },
    stdio: ['ignore', 'pipe', 'pipe']
  })

  // Wait for "Listening on port 7000..."
  await waitForServerReady(server)
}

export async function teardown() {
  server?.kill('SIGTERM')
  await new Promise(r => setTimeout(r, 500))
}

function waitForServerReady(proc: ChildProcess): Promise<void> {
  return new Promise((resolve, reject) => {
    const timeout = setTimeout(() => reject(new Error('Server start timeout')), 15000)
    proc.stdout?.on('data', (data: Buffer) => {
      if (data.toString().includes('Listening on port')) {
        clearTimeout(timeout)
        resolve()
      }
    })
    proc.stderr?.on('data', (data: Buffer) => {
      console.error('[xftp-server]', data.toString())
    })
    proc.on('error', reject)
    proc.on('exit', (code) => {
      clearTimeout(timeout)
      if (code !== 0) reject(new Error(`Server exited with code ${code}`))
    })
  })
}
```

Server env vars (from `apps/xftp-server/Main.hs` + `getEnvPath`):
- `XFTP_SERVER_CFG_PATH` — directory containing `file-server.ini` and certs (`ca.crt`, `server.key`, `server.crt`)
- `XFTP_SERVER_LOG_PATH` — directory for logs

### 3.4 Browser test

`test/browser.test.ts`:
```typescript
import {test, expect} from 'vitest'
import {encryptFileForUpload, uploadFile, downloadFile} from '../src/agent.js'
import {parseXFTPServer} from '../src/protocol/address.js'

const server = parseXFTPServer(import.meta.env.XFTP_SERVER)

test('browser upload + download round-trip', async () => {
  const data = new Uint8Array(50000)
  crypto.getRandomValues(data)
  const encrypted = encryptFileForUpload(data, 'test.bin')
  const {rcvDescription} = await uploadFile(server, encrypted)
  const {content} = await downloadFile(rcvDescription)
  expect(content).toEqual(data)
})
```

## 4. Success Criteria

1. `npm run build` — agent.ts compiles without node: imports
2. `cabal test --test-option='--match=/XFTP Web Client/'` — existing Node.js tests still pass
3. `npm run test:browser` — browser round-trip test passes in headless Chromium

## 5. Files to Create/Modify

**Modify:**
- `xftp-web/package.json` — add vitest, @vitest/browser, playwright, pako, @types/pako
- `xftp-web/src/agent.ts` — replace node:crypto, node:zlib with isomorphic alternatives

**Create:**
- `xftp-web/vitest.config.ts` — browser mode config
- `xftp-web/test/globalSetup.ts` — xftp-server lifecycle
- `xftp-web/test/browser.test.ts` — browser round-trip test

## 6. Order of Implementation

1. **Add pako dependency** — `npm install pako @types/pako`
2. **Make agent.ts isomorphic** — replace node:crypto, node:zlib
3. **Verify Node.js tests pass** — `cabal test --test-option='--match=/XFTP Web Client/'`
4. **Set up Vitest** — add devDeps, create vitest.config.ts
5. **Create globalSetup.ts** — write INI config, spawn xftp-server
6. **Write browser test** — upload + download round-trip
7. **Verify browser test passes** — `npm run test:browser`
