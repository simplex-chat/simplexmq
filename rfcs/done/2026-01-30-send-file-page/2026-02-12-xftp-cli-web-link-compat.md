# CLI-Web Link Compatibility

## Problem

CLI and web clients are isolated: CLI outputs `.xftp` description files, web outputs
`https://host/#<encoded>` links. A file uploaded via one cannot be downloaded via the other.

## Solution Summary

Make CLI produce and consume web-compatible links so that:
- CLI `send` always outputs a web link (in addition to `.xftp` files)
- CLI `recv` accepts a web link URL as input (alternative to `.xftp` file path)
- Browser can download files uploaded by CLI and vice versa

The web page host is derived from the XFTP server address - the server that hosts the file
also hosts the download page. Making XFTP servers actually serve the web page is a separate
concern (not covered here), but the link format anticipates it.

The YAML file description format is already identical between CLI and web.
The only gap is the URI encoding layer: DEFLATE-raw compression + base64url + URL structure.

## Current State

### Web link format

```
https://<xftp-server-host>/#<base64url(deflateRaw(YAML))>
```

Encoding chain (agent.ts:64-68):
1. `encodeFileDescription(fd)` -> YAML string
2. `TextEncoder.encode(yaml)` -> bytes
3. `pako.deflateRaw(bytes)` -> compressed
4. `base64urlEncode(compressed)` -> URI fragment (no `#`)

For multi-chunk files exceeding ~400 chars in URI, a redirect description is uploaded:
the real file description is encrypted, uploaded as a separate XFTP file, and a smaller
"redirect" description (pointing to it) is put in the URI.

### CLI file format

```
xftp send FILE -> writes rcv1.xftp (raw YAML), snd.xftp.private
xftp recv FILE.xftp -> reads raw YAML from file
```

No URI support. No compression. No redirect descriptions.

### Existing Haskell `FileDescriptionURI`

`Description.hs:243-266` defines a `simplex:/file#/?desc=<URL-encoded raw YAML>` format.
This is the SimpleX Chat app format - NOT the web page format. It uses URL-encoded raw YAML
(no DEFLATE compression), and has a different URL structure.

## Detailed Tech Design

### 1. File Header (Filename) Compatibility

The filename is carried **inside the encrypted file data**, not in the file description YAML.
Both CLI and web use the same `FileHeader` structure and binary encoding - full interop.

#### FileHeader type

Haskell (`Types.hs:36-46`):
```haskell
data FileHeader = FileHeader { fileName :: Text, fileExtra :: Maybe Text }
instance Encoding FileHeader where
  smpEncode FileHeader {fileName, fileExtra} = smpEncode (fileName, fileExtra)
```

TypeScript (`crypto/file.ts:11-24`):
```typescript
interface FileHeader { fileName: string; fileExtra: string | null }
function encodeFileHeader(hdr: FileHeader): Uint8Array {
  return concatBytes(encodeString(hdr.fileName), encodeMaybe(encodeString, hdr.fileExtra))
}
```

Both produce identical binary: `[1-byte UTF-8 length][fileName bytes]['0']` (for null fileExtra).
Max filename: 255 UTF-8 bytes (1-byte length prefix).

#### Encrypted file structure

Both CLI and web produce the same encrypted stream:
```
XSalsa20-Poly1305 encrypted:
  [8-byte Int64 fileSize] [FileHeader] [file content] ['#' padding]
  + [16-byte auth tag]

Where fileSize = len(FileHeader) + len(file content)
```

The 8-byte length prefix and padding are handled identically:
- Haskell: `Crypto.hs:43-56` (`encryptFile`) / `Crypto.hs:81-87` (`decryptFirstChunk`)
- TypeScript: `crypto/file.ts:51-70` (`encryptFile`) / `crypto/file.ts:81-94` (`decryptChunks`)

On decryption, `unPadLazy`/`splitLen` strips the 8-byte length prefix, then `parseFileHeader`
extracts the filename from the remaining decrypted bytes (up to 1024 bytes examined, both sides).

#### CLI upload: sets real filename (ok)

`Client/Main.hs:246-247,273`:
```haskell
let (_, fileNameStr) = splitFileName filePath
    fileName = T.pack fileNameStr
...
    fileHdr = smpEncode FileHeader {fileName, fileExtra = Nothing}
```

Extracts the actual filename from the path and embeds it in the encrypted header.

#### CLI download: uses filename from header (ok)

