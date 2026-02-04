# xftp-web

Browser-compatible XFTP file transfer client in TypeScript.

## Prerequisites

- Haskell toolchain with `cabal` (to build `xftp-server`)
- Node.js 20+
- Chromium system dependencies (see below)

## Setup

```bash
# Build the XFTP server binary (from repo root)
cabal build xftp-server

# Install JS dependencies
cd xftp-web
npm install

# Install Chromium for Playwright (browser tests)
npx playwright install chromium
```

If Chromium fails to launch due to missing system libraries, install them with:

```bash
# Requires root
npx playwright install-deps chromium
```

## Running tests

```bash
# Browser round-trip test (vitest + Playwright headless Chromium)
npm run test:browser -- --run

# Unit tests (Jest, Node.js)
npm test
```

The browser test automatically starts an `xftp-server` instance on port 7000 via `globalSetup`, using certs from `tests/fixtures/`.

## Build

```bash
npm run build
```

Output goes to `dist/`.
