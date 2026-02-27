import {defineConfig, type Plugin} from 'vitest/config'
import {readFileSync} from 'fs'
import {createHash} from 'crypto'
import {PORT_FILE} from './test/globalSetup'

// Compute fingerprint from ca.crt (SHA-256 of DER, same as Haskell's loadFileFingerprint)
const pem = readFileSync('../tests/fixtures/ca.crt', 'utf-8')
const der = Buffer.from(pem.replace(/-----[^-]+-----/g, '').replace(/\s/g, ''), 'base64')
const fingerprint = createHash('sha256').update(der).digest('base64').replace(/\+/g, '-').replace(/\//g, '_')

// Plugin to inject XFTP_SERVER at transform time (after globalSetup writes PORT_FILE)
function xftpServerPlugin(): Plugin {
  let serverAddr: string | null = null
  return {
    name: 'xftp-server-define',
    transform(code, id) {
      if (!code.includes('import.meta.env.XFTP_SERVER')) return null
      if (!serverAddr) {
        const port = readFileSync(PORT_FILE, 'utf-8').trim()
        serverAddr = `xftp://${fingerprint}@localhost:${port}`
      }
      return code.replace(/import\.meta\.env\.XFTP_SERVER/g, JSON.stringify(serverAddr))
    }
  }
}

export default defineConfig({
  esbuild: {target: 'esnext'},
  optimizeDeps: {esbuildOptions: {target: 'esnext'}},
  plugins: [xftpServerPlugin()],
  test: {
    include: ['test/**/*.test.ts'],
    exclude: ['test/**/*.node.test.ts'],
    browser: {
      enabled: true,
      provider: 'playwright',
      instances: [{browser: 'chromium'}],
      headless: true
    },
    globalSetup: './test/globalSetup.ts'
  }
})
