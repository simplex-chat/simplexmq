import sodium from 'libsodium-wrappers-sumo'
import {initUpload} from './upload.js'
import {initDownload} from './download.js'
import {decodeDescriptionURI} from '../src/agent.js'
import {t} from './i18n.js'

function getAppElement(): HTMLElement | null {
  return (document.querySelector('[data-xftp-app]') as HTMLElement | null) ?? document.getElementById('app')
}

const wasmReady = sodium.ready

async function main() {
  // Render UI immediately — no WASM needed for HTML + event listeners.
  // WASM is only used later when user triggers upload/download.
  const app = getAppElement()
  if (!app?.hasAttribute('data-defer-init')) {
    initApp()
  }
  if (!app?.hasAttribute('data-no-hashchange')) {
    window.addEventListener('hashchange', () => {
      const hash = window.location.hash.slice(1)
      if (!hash || isXFTPHash(hash)) initApp()
    })
  }
  await wasmReady
  app?.dispatchEvent(new CustomEvent('xftp:ready', {bubbles: true}))
}

function isXFTPHash(hash: string): boolean {
  try { decodeDescriptionURI(hash); return true } catch { return false }
}

function initApp() {
  const app = getAppElement()!
  const hash = window.location.hash.slice(1)

  if (hash && isXFTPHash(hash)) {
    initDownload(app, hash)
  } else {
    initUpload(app)
  }
}

;(window as any).__xftp_initApp = async () => { await wasmReady; initApp() }

main().catch(err => {
  const app = getAppElement()
  if (app) {
    app.innerHTML = `<div class="error"><p>${t('initError', 'Failed to initialize: %error%').replace('%error%', err.message)}</p></div>`
  }
  console.error(err)
})
