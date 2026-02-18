# xftp-web

Browser-compatible XFTP file transfer client in TypeScript.

## Installation

```bash
npm install xftp-web
```

## Usage

```typescript
import {
  newXFTPAgent, closeXFTPAgent,
  parseXFTPServer,
  encryptFileForUpload, uploadFile, downloadFile, deleteFile,
  decodeDescriptionURI, encodeDescriptionURI,
  XFTPRetriableError, XFTPPermanentError, isRetriable,
} from "xftp-web"

// Create agent (manages connections)
const agent = newXFTPAgent()

// Upload — chunks are distributed randomly across servers
const servers = [
  parseXFTPServer("xftp://server1..."),
  parseXFTPServer("xftp://server2..."),
  parseXFTPServer("xftp://server3..."),
]
const encrypted = await encryptFileForUpload(fileBytes, "photo.jpg")
const {rcvDescriptions, sndDescription, uri} = await uploadFile(agent, servers, encrypted, {
  onProgress: (uploaded, total) => console.log(`${uploaded}/${total}`),
})

// Download (from URI or FileDescription)
const fd = decodeDescriptionURI(uri)
const {header, content} = await downloadFile(agent, fd)

// Delete (using sender description)
await deleteFile(agent, sndDescription)

// Cleanup
closeXFTPAgent(agent)
```

### Upload options

```typescript
await uploadFile(agent, servers, encrypted, {
  onProgress: (uploaded, total) => {},  // progress callback
  auth: basicAuthBytes,                 // BasicAuth for auth-required servers
  numRecipients: 3,                     // multiple independent download credentials (default: 1)
})
```

### Error handling

```typescript
try {
  await uploadFile(agent, servers, encrypted)
} catch (e) {
  if (e instanceof XFTPRetriableError) {
    // Network/timeout/session errors — safe to retry
  } else if (e instanceof XFTPPermanentError) {
    // AUTH, NO_FILE, BLOCKED, etc. — do not retry
  }
  // or use: isRetriable(e)
}
```

## Development

### Prerequisites

- Haskell toolchain with `cabal` (to build `xftp-server`)
- Node.js 20+

### Setup

```bash
# Build the XFTP server binary (from repo root)
cabal build xftp-server

# Install JS dependencies
cd xftp-web
npm install
```

### Running tests

```bash
npm run test
```

The `pretest` script automatically installs Chromium and sets up the libsodium symlink. The browser test starts an `xftp-server` instance on port 7000 via `globalSetup`.

If Chromium fails to launch due to missing system libraries:

```bash
# Requires root
npx playwright install-deps chromium
```

### Build

```bash
npm run build
```

Output goes to `dist/`.

## License

[AGPL-3.0-only](https://www.gnu.org/licenses/agpl-3.0.html)
