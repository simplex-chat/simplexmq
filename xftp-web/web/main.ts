import sodium from 'libsodium-wrappers-sumo'
import {initUpload} from './upload.js'
import {initDownload} from './download.js'
import {t} from './i18n.js'

function getAppElement(): HTMLElement | null {
  return (document.querySelector('[data-xftp-app]') as HTMLElement | null) ?? document.getElementById('app')
}

async function main() {
  await sodium.ready

  const app = getAppElement()
  if (!app?.hasAttribute('data-defer-init')) {
    initApp()
  }
  if (!app?.hasAttribute('data-no-hashchange')) {
    window.addEventListener('hashchange', initApp)
  }
}

function initApp() {
  const app = getAppElement()!
  const hash = window.location.hash.slice(1)

  if (hash) {
    initDownload(app, hash)
  } else {
    initUpload(app)
  }
}

;(window as any).__xftp_initApp = initApp

main().catch(err => {
  const app = getAppElement()
  if (app) {
    app.innerHTML = `<div class="error"><p>${t('initError', 'Failed to initialize: %error%').replace('%error%', err.message)}</p></div>`
  }
  console.error(err)
})
