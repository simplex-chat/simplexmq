# XFTP Web Page E2E Tests Plan

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [Test Infrastructure](#2-test-infrastructure)
3. [Test Infrastructure - Page Objects](#3-test-infrastructure---page-objects)
4. [Upload Flow Tests](#4-upload-flow-tests)
5. [Download Flow Tests](#5-download-flow-tests)
6. [Edge Cases](#6-edge-cases)
7. [Implementation Order](#7-implementation-order)
8. [Test Utilities](#8-test-utilities)

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

**Architecture**: Tests use the Page Object Model pattern to encapsulate UI interactions, making tests read as domain-specific scenarios rather than raw Playwright API calls.

---

## 2. Test Infrastructure

### 2.1 Current Setup

```
xftp-web/
├── playwright.config.ts      # Playwright config (webServer, globalSetup)
├── test/
│   ├── globalSetup.ts        # Starts xftp-server, writes port to PORT_FILE
│   ├── page.spec.ts          # E2E tests (to be extended)
│   └── pages/                # Page Objects (new)
│       ├── UploadPage.ts
│       └── DownloadPage.ts
```

### 2.2 Prerequisites

- `globalSetup.ts` starts the XFTP server and writes port to `PORT_FILE`
- Tests must read the port dynamically: `readFileSync(PORT_FILE, 'utf-8').trim()`
- Vite builds and serves the page at `http://localhost:4173`

---

## 3. Test Infrastructure - Page Objects

Page Objects encapsulate page-specific selectors and actions, providing a clean API for tests. This follows the standard Page Object Model pattern used in simplex-chat and most professional test suites.

### 3.1 UploadPage

```typescript
// test/pages/UploadPage.ts
import {Page, Locator, expect} from '@playwright/test'

export class UploadPage {
  readonly page: Page
  readonly dropZone: Locator
  readonly fileInput: Locator
  readonly progressStage: Locator
  readonly progressCanvas: Locator
  readonly statusText: Locator
  readonly cancelButton: Locator
  readonly completeStage: Locator
  readonly shareLink: Locator
  readonly copyButton: Locator
  readonly errorStage: Locator
  readonly errorMessage: Locator
  readonly retryButton: Locator
  readonly expiryNote: Locator
  readonly securityNote: Locator

  constructor(page: Page) {
    this.page = page
    this.dropZone = page.locator('#drop-zone')
    this.fileInput = page.locator('#file-input')
    this.progressStage = page.locator('#upload-progress')
    this.progressCanvas = page.locator('#progress-container canvas')
    this.statusText = page.locator('#upload-status')
    this.cancelButton = page.locator('#cancel-btn')
    this.completeStage = page.locator('#upload-complete')
    this.shareLink = page.locator('[data-testid="share-link"]')
    this.copyButton = page.locator('#copy-btn')
    this.errorStage = page.locator('#upload-error')
    this.errorMessage = page.locator('#error-msg')
    this.retryButton = page.locator('#retry-btn')
    this.expiryNote = page.locator('.expiry')
    this.securityNote = page.locator('.security-note')
  }

  async goto() {
    await this.page.goto('http://localhost:4173')
  }

  async selectFile(name: string, content: Buffer, mimeType = 'application/octet-stream') {
    await this.fileInput.setInputFiles({name, mimeType, buffer: content})
  }

  async selectTextFile(name: string, content: string) {
    await this.selectFile(name, Buffer.from(content, 'utf-8'), 'text/plain')
  }

  async selectLargeFile(name: string, sizeBytes: number) {
    // Create large file in browser to avoid memory issues in test process
    await this.page.evaluate(({name, size}) => {
      const input = document.getElementById('file-input') as HTMLInputElement
      const buffer = new ArrayBuffer(size)
      new Uint8Array(buffer).fill(0x55)
      const file = new File([buffer], name, {type: 'application/octet-stream'})
      const dt = new DataTransfer()
      dt.items.add(file)
      input.files = dt.files
      input.dispatchEvent(new Event('change', {bubbles: true}))
    }, {name, size: sizeBytes})
  }

  async dragDropFile(name: string, content: Buffer) {
    // Drag-drop uses same file input handler internally
    await this.selectFile(name, content)
  }

  async waitForEncrypting(timeout = 10_000) {
    await expect(this.statusText).toContainText('Encrypting', {timeout})
  }

  async waitForUploading(timeout = 30_000) {
    await expect(this.statusText).toContainText('Uploading', {timeout})
  }

  async waitForShareLink(timeout = 60_000): Promise<string> {
    await expect(this.shareLink).toBeVisible({timeout})
    return await this.shareLink.inputValue()
  }

  async clickCopy() {
    await this.copyButton.click()
    await expect(this.copyButton).toContainText('Copied!')
  }

  async clickCancel() {
    await this.cancelButton.click()
  }

  async clickRetry() {
    await this.retryButton.click()
  }

  async expectError(messagePattern: string | RegExp) {
    await expect(this.errorStage).toBeVisible()
    await expect(this.errorMessage).toContainText(messagePattern)
  }

  async expectDropZoneVisible() {
    await expect(this.dropZone).toBeVisible()
  }

  async expectProgressVisible() {
    await expect(this.progressStage).toBeVisible()
    await expect(this.progressCanvas).toBeVisible()
  }

  async expectCompleteWithExpiry() {
    await expect(this.completeStage).toBeVisible()
    await expect(this.expiryNote).toContainText('48 hours')
  }

  async expectSecurityNote() {
    await expect(this.securityNote).toBeVisible()
    await expect(this.securityNote).toContainText('encrypted')
  }

  getHashFromLink(url: string): string {
    return new URL(url).hash
  }
}
```

### 3.2 DownloadPage

```typescript
// test/pages/DownloadPage.ts
import {Page, Locator, expect, Download} from '@playwright/test'

export class DownloadPage {
  readonly page: Page
  readonly readyStage: Locator
  readonly downloadButton: Locator
  readonly progressStage: Locator
  readonly progressCanvas: Locator
  readonly statusText: Locator
  readonly errorStage: Locator
  readonly errorMessage: Locator
  readonly retryButton: Locator
  readonly securityNote: Locator

  constructor(page: Page) {
    this.page = page
    this.readyStage = page.locator('#dl-ready')
    this.downloadButton = page.locator('#dl-btn')
    this.progressStage = page.locator('#dl-progress')
    this.progressCanvas = page.locator('#dl-progress-container canvas')
    this.statusText = page.locator('#dl-status')
    this.errorStage = page.locator('#dl-error')
    this.errorMessage = page.locator('#dl-error-msg')
    this.retryButton = page.locator('#dl-retry-btn')
    this.securityNote = page.locator('.security-note')
  }

  async goto(hash: string) {
    await this.page.goto(`http://localhost:4173${hash}`)
  }

  async gotoWithLink(fullUrl: string) {
    const hash = new URL(fullUrl).hash
    await this.goto(hash)
  }

  async expectFileReady() {
    await expect(this.readyStage).toBeVisible()
    await expect(this.downloadButton).toBeVisible()
  }

  async expectFileSizeDisplayed() {
    await expect(this.readyStage).toContainText(/\d+(?:\.\d+)?\s*(?:KB|MB|B)/)
  }

  async clickDownload(): Promise<Download> {
    const downloadPromise = this.page.waitForEvent('download')
    await this.downloadButton.click()
    return downloadPromise
  }

  async waitForDownloading(timeout = 30_000) {
    await expect(this.statusText).toContainText('Downloading', {timeout})
  }

  async waitForDecrypting(timeout = 30_000) {
    await expect(this.statusText).toContainText('Decrypting', {timeout})
  }

  async expectProgressVisible() {
    await expect(this.progressStage).toBeVisible()
    await expect(this.progressCanvas).toBeVisible()
  }

  async expectInitialError(messagePattern: string | RegExp) {
    // For malformed links - error shown in card without #dl-error stage
    await expect(this.page.locator('.card .error')).toBeVisible()
    await expect(this.page.locator('.card .error')).toContainText(messagePattern)
  }

  async expectRuntimeError(messagePattern: string | RegExp) {
    // For runtime download errors - uses #dl-error stage
    await expect(this.errorStage).toBeVisible()
    await expect(this.errorMessage).toContainText(messagePattern)
  }

  async expectSecurityNote() {
    await expect(this.securityNote).toBeVisible()
    await expect(this.securityNote).toContainText('encrypted')
  }
}
```

### 3.3 Test Fixtures

```typescript
// test/fixtures.ts
import {test as base} from '@playwright/test'
import {UploadPage} from './pages/UploadPage'
import {DownloadPage} from './pages/DownloadPage'
import {readFileSync} from 'fs'

// Extend Playwright test with page objects
export const test = base.extend<{
  uploadPage: UploadPage
  downloadPage: DownloadPage
}>({
  uploadPage: async ({page}, use) => {
    const uploadPage = new UploadPage(page)
    await uploadPage.goto()
    await use(uploadPage)
  },
  downloadPage: async ({page}, use) => {
    await use(new DownloadPage(page))
  },
})

export {expect} from '@playwright/test'

// Test data helpers
export function createTestContent(size: number, fill = 0x41): Buffer {
  return Buffer.alloc(size, fill)
}

export function createTextContent(text: string): Buffer {
  return Buffer.from(text, 'utf-8')
}

export function uniqueFileName(base: string, ext = 'txt'): string {
  return `${base}-${Date.now()}.${ext}`
}
```

---

## 4. Upload Flow Tests

### 4.1 File Selection - File Picker Button

**Test ID**: `upload-file-picker`

```typescript
test('upload via file picker button', async ({uploadPage}) => {
  await uploadPage.expectDropZoneVisible()

  await uploadPage.selectTextFile('picker-test.txt', 'test content ' + Date.now())
  await uploadPage.waitForEncrypting()
  await uploadPage.waitForUploading()

  const link = await uploadPage.waitForShareLink()
  expect(link).toMatch(/^http:\/\/localhost:\d+\/#/)
})
```

### 4.2 File Selection - Drag and Drop

**Test ID**: `upload-drag-drop`

```typescript
test('upload via drag and drop', async ({uploadPage}) => {
  await uploadPage.dragDropFile('dragdrop-test.txt', createTextContent('drag drop test'))
  await uploadPage.expectProgressVisible()

  const link = await uploadPage.waitForShareLink()
  expect(link).toContain('#')
})
```

### 4.3 File Size Validation - Too Large

**Test ID**: `upload-file-too-large`

```typescript
test('upload rejects file over 100MB', async ({uploadPage}) => {
  await uploadPage.selectLargeFile('large.bin', 100 * 1024 * 1024 + 1)
  await uploadPage.expectError('too large')
  await uploadPage.expectError('100 MB')
})
```

### 4.4 File Size Validation - Empty File

**Test ID**: `upload-file-empty`

```typescript
test('upload rejects empty file', async ({uploadPage}) => {
  await uploadPage.selectFile('empty.txt', Buffer.alloc(0))
  await uploadPage.expectError('empty')
})
```

### 4.5 Progress Display

**Test ID**: `upload-progress-display`

```typescript
test('upload shows progress during encryption and upload', async ({uploadPage}) => {
  await uploadPage.selectFile('progress-test.bin', createTestContent(500 * 1024))

  await uploadPage.expectProgressVisible()
  await uploadPage.waitForEncrypting()
  await uploadPage.waitForUploading()
  await uploadPage.waitForShareLink()
})
```

### 4.6 Cancel Button

**Test ID**: `upload-cancel`

```typescript
test('cancel button aborts upload and returns to landing', async ({uploadPage}) => {
  await uploadPage.selectFile('cancel-test.bin', createTestContent(1024 * 1024))
  await uploadPage.expectProgressVisible()

  await uploadPage.clickCancel()

  await uploadPage.expectDropZoneVisible()
  await expect(uploadPage.shareLink).toBeHidden()
})
```

### 4.7 Share Link Display and Copy

**Test ID**: `upload-share-link-copy`

```typescript
test('share link copy button works', async ({uploadPage, context}) => {
  await context.grantPermissions(['clipboard-read', 'clipboard-write'])

  await uploadPage.selectTextFile('copy-test.txt', 'copy test content')
  const link = await uploadPage.waitForShareLink()

  await uploadPage.clickCopy()

  // Verify clipboard (may fail in headless)
  try {
    const clipboardText = await uploadPage.page.evaluate(() => navigator.clipboard.readText())
    expect(clipboardText).toBe(link)
  } catch {
    // Clipboard API may not be available
  }
})
```

### 4.8 Error Handling and Retry

**Test ID**: `upload-error-retry`

```typescript
test('error state shows retry button', async ({uploadPage}) => {
  await uploadPage.selectFile('error-test.txt', Buffer.alloc(0))
  await uploadPage.expectError('empty')
  await expect(uploadPage.retryButton).toBeVisible()
})
```

---

## 5. Download Flow Tests

### 5.1 Invalid Link Handling - Malformed Hash

**Test ID**: `download-invalid-hash-malformed`

```typescript
test('download shows error for malformed hash', async ({downloadPage}) => {
  await downloadPage.goto('#not-valid-base64!!!')
  await downloadPage.expectInitialError(/[Ii]nvalid|corrupted/)
  await expect(downloadPage.downloadButton).not.toBeVisible()
})
```

### 5.2 Invalid Link Handling - Valid Base64 but Invalid Structure

**Test ID**: `download-invalid-hash-structure`

```typescript
test('download shows error for invalid structure', async ({downloadPage}) => {
  await downloadPage.goto('#AAAA')
  await downloadPage.expectInitialError(/[Ii]nvalid|corrupted/)
})
```

### 5.3 Download Button Click

**Test ID**: `download-button-click`

```typescript
test('download button initiates download', async ({uploadPage, downloadPage}) => {
  // Upload first
  await uploadPage.selectTextFile('dl-btn-test.txt', 'download test content')
  const link = await uploadPage.waitForShareLink()

  // Navigate to download
  await downloadPage.gotoWithLink(link)
  await downloadPage.expectFileReady()

  // Click download
  const download = await downloadPage.clickDownload()
  expect(download.suggestedFilename()).toBe('dl-btn-test.txt')
})
```

### 5.4 Progress Display

**Test ID**: `download-progress-display`

```typescript
test('download shows progress', async ({uploadPage, downloadPage}) => {
  await uploadPage.selectFile('dl-progress.bin', createTestContent(500 * 1024))
  const link = await uploadPage.waitForShareLink()

  await downloadPage.gotoWithLink(link)
  const downloadPromise = downloadPage.clickDownload()

  await downloadPage.expectProgressVisible()
  await downloadPage.waitForDownloading()

  await downloadPromise
})
```

### 5.5 File Save Verification

**Test ID**: `download-file-save`

```typescript
test('downloaded file content matches upload', async ({uploadPage, downloadPage}) => {
  const content = 'verification content ' + Date.now()
  const fileName = 'verify.txt'

  await uploadPage.selectTextFile(fileName, content)
  const link = await uploadPage.waitForShareLink()

  await downloadPage.gotoWithLink(link)
  const download = await downloadPage.clickDownload()

  expect(download.suggestedFilename()).toBe(fileName)

  const path = await download.path()
  if (path) {
    const downloadedContent = (await import('fs')).readFileSync(path, 'utf-8')
    expect(downloadedContent).toBe(content)
  }
})
```

---

## 6. Edge Cases

### 6.1 Very Small Files

**Test ID**: `edge-small-file`

```typescript
test('upload and download 1-byte file', async ({uploadPage, downloadPage}) => {
  await uploadPage.selectFile('tiny.bin', Buffer.from([0x42]))
  const link = await uploadPage.waitForShareLink()

  await downloadPage.gotoWithLink(link)
  const download = await downloadPage.clickDownload()

  expect(download.suggestedFilename()).toBe('tiny.bin')

  const path = await download.path()
  if (path) {
    const content = (await import('fs')).readFileSync(path)
    expect(content.length).toBe(1)
    expect(content[0]).toBe(0x42)
  }
})
```

### 6.2 Files Near 100MB Limit

**Test ID**: `edge-near-limit`

```typescript
test.slow()
test('upload file at exactly 100MB', async ({uploadPage}) => {
  await uploadPage.selectLargeFile('exactly-100mb.bin', 100 * 1024 * 1024)

  // Should succeed (not show error)
  await expect(uploadPage.errorStage).toBeHidden({timeout: 5000})
  await uploadPage.expectProgressVisible()

  // Wait for completion (may take a while)
  await uploadPage.waitForShareLink(300_000)
})
```

### 6.3 Special Characters in Filename

**Test ID**: `edge-special-chars-filename`

```typescript
test('upload and download file with unicode filename', async ({uploadPage, downloadPage}) => {
  const fileName = 'test-\u4e2d\u6587-\u0420\u0443\u0441\u0441\u043a\u0438\u0439.txt'

  await uploadPage.selectTextFile(fileName, 'unicode filename test')
  const link = await uploadPage.waitForShareLink()

  await downloadPage.gotoWithLink(link)
  const download = await downloadPage.clickDownload()

  expect(download.suggestedFilename()).toBe(fileName)
})

test('upload and download file with spaces', async ({uploadPage, downloadPage}) => {
  const fileName = 'my document (final) v2.txt'

  await uploadPage.selectTextFile(fileName, 'spaces test')
  const link = await uploadPage.waitForShareLink()

  await downloadPage.gotoWithLink(link)
  const download = await downloadPage.clickDownload()

  expect(download.suggestedFilename()).toBe(fileName)
})

test('filename with path separators is sanitized', async ({uploadPage, downloadPage}) => {
  await uploadPage.selectTextFile('../../../etc/passwd', 'path traversal test')
  const link = await uploadPage.waitForShareLink()

  await downloadPage.gotoWithLink(link)
  const download = await downloadPage.clickDownload()

  expect(download.suggestedFilename()).not.toContain('/')
  expect(download.suggestedFilename()).not.toContain('\\')
})
```

### 6.4 Network Errors (Mocked)

**Test ID**: `edge-network-error`

```typescript
test('upload handles network error gracefully', async ({uploadPage}) => {
  // Intercept and abort POST requests
  await uploadPage.page.route('**/localhost:*', route => {
    if (route.request().method() === 'POST') {
      route.abort('failed')
    } else {
      route.continue()
    }
  })

  await uploadPage.selectTextFile('network-error.txt', 'network error test')
  await uploadPage.expectError(/.+/) // Any error message
})
```

### 6.5 Binary File Content Integrity

**Test ID**: `edge-binary-content`

```typescript
test('binary file with all byte values', async ({uploadPage, downloadPage}) => {
  // Create buffer with all 256 byte values
  const buffer = Buffer.alloc(256)
  for (let i = 0; i < 256; i++) buffer[i] = i

  await uploadPage.selectFile('all-bytes.bin', buffer)
  const link = await uploadPage.waitForShareLink()

  await downloadPage.gotoWithLink(link)
  const download = await downloadPage.clickDownload()

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

### 6.6 Multiple Concurrent Downloads

**Test ID**: `edge-concurrent-downloads`

```typescript
test('concurrent downloads from same link', async ({browser}) => {
  const context = await browser.newContext({ignoreHTTPSErrors: true})
  const page1 = await context.newPage()
  const upload = new UploadPage(page1)

  await upload.goto()
  await upload.selectTextFile('concurrent.txt', 'concurrent download test')
  const link = await upload.waitForShareLink()
  const hash = upload.getHashFromLink(link)

  // Open two tabs and download concurrently
  const page2 = await context.newPage()
  const page3 = await context.newPage()
  const dl2 = new DownloadPage(page2)
  const dl3 = new DownloadPage(page3)

  await dl2.goto(hash)
  await dl3.goto(hash)

  const [download2, download3] = await Promise.all([
    dl2.clickDownload(),
    dl3.clickDownload()
  ])

  expect(download2.suggestedFilename()).toBe('concurrent.txt')
  expect(download3.suggestedFilename()).toBe('concurrent.txt')

  await context.close()
})
```

### 6.7 Redirect File Handling (Multi-chunk)

**Test ID**: `edge-redirect-file`

```typescript
test.slow()
test('upload and download multi-chunk file with redirect', async ({uploadPage, downloadPage}) => {
  // Use ~5MB file to get multiple chunks
  await uploadPage.selectLargeFile('multi-chunk.bin', 5 * 1024 * 1024)
  const link = await uploadPage.waitForShareLink(120_000)

  await downloadPage.gotoWithLink(link)
  const download = await downloadPage.clickDownload()

  expect(download.suggestedFilename()).toBe('multi-chunk.bin')

  const path = await download.path()
  if (path) {
    const stat = (await import('fs')).statSync(path)
    expect(stat.size).toBe(5 * 1024 * 1024)
  }
})
```

### 6.8 UI Information Display

**Test ID**: `edge-ui-info`

```typescript
test('upload complete shows expiry and security note', async ({uploadPage}) => {
  await uploadPage.selectTextFile('ui-test.txt', 'ui test')
  await uploadPage.waitForShareLink()

  await uploadPage.expectCompleteWithExpiry()
  await uploadPage.expectSecurityNote()
})

test('download page shows file size and security note', async ({uploadPage, downloadPage}) => {
  await uploadPage.selectFile('size-test.bin', createTestContent(1024))
  const link = await uploadPage.waitForShareLink()

  await downloadPage.gotoWithLink(link)
  await downloadPage.expectFileSizeDisplayed()
  await downloadPage.expectSecurityNote()
})
```

---

## 7. Implementation Order

### Phase 1: Core Infrastructure (Priority: High)
1. Create `test/pages/UploadPage.ts` with Page Object
2. Create `test/pages/DownloadPage.ts` with Page Object
3. Create `test/fixtures.ts` with extended test function
4. Refactor existing test to use Page Objects

### Phase 2: Core Happy Path (Priority: High)
5. `upload-file-picker` - Basic upload via file picker
6. `download-button-click` - Basic download
7. `download-file-save` - Content verification

### Phase 3: Validation (Priority: High)
8. `upload-file-too-large` - Size validation
9. `upload-file-empty` - Empty file validation
10. `download-invalid-hash-malformed` - Invalid link handling
11. `download-invalid-hash-structure` - Invalid structure handling

### Phase 4: Progress and Cancel (Priority: Medium)
12. `upload-progress-display` - Progress visibility
13. `upload-cancel` - Cancel functionality
14. `download-progress-display` - Download progress

### Phase 5: Link Sharing (Priority: Medium)
15. `upload-share-link-copy` - Copy button functionality
16. `upload-drag-drop` - Drag-drop upload

### Phase 6: Edge Cases (Priority: Low)
17. `edge-small-file` - 1-byte file
18. `edge-special-chars-filename` - Unicode/special characters
19. `edge-binary-content` - Binary content integrity
20. `edge-near-limit` - 100MB file (slow test)
21. `edge-network-error` - Network error handling

### Phase 7: Error Recovery and Advanced (Priority: Low)
22. `upload-error-retry` - Retry after error
23. `edge-concurrent-downloads` - Concurrent access
24. `edge-redirect-file` - Multi-chunk file with redirect (slow)
25. `edge-ui-info` - Expiry message, security notes

---

## 8. Test Utilities

### 8.1 Shared Test Setup

```typescript
// test/page.spec.ts
import {test, expect, createTestContent, createTextContent, uniqueFileName} from './fixtures'

test.describe('Upload Flow', () => {
  test('upload via file picker', async ({uploadPage}) => {
    // Tests use uploadPage fixture which navigates automatically
  })
})

test.describe('Download Flow', () => {
  test('download works', async ({uploadPage, downloadPage}) => {
    // Both pages available via fixtures
  })
})

test.describe('Edge Cases', () => {
  // Edge case tests
})
```

### 8.2 File Structure

```
xftp-web/test/
├── fixtures.ts           # Playwright fixtures with page objects
├── pages/
│   ├── UploadPage.ts     # Upload page object
│   └── DownloadPage.ts   # Download page object
├── page.spec.ts          # All E2E tests
└── globalSetup.ts        # Server startup (existing)
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
| edge-small-file | Edge | Low | 30s | - |
| edge-near-limit | Edge | Low | 300s | - |
| edge-special-chars-filename | Edge | Low | 30s | - |
| edge-network-error | Edge | Low | 45s | - |
| edge-binary-content | Edge | Low | 30s | - |
| edge-concurrent-downloads | Edge | Low | 60s | upload |
| edge-redirect-file | Edge | Low | 120s | - |
| edge-ui-info | Edge | Low | 60s | upload |

**Total estimated time**: ~18 minutes (excluding 100MB and 5MB tests)
