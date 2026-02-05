import {createCryptoBackend} from './crypto-backend.js'
import {getServers, pickRandomServer} from './servers.js'
import {createProgressRing} from './progress.js'
import {
  newXFTPAgent, closeXFTPAgent, uploadFile, encodeDescriptionURI,
  type EncryptedFileMetadata
} from '../src/agent.js'

const MAX_SIZE = 100 * 1024 * 1024

export function initUpload(app: HTMLElement) {
  app.innerHTML = `
    <div class="card">
      <h1>SimpleX File Transfer</h1>
      <div id="drop-zone" class="drop-zone">
        <p>Drag & drop a file here</p>
        <p class="hint">or</p>
        <label class="btn" for="file-input">Choose file</label>
        <input id="file-input" type="file" hidden>
        <p class="hint">Max 100 MB</p>
      </div>
      <div id="upload-progress" class="stage" hidden>
        <div id="progress-container"></div>
        <p id="upload-status">Encrypting…</p>
        <button id="cancel-btn" class="btn btn-secondary">Cancel</button>
      </div>
      <div id="upload-complete" class="stage" hidden>
        <p class="success">File uploaded</p>
        <div class="link-row">
          <input id="share-link" data-testid="share-link" readonly>
          <button id="copy-btn" class="btn">Copy</button>
        </div>
        <p class="hint expiry">Files are typically available for 48 hours.</p>
        <div class="security-note">
          <p>Your file was encrypted in the browser before upload — the server never sees file contents.</p>
          <p>The link contains the decryption key in the hash fragment, which the browser never sends to any server.</p>
          <p>For maximum security, use the <a href="https://simplex.chat" target="_blank" rel="noopener">SimpleX app</a>.</p>
        </div>
      </div>
      <div id="upload-error" class="stage" hidden>
        <p class="error" id="error-msg"></p>
        <button id="retry-btn" class="btn">Retry</button>
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
    if (pendingFile) startUpload(pendingFile)
  })

  function showStage(stage: HTMLElement) {
    for (const s of [dropZone, progressStage, completeStage, errorStage]) s.hidden = true
    stage.hidden = false
  }

  function showError(msg: string) {
    errorMsg.textContent = msg
    showStage(errorStage)
  }

  async function startUpload(file: File) {
    pendingFile = file
    aborted = false

    if (file.size > MAX_SIZE) {
      showError(`File too large (${formatSize(file.size)}). Maximum is 100 MB.`)
      return
    }
    if (file.size === 0) {
      showError('File is empty.')
      return
    }

    showStage(progressStage)
    const ring = createProgressRing()
    progressContainer.innerHTML = ''
    progressContainer.appendChild(ring.canvas)
    statusText.textContent = 'Encrypting…'

    const backend = createCryptoBackend()
    const agent = newXFTPAgent()

    cancelBtn.onclick = () => {
      aborted = true
      backend.cleanup().catch(() => {})
      closeXFTPAgent(agent)
      showStage(dropZone)
    }

    try {
      const fileData = new Uint8Array(await file.arrayBuffer())
      if (aborted) return

      const encrypted = await backend.encrypt(fileData, file.name, (done, total) => {
        ring.update(done / total * 0.3)
      })
      if (aborted) return

      statusText.textContent = 'Uploading…'
      const metadata: EncryptedFileMetadata = {
        digest: encrypted.digest,
        key: encrypted.key,
        nonce: encrypted.nonce,
        chunkSizes: encrypted.chunkSizes
      }
      const servers = getServers()
      const server = pickRandomServer(servers)
      const result = await uploadFile(agent, server, metadata, {
        readChunk: (off, sz) => backend.readChunk(off, sz),
        onProgress: (uploaded, total) => {
          ring.update(0.3 + (uploaded / total) * 0.7)
        }
      })
      if (aborted) return

      const url = window.location.origin + window.location.pathname + '#' + result.uri
      shareLink.value = url
      showStage(completeStage)
      copyBtn.onclick = () => {
        navigator.clipboard.writeText(url).then(() => {
          copyBtn.textContent = 'Copied!'
          setTimeout(() => { copyBtn.textContent = 'Copy' }, 2000)
        })
      }
    } catch (err: any) {
      if (!aborted) showError(err?.message ?? String(err))
    } finally {
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
