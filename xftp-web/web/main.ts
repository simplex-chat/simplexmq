import sodium from 'libsodium-wrappers-sumo'
import {initUpload} from './upload.js'
import {initDownload} from './download.js'

async function main() {
  await sodium.ready
  initApp()

  // Handle hash changes (SPA navigation)
  window.addEventListener('hashchange', initApp)
}

function initApp() {
  const app = document.getElementById('app')!
  const hash = window.location.hash.slice(1)

  if (hash) {
    initDownload(app, hash)
  } else {
    initUpload(app)
  }
}

main().catch(err => {
  const app = document.getElementById('app')
  if (app) {
    app.innerHTML = `<div class="error"><p>Failed to initialize: ${err.message}</p></div>`
  }
  console.error(err)
})
