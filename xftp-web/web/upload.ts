import {createCryptoBackend} from './crypto-backend.js'
import {getServers} from './servers.js'
import {createProgressRing} from './progress.js'
import {t} from './i18n.js'
import {
  newXFTPAgent, closeXFTPAgent, uploadFile, encodeDescriptionURI,
  type EncryptedFileMetadata
} from '../src/agent.js'
import {XFTPPermanentError} from '../src/client.js'

const MAX_SIZE = 100 * 1024 * 1024
const ENCRYPT_WEIGHT = 0.15
const ENCRYPT_MIN_FILE_SIZE = 100 * 1024
const ENCRYPT_MIN_DISPLAY_MS = 1000

export function initUpload(app: HTMLElement) {
  app.innerHTML = `
    <div class="card">
      <h1>${t('title', 'SimpleX File Transfer')}</h1>
      <div id="drop-zone" class="drop-zone">
        <p>${t('dropZone', 'Drag & drop a file here')}</p>
        <p class="hint">${t('dropZoneHint', 'or')}</p>
        <label class="btn" for="file-input">${t('chooseFile', 'Choose file')}</label>
        <input id="file-input" type="file" hidden>
        <p class="hint">${t('maxSizeHint', 'Max 100 MB')}</p>
      </div>
      <div id="upload-progress" class="stage" hidden>
        <div id="progress-container"></div>
        <p id="upload-status">${t('encrypting', 'Encrypting\u2026')}</p>
        <button id="cancel-btn" class="btn btn-secondary">${t('cancel', 'Cancel')}</button>
      </div>
      <div id="upload-complete" class="stage" hidden>
        <p class="success">${t('fileUploaded', 'File uploaded')}</p>
        <div class="link-row">
          <input id="share-link" data-testid="share-link" readonly>
          <button id="copy-btn" class="btn">${t('copy', 'Copy')}</button>
        </div>
        <p class="hint expiry">${t('expiryHint', 'Files are typically available for 48 hours.')}</p>
        <div class="security-note">
          <p>${t('securityNote1', 'Your file was encrypted in the browser before upload \u2014 the server never sees file contents.')}</p>
          <p>${t('securityNote2', 'The link contains the decryption key in the hash fragment, which the browser never sends to any server.')}</p>
          <p>${t('securityNote3', 'For maximum security, use the <a href="https://simplex.chat" target="_blank" rel="noopener">SimpleX app</a>.')}</p>
        </div>
      </div>
      <div id="upload-error" class="stage" hidden>
        <p class="error" id="error-msg"></p>
        <button id="retry-btn" class="btn">${t('retry', 'Retry')}</button>
      </div>
    </div>`

  const dropZone = document.getElementById('drop-zone')!
  const fileInput = document.getElementById('file-input') as HTMLInputElement
  const progressStage = document.getElementById('upload-progress')!
  const completeStage = document.getElementById('upload-complete')!
  const errorStage = document.getElementById('upload-error')!
  const progressContainer = document.getElementById('progress-container')!
  const statusText = document.getElementById('upload-status')!
  const cancelBtn = document.getElementById('cancel-btn')!
  const shareLink = document.getElementById('share-link') as HTMLInputElement
  const copyBtn = document.getElementById('copy-btn')!
  const errorMsg = document.getElementById('error-msg')!
  const retryBtn = document.getElementById('retry-btn')!

  const shareBtn = typeof navigator.share === 'function'
    ? (() => {
        const btn = document.createElement('button')
        btn.className = 'btn btn-secondary'
        btn.textContent = t('share', 'Share')
        shareLink.parentElement!.appendChild(btn)
        return btn
      })()
    : null

  let aborted = false
  let pendingFile: File | null = null

  dropZone.addEventListener('dragover', e => { e.preventDefault(); dropZone.classList.add('drag-over') })
  dropZone.addEventListener('dragleave', () => dropZone.classList.remove('drag-over'))
  dropZone.addEventListener('drop', e => {
    e.preventDefault()
    dropZone.classList.remove('drag-over')
    const f = e.dataTransfer?.files[0]
    if (f) startUpload(f)
  })
  fileInput.addEventListener('change', () => {
    if (fileInput.files?.[0]) startUpload(fileInput.files[0])
  })
  retryBtn.addEventListener('click', () => {
    pendingFile = null
    fileInput.value = ''
    showStage(dropZone)
  })

  function showStage(stage: HTMLElement) {
    for (const s of [dropZone, progressStage, completeStage, errorStage]) s.hidden = true
    stage.hidden = false
  }

  function showError(msg: string) {
    errorMsg.innerHTML = msg
    showStage(errorStage)
  }

  async function startUpload(file: File) {
    pendingFile = file
    aborted = false

    if (file.size > MAX_SIZE) {
      showError(t('fileTooLarge', 'File too large (%size%). Maximum is 100 MB. The SimpleX app supports files up to 1 GB.').replace('%size%', formatSize(file.size)))
      return
    }
    if (file.size === 0) {
      showError(t('fileEmpty', 'File is empty.'))
      return
    }

    showStage(progressStage)
    const ring = createProgressRing()
    progressContainer.innerHTML = ''
    progressContainer.appendChild(ring.canvas)

    const showEncrypt = file.size >= ENCRYPT_MIN_FILE_SIZE
    const encryptWeight = showEncrypt ? ENCRYPT_WEIGHT : 0
    statusText.textContent = showEncrypt
      ? t('encrypting', 'Encrypting\u2026')
      : t('uploading', 'Uploading\u2026')

    const backend = createCryptoBackend()
    const agent = newXFTPAgent()

    cancelBtn.onclick = () => {
      aborted = true
      ring.destroy()
      backend.cleanup().catch(() => {})
      closeXFTPAgent(agent)
      showStage(dropZone)
    }

    try {
      const encryptStart = performance.now()
      const fileData = new Uint8Array(await file.arrayBuffer())
      if (aborted) return

      const encrypted = await backend.encrypt(fileData, file.name, (done, total) => {
        ring.update((done / total) * encryptWeight)
      })
      if (aborted) return

      if (showEncrypt) {
        const elapsed = performance.now() - encryptStart
        if (elapsed < ENCRYPT_MIN_DISPLAY_MS) {
          await ring.fillTo(encryptWeight, ENCRYPT_MIN_DISPLAY_MS - elapsed)
          if (aborted) return
        }
        statusText.textContent = t('uploading', 'Uploading\u2026')
      }

      const metadata: EncryptedFileMetadata = {
        digest: encrypted.digest,
        key: encrypted.key,
        nonce: encrypted.nonce,
        chunkSizes: encrypted.chunkSizes
      }
      const servers = getServers()
      const result = await uploadFile(agent, servers, metadata, {
        readChunk: (off, sz) => backend.readChunk(off, sz),
        onProgress: (uploaded, total) => {
          ring.update(encryptWeight + (uploaded / total) * (1 - encryptWeight))
        }
      })
      if (aborted) return

      const url = window.location.origin + window.location.pathname + '#' + result.uri
      shareLink.value = url
      showStage(completeStage)
      app.dispatchEvent(new CustomEvent('xftp:upload-complete', {detail: {url}, bubbles: true}))
      copyBtn.onclick = () => {
        navigator.clipboard.writeText(url).then(() => {
          copyBtn.textContent = t('copied', 'Copied!')
          setTimeout(() => { copyBtn.textContent = t('copy', 'Copy') }, 2000)
        })
      }
      if (shareBtn) {
        shareBtn.onclick = () => navigator.share({url}).catch(() => {})
      }
    } catch (err: any) {
      if (!aborted) {
        const msg = err?.message ?? String(err)
        showError(msg)
        // Hide retry button for permanent errors (no point retrying)
        if (err instanceof XFTPPermanentError) retryBtn.hidden = true
        else retryBtn.hidden = false
      }
    } finally {
      ring.destroy()
      await backend.cleanup().catch(() => {})
      closeXFTPAgent(agent)
    }
  }
}

function formatSize(bytes: number): string {
  if (bytes < 1024) return bytes + ' B'
  if (bytes < 1024 * 1024) return (bytes / 1024).toFixed(1) + ' KB'
  return (bytes / (1024 * 1024)).toFixed(1) + ' MB'
}
