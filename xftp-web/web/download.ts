import {createCryptoBackend} from './crypto-backend.js'
import {createProgressRing} from './progress.js'
import {
  newXFTPAgent, closeXFTPAgent,
  decodeDescriptionURI, downloadFileRaw
} from '../src/agent.js'

export function initDownload(app: HTMLElement, hash: string) {
  let fd: ReturnType<typeof decodeDescriptionURI>
  try {
    fd = decodeDescriptionURI(hash)
  } catch (err: any) {
    app.innerHTML = `<div class="card"><p class="error">Invalid or corrupted link.</p></div>`
    return
  }

  const size = fd.redirect ? fd.redirect.size : fd.size
  app.innerHTML = `
    <div class="card">
      <h1>SimpleX File Transfer</h1>
      <div id="dl-ready" class="stage">
        <p>File available (~${formatSize(size)})</p>
        <button id="dl-btn" class="btn">Download</button>
        <div class="security-note">
          <p>This file is encrypted — the server never sees file contents.</p>
          <p>The decryption key is in the link's hash fragment, which your browser never sends to any server.</p>
          <p>For maximum security, use the <a href="https://simplex.chat" target="_blank" rel="noopener">SimpleX app</a>.</p>
        </div>
      </div>
      <div id="dl-progress" class="stage" hidden>
        <div id="dl-progress-container"></div>
        <p id="dl-status">Downloading…</p>
      </div>
      <div id="dl-error" class="stage" hidden>
        <p class="error" id="dl-error-msg"></p>
        <button id="dl-retry-btn" class="btn">Retry</button>
      </div>
    </div>`

  const readyStage = document.getElementById('dl-ready')!
  const progressStage = document.getElementById('dl-progress')!
  const errorStage = document.getElementById('dl-error')!
  const progressContainer = document.getElementById('dl-progress-container')!
  const statusText = document.getElementById('dl-status')!
  const dlBtn = document.getElementById('dl-btn')!
  const errorMsg = document.getElementById('dl-error-msg')!
  const retryBtn = document.getElementById('dl-retry-btn')!

  function showStage(stage: HTMLElement) {
    for (const s of [readyStage, progressStage, errorStage]) s.hidden = true
    stage.hidden = false
  }

  function showError(msg: string) {
    errorMsg.textContent = msg
    showStage(errorStage)
  }

  dlBtn.addEventListener('click', startDownload)
  retryBtn.addEventListener('click', startDownload)

  async function startDownload() {
    showStage(progressStage)
    const ring = createProgressRing()
    progressContainer.innerHTML = ''
    progressContainer.appendChild(ring.canvas)
    statusText.textContent = 'Downloading…'

    const backend = createCryptoBackend()
    const agent = newXFTPAgent()

    try {
      const resolvedFd = await downloadFileRaw(agent, fd, async (raw) => {
        await backend.decryptAndStoreChunk(
          raw.dhSecret, raw.nonce, raw.body, raw.digest, raw.chunkNo
        )
      }, {
        onProgress: (downloaded, total) => {
          ring.update(downloaded / total * 0.8)
        }
      })

      statusText.textContent = 'Decrypting…'
      ring.update(0.85)

      const {header, content} = await backend.verifyAndDecrypt({
        size: resolvedFd.size,
        digest: resolvedFd.digest,
        key: resolvedFd.key,
        nonce: resolvedFd.nonce
      })

      ring.update(0.95)

      // Sanitize filename and trigger browser save
      const fileName = sanitizeFileName(header.fileName)
      const blob = new Blob([content.buffer as ArrayBuffer])
      const url = URL.createObjectURL(blob)
      const a = document.createElement('a')
      a.href = url
      a.download = encodeURIComponent(fileName)
      a.style.display = 'none'
      document.body.appendChild(a)
      a.click()
      document.body.removeChild(a)
      setTimeout(() => URL.revokeObjectURL(url), 1000)

      ring.update(1)
      statusText.textContent = 'Download complete'
    } catch (err: any) {
      showError(err?.message ?? String(err))
    } finally {
      await backend.cleanup().catch(() => {})
      closeXFTPAgent(agent)
    }
  }
}

function sanitizeFileName(name: string): string {
  let s = name
  // Strip path separators
  s = s.replace(/[/\\]/g, '')
  // Replace null/control characters
  s = s.replace(/[\x00-\x1f\x7f]/g, '_')
  // Strip Unicode bidi override characters
  s = s.replace(/[\u202a-\u202e\u2066-\u2069]/g, '')
  // Limit length
  if (s.length > 255) s = s.slice(0, 255)
  return s || 'download'
}

function formatSize(bytes: number): string {
  if (bytes < 1024) return bytes + ' B'
  if (bytes < 1024 * 1024) return (bytes / 1024).toFixed(1) + ' KB'
  return (bytes / (1024 * 1024)).toFixed(1) + ' MB'
}
