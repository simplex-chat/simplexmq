# xftp-web

Browser-compatible XFTP file transfer client in TypeScript.

## Installation

```bash
npm install xftp-web
```

## Usage

```typescript
import {
  XFTPAgent,
  parseXFTPServer,
  sendFile, receiveFile, deleteFile,
  XFTPRetriableError, XFTPPermanentError, isRetriable,
} from "xftp-web"

// Create agent (manages connections)
const agent = new XFTPAgent()

const servers = [
  parseXFTPServer("xftp://server1..."),
  parseXFTPServer("xftp://server2..."),
  parseXFTPServer("xftp://server3..."),
]

// Upload (from Uint8Array)
const {rcvDescriptions, sndDescription, uri} = await sendFile(
  agent, servers, fileBytes, "photo.jpg",
  {onProgress: (uploaded, total) => console.log(`${uploaded}/${total}`)}
)

// Upload (streaming — constant memory, no full-file buffer)
const file = inputEl.files[0]
const result = await sendFile(
  agent, servers, file.stream(), file.size, file.name,
  {onProgress: (uploaded, total) => console.log(`${uploaded}/${total}`)}
)

// Download
const {header, content} = await receiveFile(agent, uri, {
  onProgress: (downloaded, total) => console.log(`${downloaded}/${total}`)
})

// Delete (requires sender description from upload)
await deleteFile(agent, sndDescription)

// Cleanup
agent.close()
```

### Advanced usage

For streaming encryption (avoids buffering the full encrypted file) or worker-based uploads:

```typescript
import {
  encryptFileForUpload, uploadFile, downloadFile,
  decodeDescriptionURI,
} from "xftp-web"

// Streaming encryption — encrypted slices emitted via callback
const metadata = await encryptFileForUpload(fileBytes, "photo.jpg", {
  onSlice: (data) => { /* write to OPFS, IndexedDB, etc. */ },
  onProgress: (done, total) => {},
})
// metadata has {digest, key, nonce, chunkSizes} but no encData

// Upload with custom chunk reader (e.g. reading from OPFS)
const result = await uploadFile(agent, servers, metadata, {
  readChunk: (offset, size) => readFromStorage(offset, size),
})

// Download with FileDescription object
const fd = decodeDescriptionURI(uri)
const {header, content} = await downloadFile(agent, fd)
```

### Upload options

```typescript
await sendFile(agent, servers, fileBytes, "photo.jpg", {
  onProgress: (uploaded, total) => {},  // progress callback
  auth: basicAuthBytes,                 // BasicAuth for auth-required servers
  numRecipients: 3,                     // multiple independent download credentials (default: 1)
})
```

### Error handling

```typescript
try {
  await sendFile(agent, servers, fileBytes, "photo.jpg")
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
