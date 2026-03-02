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
    // Note: True drag-drop simulation is complex in Playwright. The app's drop handler
    // dispatches a 'change' event on the file input, so setting input files triggers
    // the same code path. This tests the file handling logic, not the DnD UI events.
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

  async expectRetryButtonVisible() {
    await expect(this.retryButton).toBeVisible()
  }

  async expectShareLinkNotVisible() {
    await expect(this.shareLink).not.toBeVisible()
  }

  async expectNoError(timeout = 5000) {
    await expect(this.errorStage).not.toBeVisible({timeout})
  }

  getHashFromLink(url: string): string {
    return new URL(url).hash
  }
}
