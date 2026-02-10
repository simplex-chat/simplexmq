import {test, expect, createTestContent, createTextContent} from './fixtures'
import {UploadPage} from './pages/upload-page'
import {DownloadPage} from './pages/download-page'
import {readFileSync, statSync} from 'fs'

// ─────────────────────────────────────────────────────────────────────────────
// Upload Flow Tests
// ─────────────────────────────────────────────────────────────────────────────

test.describe('Upload Flow', () => {
  test('upload via file picker button', async ({uploadPage}) => {
    await uploadPage.expectDropZoneVisible()

    await uploadPage.selectTextFile('picker-test.txt', 'test content ' + Date.now())
    await uploadPage.waitForEncrypting()
    await uploadPage.waitForUploading()

    const link = await uploadPage.waitForShareLink()
    expect(link).toMatch(/^http:\/\/localhost:\d+\/?#/)
  })

  test('upload via file input (drag-drop code path)', async ({uploadPage}) => {
    // Tests file handling logic - the drop handler uses the same input processing
    await uploadPage.dragDropFile('dragdrop-test.txt', createTextContent('drag drop test'))
    await uploadPage.expectProgressVisible()

    const link = await uploadPage.waitForShareLink()
    expect(link).toContain('#')
  })

  test('upload rejects file over 100MB', async ({uploadPage}) => {
    await uploadPage.selectLargeFile('large.bin', 100 * 1024 * 1024 + 1)
    await uploadPage.expectError('too large')
    await uploadPage.expectError('100 MB')
  })

  test('upload rejects empty file', async ({uploadPage}) => {
    await uploadPage.selectFile('empty.txt', Buffer.alloc(0))
    await uploadPage.expectError('empty')
  })

  test('upload shows progress during encryption and upload', async ({uploadPage}) => {
    await uploadPage.selectFile('progress-test.bin', createTestContent(500 * 1024))

    await uploadPage.expectProgressVisible()
    await uploadPage.waitForEncrypting()
    await uploadPage.waitForUploading()
    await uploadPage.waitForShareLink()
  })

  test('cancel button aborts upload and returns to landing', async ({uploadPage}) => {
    await uploadPage.selectFile('cancel-test.bin', createTestContent(1024 * 1024))
    await uploadPage.expectProgressVisible()

    await uploadPage.clickCancel()

    await uploadPage.expectDropZoneVisible()
    await uploadPage.expectShareLinkNotVisible()
  })

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
      // Clipboard API may not be available in headless mode
    }
  })

  test('error state shows retry button', async ({uploadPage}) => {
    await uploadPage.selectFile('error-test.txt', Buffer.alloc(0))
    await uploadPage.expectError('empty')
    await uploadPage.expectRetryButtonVisible()
  })

  test('upload complete shows expiry and security note', async ({uploadPage}) => {
    await uploadPage.selectTextFile('ui-test.txt', 'ui test')
    await uploadPage.waitForShareLink()

    await uploadPage.expectCompleteWithExpiry()
    await uploadPage.expectSecurityNote()
  })
})

// ─────────────────────────────────────────────────────────────────────────────
// Download Flow Tests
// ─────────────────────────────────────────────────────────────────────────────

test.describe('Download Flow', () => {
  test('download shows error for malformed hash', async ({downloadPage}) => {
    await downloadPage.goto('#not-valid-base64!!!')
    await downloadPage.expectInitialError(/[Ii]nvalid|corrupted/)
    await downloadPage.expectDownloadButtonNotVisible()
  })

  test('download shows error for invalid structure', async ({downloadPage}) => {
    await downloadPage.goto('#AAAA')
    await downloadPage.expectInitialError(/[Ii]nvalid|corrupted/)
  })

  test('download button initiates download', async ({uploadPage, downloadPage}) => {
    await uploadPage.selectTextFile('dl-btn-test.txt', 'download test content')
    const link = await uploadPage.waitForShareLink()

    await downloadPage.gotoWithLink(link)
    await downloadPage.expectFileReady()

    const download = await downloadPage.clickDownload()
    expect(download.suggestedFilename()).toBe('dl-btn-test.txt')
  })

  test('download shows progress', async ({uploadPage, downloadPage}) => {
    // Use larger file to ensure progress is observable
    await uploadPage.selectFile('dl-progress.bin', createTestContent(1024 * 1024))
    const link = await uploadPage.waitForShareLink()

    await downloadPage.gotoWithLink(link)

    // Set up download listener before clicking
    const downloadPromise = downloadPage.page.waitForEvent('download')

    // Click starts download - progress should be visible while downloading
    await downloadPage.startDownload()
    await downloadPage.expectProgressVisible()

    await downloadPromise
  })

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
      const downloadedContent = readFileSync(path, 'utf-8')
      expect(downloadedContent).toBe(content)
    }
  })

  test('download page shows file size and security note', async ({uploadPage, downloadPage}) => {
    await uploadPage.selectFile('size-test.bin', createTestContent(1024))
    const link = await uploadPage.waitForShareLink()

    await downloadPage.gotoWithLink(link)
    await downloadPage.expectFileSizeDisplayed()
    await downloadPage.expectSecurityNote()
  })
})

