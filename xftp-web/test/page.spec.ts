import {test, expect} from '@playwright/test'

const PAGE_URL = 'http://localhost:4173'

test('page upload + download round-trip', async ({page}) => {
  // Upload page
  await page.goto(PAGE_URL)
  await expect(page.locator('#drop-zone')).toBeVisible()

  // Create a small test file
  const content = 'Hello SimpleX ' + Date.now()
  const fileName = 'test-file.txt'
  const buffer = Buffer.from(content, 'utf-8')

  // Set file via hidden input
  const fileInput = page.locator('#file-input')
  await fileInput.setInputFiles({name: fileName, mimeType: 'text/plain', buffer})

  // Wait for upload to complete
  const shareLink = page.locator('[data-testid="share-link"]')
  await expect(shareLink).toBeVisible({timeout: 30_000})

  // Extract the hash from the share link
  const linkValue = await shareLink.inputValue()
  const hash = new URL(linkValue).hash

  // Navigate to download page
  await page.goto(PAGE_URL + hash)
  await expect(page.locator('#dl-btn')).toBeVisible()

  // Start download and wait for completion
  const downloadPromise = page.waitForEvent('download')
  await page.locator('#dl-btn').click()
  const download = await downloadPromise

  // Verify downloaded file
  expect(download.suggestedFilename()).toBe(fileName)
  const downloadedContent = (await download.path()) !== null
    ? (await import('fs')).readFileSync(await download.path()!, 'utf-8')
    : ''
  expect(downloadedContent).toBe(content)
})