`Crypto.hs:62-66` (single chunk) / `Crypto.hs:72-74` (multi-chunk):
```haskell
(FileHeader {fileName}, rest) <- parseFileHeader decryptedContent
destFile <- withExceptT FTCEFileIOError $ getDestFile fileName
```

`Client/Main.hs:435-441` (`getFilePath`):
- If output dir specified: saves to `<dir>/<fileName>`
- If no dir: saves to `~/Downloads/<fileName>`

The filename from the decrypted header determines the output file name.

#### Web upload: sets real filename (ok)

`upload.ts:121` -> `agent.ts:86`:
```typescript
const fileHdr = encodeFileHeader({fileName, fileExtra: null})
```

Where `fileName` comes from `file.name` (browser File API).

#### Web download: uses filename from header (ok)

`download.ts:97,102`:
```typescript
const fileName = sanitizeFileName(header.fileName)
a.download = encodeURIComponent(fileName)
```

The web client additionally sanitizes the filename (strips path separators, control chars,
bidi overrides, limits to 255 chars).

#### Web redirect description: empty filename (correct)

`agent.ts:193`: `encryptFileForUpload(yamlBytes, "")` - redirect descriptions use empty filename
because they are internal artifacts, not user files. This is handled correctly on both sides:
the redirect content is decrypted and parsed as YAML, not saved as a file.

#### Cross-client interop: fully compatible (ok)

| Scenario | Filename flow | Status |
|----------|--------------|--------|
| CLI upload -> CLI download | `splitFileName` -> header -> `getDestFile` | Works |
| Web upload -> Web download | `File.name` -> header -> `sanitizeFileName` | Works |
| CLI upload -> Web download | `splitFileName` -> header -> `sanitizeFileName` | **Compatible** |
| Web upload -> CLI download | `File.name` -> header -> `getDestFile` | **Compatible** |

The binary encoding is identical (smpEncode). No changes needed for filename interop.
The CLI should consider adding filename sanitization similar to the web client for safety.

### 2. Web Link Host Derivation

The web page URL domain comes from the XFTP server address, not from a CLI flag:

- **Non-redirected description**: use the server host of the first chunk's first replica.
  E.g., `xftp://abc=@xftp1.simplex.im` -> `https://xftp1.simplex.im/#<encoded>`

- **Redirected description**: use the server host of the redirect chunk (the outer description's
  chunk that stores the encrypted inner description).

The server address format is `xftp://<keyhash>@<host>[,<host2>,...][:<port>]`.
The web link uses `https://<host>` (port 443 implied).

This means the CLI does not need a `--web-url` flag - the server address fully determines
the link. The XFTP server serving the web page is a separate deployment concern.

### 3. Web URI Encoding/Decoding in Haskell

Add two functions (new module or in `Description.hs`):

```haskell
-- Encode file description as web URI fragment (no leading #)
encodeWebURI :: FileDescription 'FRecipient -> ByteString
-- 1. Y.encode . encodeFileDescription -> YAML bytes
-- 2. deflateRaw (raw DEFLATE, no zlib/gzip header) via zlib package
-- 3. base64url encode (with padding, matching Data.ByteString.Base64.URL)

-- Decode web URI fragment (no leading #) to file description
decodeWebURI :: ByteString -> Either String (ValidFileDescription 'FRecipient)
-- 1. base64url decode
-- 2. inflateRaw (raw DEFLATE decompress)
-- 3. Y.decodeEither' -> YAMLFileDescription -> FileDescription
-- 4. validateFileDescription

-- Build full web link from file description
-- Extracts server host from first chunk replica (or redirect chunk)
fileWebLink :: FileDescription 'FRecipient -> (String, ByteString)
-- Returns (webHost, uriFragment)
-- Caller assembles: "https://" <> webHost <> "/#" <> uriFragment
```

**Dependency**: Add `zlib` to `simplexmq.cabal` (for raw DEFLATE).
The codebase already has `zstd` for message compression - `zlib` is standard and small.

The `zlib` Haskell package provides `Codec.Compression.Zlib.Raw` for raw DEFLATE
(no header/trailer), matching `pako.deflateRaw()` / `pako.inflateRaw()`.

### 4. Redirect Description Support

The CLI currently does NOT create redirect descriptions. For single-server single-recipient
uploads, most file descriptions fit in a reasonable URI even for multi-chunk files. But for
large files (many chunks x long server hostnames), the URI can exceed practical limits.

**Approach**: Match the web client threshold.
- After encoding the URI, if `length > 400` and chunks > 1, upload a redirect description.
- The redirect upload uses the same XFTP upload flow: encrypt YAML -> upload as file -> create
  outer description pointing to it.
