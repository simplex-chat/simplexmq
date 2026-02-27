import {test as base} from '@playwright/test'
import {UploadPage} from './pages/upload-page'
import {DownloadPage} from './pages/download-page'

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
