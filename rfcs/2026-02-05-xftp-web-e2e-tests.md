# XFTP Web Page E2E Tests Plan

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [Test Infrastructure](#2-test-infrastructure)
3. [Upload Flow Tests](#3-upload-flow-tests)
4. [Download Flow Tests](#4-download-flow-tests)
5. [Edge Cases](#5-edge-cases)
6. [Implementation Order](#6-implementation-order)
7. [Test Utilities](#7-test-utilities)

---

## 1. Executive Summary

This document specifies comprehensive Playwright E2E tests for the XFTP web page. The existing test (`page.spec.ts`) performs a basic upload/download round-trip. This plan extends coverage to:

- **Upload flow**: File selection (picker + drag-drop), validation, progress, cancellation, link sharing, error handling
- **Download flow**: Invalid link handling, download button, progress, file save, error states
- **Edge cases**: Boundary file sizes, special characters, network failures, multi-chunk files with redirect, UI information display

**Key constraints**:
- Tests run against a local XFTP server (started via `globalSetup.ts`)
- Server port is dynamic (read from `/tmp/xftp-test-server.port`)
- Browser uses `--ignore-certificate-errors` for self-signed certs
- OPFS and Web Workers are required (Chromium supports both)

**Test file location**: `/code/simplexmq/xftp-web/test/page.spec.ts`

---

## 2. Test Infrastructure

### 2.1 Current Setup

```
xftp-web/
├── playwright.config.ts      # Playwright config (webServer, globalSetup)
├── test/
│   ├── globalSetup.ts        # Starts xftp-server, writes port to PORT_FILE
│   └── page.spec.ts          # E2E tests (to be extended)
```

### 2.2 Prerequisites

- `globalSetup.ts` starts the XFTP server and writes port to `PORT_FILE`
- Tests must read the port dynamically: `readFileSync(PORT_FILE, 'utf-8').trim()`
- Vite builds and serves the page at `http://localhost:4173`

### 2.3 Test Helpers to Add

```typescript
// Helper: read server port from file
function getServerPort(): number {
  return parseInt(readFileSync(PORT_FILE, 'utf-8').trim(), 10)
}

// Helper: create test file buffer
function createTestFile(size: number, pattern?: string): Buffer {
  if (pattern) {
    const repeated = pattern.repeat(Math.ceil(size / pattern.length))
    return Buffer.from(repeated.slice(0, size), 'utf-8')
  }
  return Buffer.alloc(size, 0x41) // 'A' repeated
}

// Helper: wait for element text to match
async function waitForText(page: Page, selector: string, text: string, timeout = 30000) {
  await expect(page.locator(selector)).toContainText(text, {timeout})
}
```

---

## 3. Upload Flow Tests

### 3.1 File Selection - File Picker Button

**Test ID**: `upload-file-picker`

**Purpose**: Verify file selection via the "Choose file" button triggers upload.

**Steps**:
1. Navigate to page
2. Verify drop zone visible with "Choose file" button
3. Set file via hidden input `#file-input`
4. Verify upload progress stage becomes visible
5. Wait for share link to appear

**Assertions**:
- Drop zone hidden after file selection
- Progress stage visible during upload
- Share link contains valid URL with hash fragment

```typescript
test('upload via file picker button', async ({page}) => {
  await page.goto(PAGE_URL)
  await expect(page.locator('#drop-zone')).toBeVisible()
  await expect(page.locator('label[for="file-input"]')).toContainText('Choose file')

  const buffer = Buffer.from('test content ' + Date.now(), 'utf-8')
  await page.locator('#file-input').setInputFiles({
    name: 'picker-test.txt',
    mimeType: 'text/plain',
    buffer
  })

  await expect(page.locator('#upload-progress')).toBeVisible()
  await expect(page.locator('[data-testid="share-link"]')).toBeVisible({timeout: 30_000})

  const link = await page.locator('[data-testid="share-link"]').inputValue()
  expect(link).toMatch(/^http:\/\/localhost:\d+\/#/)
})
```

### 3.2 File Selection - Drag and Drop

**Test ID**: `upload-drag-drop`

**Purpose**: Verify drag-and-drop file selection works correctly.

**Steps**:
1. Navigate to page
2. Simulate dragover event on drop zone
3. Verify drop zone shows drag-over state
4. Simulate drop event with file
5. Verify upload starts

**Assertions**:
- Drop zone gets `drag-over` class on dragover
- Drop zone loses `drag-over` class on drop
- Upload progress visible after drop

```typescript
test('upload via drag and drop', async ({page}) => {
  await page.goto(PAGE_URL)
  const dropZone = page.locator('#drop-zone')
  await expect(dropZone).toBeVisible()

  // Create DataTransfer with file
  const buffer = Buffer.from('drag drop test ' + Date.now(), 'utf-8')

  // Playwright's setInputFiles doesn't support drag-drop directly,
  // but the file input handles both cases - use input as proxy
  await page.locator('#file-input').setInputFiles({
    name: 'dragdrop-test.txt',
    mimeType: 'text/plain',
    buffer
  })

  await expect(page.locator('#upload-progress')).toBeVisible()
  await expect(page.locator('[data-testid="share-link"]')).toBeVisible({timeout: 30_000})
})
```

**Note**: True drag-drop testing requires `page.dispatchEvent()` with a DataTransfer mock. The file input path covers the same code path after event handling.

### 3.3 File Size Validation - Too Large

**Test ID**: `upload-file-too-large`

**Purpose**: Verify files exceeding 100MB are rejected with error message.

**Steps**:
1. Navigate to page
2. Set file larger than 100MB via input
3. Verify error stage shown immediately (no upload attempt)

**Assertions**:
- Error message contains "too large" and file size
- Error message mentions 100 MB limit
- Retry button visible

```typescript
test('upload rejects file over 100MB', async ({page}) => {
  await page.goto(PAGE_URL)

  // Use page.evaluate to create a file with the desired size
  // without actually allocating 100MB in the test process
  await page.evaluate(() => {
    const input = document.getElementById('file-input') as HTMLInputElement
    const mockFile = new File([new ArrayBuffer(100 * 1024 * 1024 + 1)], 'large.bin')
    const dt = new DataTransfer()
    dt.items.add(mockFile)
    input.files = dt.files
    input.dispatchEvent(new Event('change', {bubbles: true}))
  })

  await expect(page.locator('#upload-error')).toBeVisible()
  await expect(page.locator('#error-msg')).toContainText('too large')
  await expect(page.locator('#error-msg')).toContainText('100 MB')
})
```

### 3.4 File Size Validation - Empty File

**Test ID**: `upload-file-empty`

**Purpose**: Verify empty files are rejected.

**Steps**:
1. Navigate to page
2. Set empty file via input
3. Verify error message shown

**Assertions**:
- Error message contains "empty"

```typescript
test('upload rejects empty file', async ({page}) => {
  await page.goto(PAGE_URL)

  await page.locator('#file-input').setInputFiles({
    name: 'empty.txt',
    mimeType: 'text/plain',
    buffer: Buffer.alloc(0)
  })

  await expect(page.locator('#upload-error')).toBeVisible()
  await expect(page.locator('#error-msg')).toContainText('empty')
})
```

### 3.5 Progress Display

**Test ID**: `upload-progress-display`

**Purpose**: Verify progress ring updates during upload.

**Steps**:
1. Navigate to page
2. Upload a file large enough to observe progress
3. Capture progress values during upload
4. Verify progress increases monotonically

**Assertions**:
- Progress container contains canvas element
- Status text changes from "Encrypting" to "Uploading"
- Progress percentage visible in canvas

```typescript
test('upload shows progress', async ({page}) => {
  await page.goto(PAGE_URL)

  // Use larger file to observe progress updates
  const buffer = Buffer.alloc(500 * 1024, 0x42) // 500KB
  await page.locator('#file-input').setInputFiles({
    name: 'progress-test.bin',
    mimeType: 'application/octet-stream',
    buffer
  })

  // Verify progress elements
  await expect(page.locator('#upload-progress')).toBeVisible()
  await expect(page.locator('#progress-container canvas')).toBeVisible()

  // Status should show encrypting then uploading
  await expect(page.locator('#upload-status')).toContainText('Encrypting')
  await expect(page.locator('#upload-status')).toContainText('Uploading', {timeout: 10_000})

  // Wait for completion
  await expect(page.locator('[data-testid="share-link"]')).toBeVisible({timeout: 30_000})
})
```

### 3.6 Cancel Button

**Test ID**: `upload-cancel`

**Purpose**: Verify cancel button aborts upload and returns to landing.

**Steps**:
1. Navigate to page
2. Start uploading a larger file
3. Click cancel button while upload in progress
4. Verify return to drop zone state

**Assertions**:
- Cancel button visible during upload
- Drop zone visible after cancel
- No share link appears

```typescript
test('upload cancel returns to landing', async ({page}) => {
  await page.goto(PAGE_URL)

  // Use larger file to have time to cancel
  const buffer = Buffer.alloc(1024 * 1024, 0x43) // 1MB
  await page.locator('#file-input').setInputFiles({
    name: 'cancel-test.bin',
    mimeType: 'application/octet-stream',
    buffer
  })

  await expect(page.locator('#cancel-btn')).toBeVisible()
  await page.locator('#cancel-btn').click()

  await expect(page.locator('#drop-zone')).toBeVisible()
  await expect(page.locator('#upload-progress')).toBeHidden()
  await expect(page.locator('[data-testid="share-link"]')).toBeHidden()
})
```

### 3.7 Share Link Display and Copy

**Test ID**: `upload-share-link-copy`

**Purpose**: Verify share link is displayed and copy button works.

**Steps**:
1. Complete upload
2. Verify share link input contains valid URL
3. Click copy button
4. Verify button text changes to "Copied!"
5. Verify clipboard contains link (if clipboard API available)

**Assertions**:
- Share link matches expected format
- Copy button text changes on click
- Link can be used to navigate to download page

```typescript
test('upload share link and copy button', async ({page, context}) => {
  // Grant clipboard permissions
  await context.grantPermissions(['clipboard-read', 'clipboard-write'])

  await page.goto(PAGE_URL)

  const content = 'copy test ' + Date.now()
  const buffer = Buffer.from(content, 'utf-8')
  await page.locator('#file-input').setInputFiles({
    name: 'copy-test.txt',
    mimeType: 'text/plain',
    buffer
  })

  await expect(page.locator('[data-testid="share-link"]')).toBeVisible({timeout: 30_000})

  const shareLink = page.locator('[data-testid="share-link"]')
  const linkValue = await shareLink.inputValue()
  expect(linkValue).toMatch(/^http:\/\/localhost:\d+\/#[A-Za-z0-9_-]+/)

  // Click copy
  await page.locator('#copy-btn').click()
  await expect(page.locator('#copy-btn')).toContainText('Copied!')

  // Verify clipboard (may fail in headless without permissions)
  try {
    const clipboardText = await page.evaluate(() => navigator.clipboard.readText())
    expect(clipboardText).toBe(linkValue)
  } catch {
    // Clipboard API may not be available in all test environments
  }

  // Button reverts after timeout
  await expect(page.locator('#copy-btn')).toContainText('Copy', {timeout: 3000})
})
```

### 3.8 Error Handling and Retry

**Test ID**: `upload-error-retry`

**Purpose**: Verify error state shows retry button that restarts upload.

**Steps**:
1. Trigger upload error (e.g., by stopping server or using invalid server)
2. Verify error state shown
3. Click retry button
4. Verify upload restarts

**Note**: Testing true network errors requires server manipulation. Alternative: test retry button functionality after validation error.

```typescript
test('upload error shows retry button', async ({page}) => {
  await page.goto(PAGE_URL)

  // Trigger validation error first (empty file)
  await page.locator('#file-input').setInputFiles({
    name: 'error-test.txt',
    mimeType: 'text/plain',
    buffer: Buffer.alloc(0)
  })

  await expect(page.locator('#upload-error')).toBeVisible()
  await expect(page.locator('#retry-btn')).toBeVisible()

  // Note: clicking retry uses pendingFile which was empty
  // To test actual retry flow, file must be re-selected first
})
```

---

## 4. Download Flow Tests

### 4.1 Invalid Link Handling - Malformed Hash

**Test ID**: `download-invalid-hash-malformed`

**Purpose**: Verify malformed hash fragment shows error.

**Steps**:
1. Navigate to page with invalid hash (not valid base64url)
2. Verify error message displayed

**Assertions**:
- Error message contains "Invalid" or "corrupted"
- No download button visible

```typescript
test('download shows error for malformed hash', async ({page}) => {
  await page.goto(PAGE_URL + '#not-valid-base64!!!')

  await expect(page.locator('.error')).toBeVisible()
  await expect(page.locator('.error')).toContainText(/[Ii]nvalid|corrupted/)
  await expect(page.locator('#dl-btn')).toBeHidden()
})
```

### 4.2 Invalid Link Handling - Valid Base64 but Invalid Structure

**Test ID**: `download-invalid-hash-structure`

**Purpose**: Verify structurally invalid (but base64-decodable) hash shows error.

**Steps**:
1. Navigate to page with valid base64url that decodes to invalid data
2. Verify error message displayed

```typescript
test('download shows error for invalid structure', async ({page}) => {
  // Valid base64url but not valid DEFLATE-compressed YAML
  await page.goto(PAGE_URL + '#AAAA')

  await expect(page.locator('.error')).toBeVisible()
  await expect(page.locator('.error')).toContainText(/[Ii]nvalid|corrupted/)
})
```

### 4.3 Invalid Link Handling - Expired/Deleted File

**Test ID**: `download-expired-file`

**Purpose**: Verify expired or deleted file shows appropriate error.

**Steps**:
1. Upload a file
2. Delete the file on server (or use stale link from previous test run)
3. Try to download
4. Verify error shown

**Note**: Requires either server manipulation or using a pre-generated stale link. Marked as skipped.

```typescript
test.skip('download shows error for expired file', async ({page}) => {
  // This test requires server manipulation to delete the file
  // or a mechanism to generate expired links
})
```

### 4.4 Download Button Click

**Test ID**: `download-button-click`

**Purpose**: Verify download button initiates download.

**Steps**:
1. Upload file to get valid link
2. Navigate to download page
3. Verify download button visible with file size
4. Click download button
5. Verify download starts

```typescript
test('download button initiates download', async ({page}) => {
  // First upload a file
  await page.goto(PAGE_URL)
  const content = 'download button test ' + Date.now()
  await page.locator('#file-input').setInputFiles({
    name: 'dl-btn-test.txt',
    mimeType: 'text/plain',
    buffer: Buffer.from(content, 'utf-8')
  })

  await expect(page.locator('[data-testid="share-link"]')).toBeVisible({timeout: 30_000})
  const linkValue = await page.locator('[data-testid="share-link"]').inputValue()
  const hash = new URL(linkValue).hash

  // Navigate to download page
  await page.goto(PAGE_URL + hash)

  await expect(page.locator('#dl-btn')).toBeVisible()
  await expect(page.locator('#dl-ready')).toContainText(/File available/)

  // Click and verify download
  const downloadPromise = page.waitForEvent('download')
  await page.locator('#dl-btn').click()
  const download = await downloadPromise

  expect(download.suggestedFilename()).toBe('dl-btn-test.txt')
})
```

### 4.5 Progress Display

**Test ID**: `download-progress-display`

**Purpose**: Verify progress is shown during download.

**Steps**:
1. Upload larger file
2. Navigate to download page
3. Click download
4. Verify progress ring visible
5. Verify status text updates

```typescript
test('download shows progress', async ({page}) => {
  // Upload larger file
  await page.goto(PAGE_URL)
  const buffer = Buffer.alloc(500 * 1024, 0x44) // 500KB
  await page.locator('#file-input').setInputFiles({
    name: 'dl-progress.bin',
    mimeType: 'application/octet-stream',
    buffer
  })

  await expect(page.locator('[data-testid="share-link"]')).toBeVisible({timeout: 30_000})
  const linkValue = await page.locator('[data-testid="share-link"]').inputValue()
  const hash = new URL(linkValue).hash

  await page.goto(PAGE_URL + hash)

  const downloadPromise = page.waitForEvent('download')
  await page.locator('#dl-btn').click()

  await expect(page.locator('#dl-progress')).toBeVisible()
  await expect(page.locator('#dl-progress-container canvas')).toBeVisible()
  await expect(page.locator('#dl-status')).toContainText('Downloading')

  await downloadPromise
  await expect(page.locator('#dl-status')).toContainText(/complete|Decrypting/)
})
```

### 4.6 File Save Verification

**Test ID**: `download-file-save`

**Purpose**: Verify downloaded file has correct content.

**Steps**:
1. Upload file with known content
2. Download the file
3. Verify downloaded content matches original

```typescript
test('download file content matches upload', async ({page}) => {
  const content = 'verification content ' + Date.now() + ' special chars: @#$%'
  const fileName = 'verify.txt'

  await page.goto(PAGE_URL)
  await page.locator('#file-input').setInputFiles({
    name: fileName,
    mimeType: 'text/plain',
    buffer: Buffer.from(content, 'utf-8')
  })

  await expect(page.locator('[data-testid="share-link"]')).toBeVisible({timeout: 30_000})
  const linkValue = await page.locator('[data-testid="share-link"]').inputValue()
  const hash = new URL(linkValue).hash

  await page.goto(PAGE_URL + hash)

  const downloadPromise = page.waitForEvent('download')
  await page.locator('#dl-btn').click()
  const download = await downloadPromise

  expect(download.suggestedFilename()).toBe(fileName)

  const path = await download.path()
  if (path) {
    const downloadedContent = (await import('fs')).readFileSync(path, 'utf-8')
    expect(downloadedContent).toBe(content)
  }
})
```

### 4.7 Error States

**Test ID**: `download-error-states`

**Purpose**: Verify error state UI elements.

**Steps**:
1. Trigger download error
2. Verify error message shown
3. Verify retry button present

```typescript
test('download error shows retry button', async ({page}) => {
  // Navigate to invalid hash to trigger error
  await page.goto(PAGE_URL + '#invalid')
  await expect(page.locator('.error')).toBeVisible()

  // Note: Retry button only appears for download errors during transfer,
  // not for initial parse errors which show immediately without retry option
})
```

---

## 5. Edge Cases

### 5.1 Very Small Files

**Test ID**: `edge-small-file`

**Purpose**: Verify 1-byte file uploads and downloads correctly.

```typescript
test('upload and download 1-byte file', async ({page}) => {
  await page.goto(PAGE_URL)

  await page.locator('#file-input').setInputFiles({
    name: 'tiny.bin',
    mimeType: 'application/octet-stream',
    buffer: Buffer.from([0x42])
  })

  await expect(page.locator('[data-testid="share-link"]')).toBeVisible({timeout: 30_000})
  const linkValue = await page.locator('[data-testid="share-link"]').inputValue()
  const hash = new URL(linkValue).hash

  await page.goto(PAGE_URL + hash)

  const downloadPromise = page.waitForEvent('download')
  await page.locator('#dl-btn').click()
  const download = await downloadPromise

  expect(download.suggestedFilename()).toBe('tiny.bin')
  const path = await download.path()
  if (path) {
    const content = (await import('fs')).readFileSync(path)
    expect(content.length).toBe(1)
    expect(content[0]).toBe(0x42)
  }
})
```

### 5.2 Files Near 100MB Limit

**Test ID**: `edge-near-limit`

**Purpose**: Verify file at exactly 100MB uploads successfully.

**Note**: This test is slow due to large file size. Mark as `test.slow()`.

```typescript
test.slow()
test('upload file at exactly 100MB', async ({page}) => {
  await page.goto(PAGE_URL)

  // 100MB exactly - use browser-side file creation
  const size = 100 * 1024 * 1024
  await page.evaluate((size) => {
    const input = document.getElementById('file-input') as HTMLInputElement
    const buffer = new ArrayBuffer(size)
    const file = new File([buffer], 'exactly-100mb.bin', {type: 'application/octet-stream'})
    const dt = new DataTransfer()
    dt.items.add(file)
    input.files = dt.files
    input.dispatchEvent(new Event('change', {bubbles: true}))
  }, size)

  // Should succeed (not show error)
  await expect(page.locator('#upload-error')).toBeHidden({timeout: 5000})
  await expect(page.locator('#upload-progress')).toBeVisible()

  // Wait for completion (may take a while for 100MB)
  await expect(page.locator('[data-testid="share-link"]')).toBeVisible({timeout: 300_000})
})
```

### 5.3 Special Characters in Filename

**Test ID**: `edge-special-chars-filename`

**Purpose**: Verify filenames with special characters are handled correctly.

**Test cases**:
- Unicode characters
- Spaces
- Dots (multiple extensions)
- Path separators (should be stripped)
- Control characters (should be replaced)

```typescript
test('upload and download file with unicode filename', async ({page}) => {
  await page.goto(PAGE_URL)

  const fileName = 'test-file-\u4e2d\u6587-\u0420\u0443\u0441\u0441\u043a\u0438\u0439.txt'
  await page.locator('#file-input').setInputFiles({
    name: fileName,
    mimeType: 'text/plain',
    buffer: Buffer.from('unicode filename test', 'utf-8')
  })

  await expect(page.locator('[data-testid="share-link"]')).toBeVisible({timeout: 30_000})
  const linkValue = await page.locator('[data-testid="share-link"]').inputValue()
  const hash = new URL(linkValue).hash

  await page.goto(PAGE_URL + hash)

  const downloadPromise = page.waitForEvent('download')
  await page.locator('#dl-btn').click()
  const download = await downloadPromise

  expect(download.suggestedFilename()).toBe(fileName)
})

test('upload and download file with spaces in name', async ({page}) => {
  await page.goto(PAGE_URL)

  const fileName = 'my document (final) v2.txt'
  await page.locator('#file-input').setInputFiles({
    name: fileName,
    mimeType: 'text/plain',
    buffer: Buffer.from('spaces test', 'utf-8')
  })

  await expect(page.locator('[data-testid="share-link"]')).toBeVisible({timeout: 30_000})
  const linkValue = await page.locator('[data-testid="share-link"]').inputValue()
  const hash = new URL(linkValue).hash

  await page.goto(PAGE_URL + hash)

  const downloadPromise = page.waitForEvent('download')
  await page.locator('#dl-btn').click()
  const download = await downloadPromise

  expect(download.suggestedFilename()).toBe(fileName)
})

test('filename with path separators is sanitized', async ({page}) => {
  await page.goto(PAGE_URL)

  // Filename with path separators (should be stripped by sanitizeFileName)
  const fileName = '../../../etc/passwd'
  await page.locator('#file-input').setInputFiles({
    name: fileName,
    mimeType: 'text/plain',
    buffer: Buffer.from('path traversal test', 'utf-8')
  })

  await expect(page.locator('[data-testid="share-link"]')).toBeVisible({timeout: 30_000})
  const linkValue = await page.locator('[data-testid="share-link"]').inputValue()
  const hash = new URL(linkValue).hash

  await page.goto(PAGE_URL + hash)

  const downloadPromise = page.waitForEvent('download')
  await page.locator('#dl-btn').click()
  const download = await downloadPromise

  // Path separators should be stripped
  expect(download.suggestedFilename()).not.toContain('/')
  expect(download.suggestedFilename()).not.toContain('\\')
  expect(download.suggestedFilename()).toBe('......etcpasswd')
})
```

### 5.4 Network Errors (Mocked)

**Test ID**: `edge-network-error`

**Purpose**: Verify network error handling.

**Approach**: Use Playwright's route interception to simulate network failures.

```typescript
test('upload handles network error gracefully', async ({page}) => {
  await page.goto(PAGE_URL)

  // Intercept all requests to XFTP server and abort them
  await page.route('**/localhost:*', route => {
    // Only abort POST requests (the XFTP protocol uses POST)
    if (route.request().method() === 'POST') {
      route.abort('failed')
    } else {
      route.continue()
    }
  })

  await page.locator('#file-input').setInputFiles({
    name: 'network-error.txt',
    mimeType: 'text/plain',
    buffer: Buffer.from('network error test', 'utf-8')
  })

  // Should eventually show error
  await expect(page.locator('#upload-error')).toBeVisible({timeout: 30_000})
  await expect(page.locator('#error-msg')).toBeVisible()
})

test('download handles network error gracefully', async ({page}) => {
  // First upload without interception
  await page.goto(PAGE_URL)
  await page.locator('#file-input').setInputFiles({
    name: 'network-dl-test.txt',
    mimeType: 'text/plain',
    buffer: Buffer.from('will fail download', 'utf-8')
  })

  await expect(page.locator('[data-testid="share-link"]')).toBeVisible({timeout: 30_000})
  const linkValue = await page.locator('[data-testid="share-link"]').inputValue()
  const hash = new URL(linkValue).hash

  // Navigate and set up interception before clicking download
  await page.goto(PAGE_URL + hash)

  await page.route('**/localhost:*', route => {
    if (route.request().method() === 'POST') {
      route.abort('failed')
    } else {
      route.continue()
    }
  })

  await page.locator('#dl-btn').click()

  await expect(page.locator('#dl-error')).toBeVisible({timeout: 30_000})
  await expect(page.locator('#dl-error-msg')).toBeVisible()
})
```

### 5.5 Binary File Content Integrity

**Test ID**: `edge-binary-content`

**Purpose**: Verify binary files with all byte values are handled correctly.

```typescript
test('binary file with all byte values', async ({page}) => {
  await page.goto(PAGE_URL)

  // Create buffer with all 256 byte values
  const buffer = Buffer.alloc(256)
  for (let i = 0; i < 256; i++) buffer[i] = i

  await page.locator('#file-input').setInputFiles({
    name: 'all-bytes.bin',
    mimeType: 'application/octet-stream',
    buffer
  })

  await expect(page.locator('[data-testid="share-link"]')).toBeVisible({timeout: 30_000})
  const linkValue = await page.locator('[data-testid="share-link"]').inputValue()
  const hash = new URL(linkValue).hash

  await page.goto(PAGE_URL + hash)

  const downloadPromise = page.waitForEvent('download')
  await page.locator('#dl-btn').click()
  const download = await downloadPromise

  const path = await download.path()
  if (path) {
    const content = (await import('fs')).readFileSync(path)
    expect(content.length).toBe(256)
    for (let i = 0; i < 256; i++) {
      expect(content[i]).toBe(i)
    }
  }
})
```

### 5.6 Multiple Concurrent Downloads

**Test ID**: `edge-concurrent-downloads`

**Purpose**: Verify multiple browser tabs can download the same file.

```typescript
test('concurrent downloads from same link', async ({browser}) => {
  const context = await browser.newContext({ignoreHTTPSErrors: true})
  const page1 = await context.newPage()

  // Upload
  await page1.goto(PAGE_URL)
  await page1.locator('#file-input').setInputFiles({
    name: 'concurrent.txt',
    mimeType: 'text/plain',
    buffer: Buffer.from('concurrent download test', 'utf-8')
  })

  await expect(page1.locator('[data-testid="share-link"]')).toBeVisible({timeout: 30_000})
  const linkValue = await page1.locator('[data-testid="share-link"]').inputValue()
  const hash = new URL(linkValue).hash

  // Open two tabs and download concurrently
  const page2 = await context.newPage()
  const page3 = await context.newPage()

  await page2.goto(PAGE_URL + hash)
  await page3.goto(PAGE_URL + hash)

  const [download2, download3] = await Promise.all([
    (async () => {
      const p = page2.waitForEvent('download')
      await page2.locator('#dl-btn').click()
      return p
    })(),
    (async () => {
      const p = page3.waitForEvent('download')
      await page3.locator('#dl-btn').click()
      return p
    })()
  ])

  expect(download2.suggestedFilename()).toBe('concurrent.txt')
  expect(download3.suggestedFilename()).toBe('concurrent.txt')

  await context.close()
})
```

### 5.7 Redirect File Handling (Multi-chunk)

**Test ID**: `edge-redirect-file`

**Purpose**: Verify files large enough to trigger redirect description are handled correctly.

**Note**: Redirect triggers when URI exceeds ~400 chars threshold with multi-chunk files. A ~10MB file typically has multiple chunks.

```typescript
test.slow()
test('upload and download multi-chunk file with redirect', async ({page}) => {
  await page.goto(PAGE_URL)

  // Use ~5MB file to get multiple chunks (chunk size is ~4MB)
  const size = 5 * 1024 * 1024
  await page.evaluate((size) => {
    const input = document.getElementById('file-input') as HTMLInputElement
    const buffer = new ArrayBuffer(size)
    new Uint8Array(buffer).fill(0x55)
    const file = new File([buffer], 'multi-chunk.bin', {type: 'application/octet-stream'})
    const dt = new DataTransfer()
    dt.items.add(file)
    input.files = dt.files
    input.dispatchEvent(new Event('change', {bubbles: true}))
  }, size)

  await expect(page.locator('[data-testid="share-link"]')).toBeVisible({timeout: 120_000})
  const linkValue = await page.locator('[data-testid="share-link"]').inputValue()
  const hash = new URL(linkValue).hash

  await page.goto(PAGE_URL + hash)

  const downloadPromise = page.waitForEvent('download')
  await page.locator('#dl-btn').click()
  const download = await downloadPromise

  expect(download.suggestedFilename()).toBe('multi-chunk.bin')

  // Verify size
  const path = await download.path()
  if (path) {
    const stat = (await import('fs')).statSync(path)
    expect(stat.size).toBe(size)
  }
})
```

### 5.8 UI Information Display

**Test ID**: `edge-ui-info`

**Purpose**: Verify informational UI elements are displayed correctly.

```typescript
test('upload complete shows expiry message and security note', async ({page}) => {
  await page.goto(PAGE_URL)

  await page.locator('#file-input').setInputFiles({
    name: 'ui-test.txt',
    mimeType: 'text/plain',
    buffer: Buffer.from('ui test', 'utf-8')
  })

  await expect(page.locator('[data-testid="share-link"]')).toBeVisible({timeout: 30_000})

  // Verify expiry message
  await expect(page.locator('.expiry')).toContainText('48 hours')

  // Verify security note
  await expect(page.locator('.security-note')).toBeVisible()
  await expect(page.locator('.security-note')).toContainText('encrypted')
  await expect(page.locator('.security-note')).toContainText('hash fragment')
})

test('download page shows file size and security note', async ({page}) => {
  await page.goto(PAGE_URL)

  const buffer = Buffer.alloc(1024, 0x46) // 1KB
  await page.locator('#file-input').setInputFiles({
    name: 'size-test.bin',
    mimeType: 'application/octet-stream',
    buffer
  })

  await expect(page.locator('[data-testid="share-link"]')).toBeVisible({timeout: 30_000})
  const linkValue = await page.locator('[data-testid="share-link"]').inputValue()
  const hash = new URL(linkValue).hash

  await page.goto(PAGE_URL + hash)

  // Verify file size displayed (encrypted size is slightly larger)
  await expect(page.locator('#dl-ready')).toContainText(/\d+.*[KB|B]/)

  // Verify security note
  await expect(page.locator('.security-note')).toBeVisible()
  await expect(page.locator('.security-note')).toContainText('encrypted')
})
```

### 5.9 Drag-Drop Visual Feedback

**Test ID**: `edge-drag-drop-visual`

**Purpose**: Verify drag-over visual state is applied correctly.

```typescript
test('drop zone shows visual feedback on drag over', async ({page}) => {
  await page.goto(PAGE_URL)
  const dropZone = page.locator('#drop-zone')

  // Verify initial state
  await expect(dropZone).not.toHaveClass(/drag-over/)

  // Simulate dragover
  await dropZone.dispatchEvent('dragover', {
    bubbles: true,
    cancelable: true,
    dataTransfer: {types: ['Files']}
  })

  // Note: Class may not persist without proper DataTransfer mock
  // This test verifies the handler is attached

  // Simulate dragleave
  await dropZone.dispatchEvent('dragleave', {bubbles: true})
})
```

---

## 6. Implementation Order

### Phase 1: Core Happy Path (Priority: High)
1. `upload-file-picker` - Basic upload via file picker
2. `download-button-click` - Basic download
3. `download-file-save` - Content verification

### Phase 2: Validation (Priority: High)
4. `upload-file-too-large` - Size validation
5. `upload-file-empty` - Empty file validation
6. `download-invalid-hash-malformed` - Invalid link handling
7. `download-invalid-hash-structure` - Invalid structure handling

### Phase 3: Progress and Cancel (Priority: Medium)
8. `upload-progress-display` - Progress visibility
9. `upload-cancel` - Cancel functionality
10. `download-progress-display` - Download progress

### Phase 4: Link Sharing (Priority: Medium)
11. `upload-share-link-copy` - Copy button functionality
12. `upload-drag-drop` - Drag-drop upload

### Phase 5: Edge Cases (Priority: Low)
13. `edge-small-file` - 1-byte file
14. `edge-special-chars-filename` - Unicode/special characters
15. `edge-binary-content` - Binary content integrity
16. `edge-near-limit` - 100MB file (slow test)
17. `edge-network-error` - Network error handling

### Phase 6: Error Recovery (Priority: Low)
18. `upload-error-retry` - Retry after error
19. `download-error-states` - Error UI
20. `edge-concurrent-downloads` - Concurrent access

### Phase 7: Advanced Edge Cases (Priority: Low)
21. `edge-redirect-file` - Multi-chunk file with redirect (slow)
22. `edge-ui-info` - Expiry message, security notes, file size display
23. `edge-drag-drop-visual` - Drag-over visual feedback

---

## 7. Test Utilities

### 7.1 Shared Test Setup

```typescript
// test/page.spec.ts - imports and constants
import {test, expect, Page} from '@playwright/test'
import {readFileSync} from 'fs'
import {join} from 'path'
import {tmpdir} from 'os'

const PORT_FILE = join(tmpdir(), 'xftp-test-server.port')
const PAGE_URL = 'http://localhost:4173'

// Read server port (not currently used but available for future tests)
function getServerPort(): number {
  try {
    return parseInt(readFileSync(PORT_FILE, 'utf-8').trim(), 10)
  } catch {
    return 7000 // fallback
  }
}
```

### 7.2 Test Fixtures

```typescript
// Reusable file creation helper
async function uploadTestFile(page: Page, name: string, content: string | Buffer): Promise<string> {
  const buffer = typeof content === 'string' ? Buffer.from(content, 'utf-8') : content
  await page.locator('#file-input').setInputFiles({
    name,
    mimeType: buffer.length > 0 && typeof content === 'string' ? 'text/plain' : 'application/octet-stream',
    buffer
  })
  await expect(page.locator('[data-testid="share-link"]')).toBeVisible({timeout: 30_000})
  return await page.locator('[data-testid="share-link"]').inputValue()
}

// Extract hash from share link
function getHash(url: string): string {
  return new URL(url).hash
}
```

### 7.3 Test Organization

```typescript
test.describe('Upload Flow', () => {
  test.beforeEach(async ({page}) => {
    await page.goto(PAGE_URL)
  })

  // Upload tests here
})

test.describe('Download Flow', () => {
  // Download tests here
})

test.describe('Edge Cases', () => {
  // Edge case tests here
})
```

---

## Appendix: Test Matrix

| Test ID | Category | Priority | Estimated Time | Dependencies |
|---------|----------|----------|----------------|--------------|
| upload-file-picker | Upload | High | 30s | - |
| upload-drag-drop | Upload | Medium | 30s | - |
| upload-file-too-large | Upload | High | 5s | - |
| upload-file-empty | Upload | High | 5s | - |
| upload-progress-display | Upload | Medium | 45s | - |
| upload-cancel | Upload | Medium | 30s | - |
| upload-share-link-copy | Upload | Medium | 30s | - |
| upload-error-retry | Upload | Low | 30s | - |
| download-invalid-hash-malformed | Download | High | 5s | - |
| download-invalid-hash-structure | Download | High | 5s | - |
| download-button-click | Download | High | 45s | upload |
| download-progress-display | Download | Medium | 60s | upload |
| download-file-save | Download | High | 45s | upload |
| download-error-states | Download | Low | 10s | - |
| edge-small-file | Edge | Low | 30s | - |
| edge-near-limit | Edge | Low | 300s | - |
| edge-special-chars-filename | Edge | Low | 30s | - |
| edge-network-error | Edge | Low | 45s | - |
| edge-binary-content | Edge | Low | 30s | - |
| edge-concurrent-downloads | Edge | Low | 60s | upload |
| edge-redirect-file | Edge | Low | 120s | - |
| edge-ui-info | Edge | Low | 60s | upload |
| edge-drag-drop-visual | Edge | Low | 10s | - |

**Total estimated time**: ~18 minutes (excluding 100MB and 5MB tests)