- This matches `agent.ts:152-155` exactly.
- The redirect chunk's server becomes the web link host.

For CLI download from a redirect URI, the existing `cliReceiveFile` needs extension:
- After decoding the file description, check `redirect` field.
- If present: download and decrypt the redirect chunks first to get the inner description,
  then download the actual file using the inner description.
- The web client already does this (`resolveRedirect` in agent.ts:320-346).

### 5. CLI Command Changes

#### `xftp send` - always output web link

```
xftp send FILE [DIR] [-n COUNT] [-s SERVERS]
```

- Upload file as usual
- Generate web link: `https://<server-host>/#<encodeWebURI(rcvDescription)>`
- If URI exceeds threshold, upload redirect description first
- Print web link to stdout (in addition to `.xftp` file paths)
- Only generates link for the first recipient (web links are single-recipient)

**Output change**:
```
Sender file description: ./file.xftp/snd.xftp.private
Pass file descriptions to the recipient(s):
./file.xftp/rcv1.xftp

Web link:
https://xftp1.simplex.im/#eJy0VduO2zYQ...
```

#### `xftp recv` - accept URL as input

```
xftp recv <FILE.xftp | URL> [DIR]
```

- If input starts with `http://` or `https://`, extract hash fragment after `#`
- Decode: base64url -> inflateRaw -> YAML -> FileDescription
- Resolve redirect if present
- Download and decrypt as usual

The URL must be quoted on the command line (`"https://...#..."`) because `#` is a shell
comment character when unquoted.

Implementation: modify `receiveP` parser to accept URL, add `decodeWebURI` path in
`cliReceiveFile` alongside existing `getFileDescription'`.

### 6. YAML Format Compatibility

Already identical. The web `description.ts` explicitly matches Haskell `Data.Yaml` output:
- Same field names (alphabetical key order)
- Same base64url encoding for binary fields (with `=` padding)
- Same server replica colon-delimited format: `chunkNo:replicaId:replicaKey[:digest][:chunkSize]`
- Same size encoding (`kb`/`mb`/`gb` suffixes)
- Same redirect structure

**Verification**: The Playwright test suite already tests upload->download round-trips.
Adding a cross-client test (CLI upload -> web download, or web upload -> CLI download) would
validate interop end-to-end.

### 7. Server Compatibility

No server changes needed. Both clients use the same XFTP protocol (FGET, FPUT, FNEW, FACK, FDEL).
The web client adds `xftp-web-hello: 1` header for the hello handshake, but the actual file
operations are identical wire-format.

The only consideration: CLI uses native HTTP/2 (via `http2` Haskell package), web uses
browser `fetch()` API over HTTP/2. Both produce identical XFTP protocol frames.

**Note**: Making XFTP servers actually serve the web download page at `https://<host>/` is a
separate deployment/infrastructure task. This plan only establishes the link format convention
so that links are ready to work once servers serve the page.

## Implementation Plan

### Phase 1: Web URI codec in Haskell

1. Add `zlib` dependency to `simplexmq.cabal`
2. Add `encodeWebURI` / `decodeWebURI` / `fileWebLink` to `Simplex.FileTransfer.Description`
   (or a new `Simplex.FileTransfer.Description.WebURI` module)
3. `fileWebLink` extracts host from first chunk's first replica server address
4. Add unit tests: encode a known FileDescription, verify output matches web client encoding
5. Add round-trip test: encode -> decode -> compare

### Phase 2: CLI `recv` accepts URL

1. Modify `ReceiveOptions` to accept `Either FilePath WebURL` for `fileDescription`
2. In `cliReceiveFile`: if URL, extract fragment after `#`, call `decodeWebURI`
3. Add redirect resolution: if `redirect /= Nothing`, download redirect chunks,
   decrypt, parse inner description, then proceed with download
4. Test: upload via web page -> copy link -> `xftp recv <link>`

### Phase 3: CLI `send` outputs web link

1. After upload, call `fileWebLink` to get (host, fragment)
2. If fragment exceeds threshold, upload redirect description first, rebuild link
3. Print `https://<host>/#<fragment>` to stdout
4. Test: `xftp send FILE` -> open link in browser -> download

### Phase 4: Cross-client integration test

1. Add test: CLI send -> extract link from stdout -> Playwright browser download -> verify
2. Add test: Playwright browser upload -> extract link -> CLI recv -> verify
3. These can be shell-script or Haskell test-suite tests that spawn both clients