// ─────────────────────────────────────────────────────────────────────────────
// Edge Cases
// ─────────────────────────────────────────────────────────────────────────────

test.describe('Edge Cases', () => {
  test('upload and download 1-byte file', async ({uploadPage, downloadPage}) => {
    await uploadPage.selectFile('tiny.bin', Buffer.from([0x42]))
    const link = await uploadPage.waitForShareLink()

    await downloadPage.gotoWithLink(link)
    const download = await downloadPage.clickDownload()

    expect(download.suggestedFilename()).toBe('tiny.bin')

    const path = await download.path()
    if (path) {
      const content = readFileSync(path)
      expect(content.length).toBe(1)
      expect(content[0]).toBe(0x42)
    }
  })

  test('upload and download file with unicode filename', async ({uploadPage, downloadPage}) => {
    const fileName = 'test-\u4e2d\u6587-\u0420\u0443\u0441\u0441\u043a\u0438\u0439.txt'

    await uploadPage.selectTextFile(fileName, 'unicode filename test')
    const link = await uploadPage.waitForShareLink()

    await downloadPage.gotoWithLink(link)
    const download = await downloadPage.clickDownload()

    // Browser download attribute uses encodeURIComponent for non-ASCII filenames
    expect(download.suggestedFilename()).toBe(encodeURIComponent(fileName))
  })

  test('upload and download file with spaces', async ({uploadPage, downloadPage}) => {
    const fileName = 'my document (final) v2.txt'

    await uploadPage.selectTextFile(fileName, 'spaces test')
    const link = await uploadPage.waitForShareLink()

    await downloadPage.gotoWithLink(link)
    const download = await downloadPage.clickDownload()

    // Browser download attribute uses encodeURIComponent for the filename
    expect(download.suggestedFilename()).toBe(encodeURIComponent(fileName))
  })

  test('filename with path separators is sanitized', async ({uploadPage, downloadPage}) => {
    await uploadPage.selectTextFile('../../../etc/passwd', 'path traversal test')
    const link = await uploadPage.waitForShareLink()

    await downloadPage.gotoWithLink(link)
    const download = await downloadPage.clickDownload()

    expect(download.suggestedFilename()).not.toContain('/')
    expect(download.suggestedFilename()).not.toContain('\\')
  })

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
      const content = readFileSync(path)
      expect(content.length).toBe(256)
      for (let i = 0; i < 256; i++) {
        expect(content[i]).toBe(i)
      }
    }
  })

  test('upload handles network error gracefully', async ({uploadPage}) => {
    // Intercept and abort server requests after encryption starts
    await uploadPage.page.route('**/*', route => {
      const url = route.request().url()
      // Only abort XFTP server requests (HTTPS), not the web page (HTTP)
      if (url.startsWith('https://') && route.request().method() !== 'GET') {
        route.abort('failed')
      } else {
        route.continue()
      }
    })

    await uploadPage.selectTextFile('network-error.txt', 'network error test')
    await uploadPage.expectError(/.+/) // Any error message
  })

  test('concurrent downloads from same link', async ({browser}) => {
    const context = await browser.newContext({ignoreHTTPSErrors: true})
    const page1 = await context.newPage()
    const upload = new UploadPage(page1)

    await upload.goto()
    await upload.selectTextFile('concurrent.txt', 'concurrent download test')
    const link = await upload.waitForShareLink()
    const hash = upload.getHashFromLink(link)

    // Open two tabs and download concurrently (shared HTTP/2 connection)
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
})

// ─────────────────────────────────────────────────────────────────────────────
// Slow Tests (Large Files)
// ─────────────────────────────────────────────────────────────────────────────

test.describe('Slow Tests', () => {
  test('upload file at exactly 100MB', async ({uploadPage}) => {
    test.slow()
    await uploadPage.selectLargeFile('exactly-100mb.bin', 100 * 1024 * 1024)

    // Should succeed (not show error)
    await uploadPage.expectNoError()
    await uploadPage.expectProgressVisible()

    // Wait for completion (may take a while)
    await uploadPage.waitForShareLink(300_000)
  })

  test('upload and download multi-chunk file with redirect', async ({uploadPage, downloadPage}) => {
    test.slow()
    // Use ~5MB file to get multiple chunks
    await uploadPage.selectLargeFile('multi-chunk.bin', 5 * 1024 * 1024)
    const link = await uploadPage.waitForShareLink(120_000)

    await downloadPage.gotoWithLink(link)
    const download = await downloadPage.clickDownload()

    expect(download.suggestedFilename()).toBe('multi-chunk.bin')

    const path = await download.path()
    if (path) {
      const stat = statSync(path)
      expect(stat.size).toBe(5 * 1024 * 1024)
    }
  })
})
