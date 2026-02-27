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

  async startDownload() {
    await this.downloadButton.click()
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

  async expectDownloadButtonNotVisible() {
    await expect(this.downloadButton).not.toBeVisible()
  }
}
