import {defineConfig} from 'vitest/config'
import {readFileSync} from 'fs'
import {createHash} from 'crypto'

// Compute fingerprint from ca.crt (SHA-256 of DER, same as Haskell's loadFileFingerprint)
const pem = readFileSync('../tests/fixtures/ca.crt', 'utf-8')
const der = Buffer.from(pem.replace(/-----[^-]+-----/g, '').replace(/\s/g, ''), 'base64')
const fingerprint = createHash('sha256').update(der).digest('base64').replace(/\+/g, '-').replace(/\//g, '_')
const serverAddr = `xftp://${fingerprint}@localhost:7000`

export default defineConfig({
  define: {
    'import.meta.env.XFTP_SERVER': JSON.stringify(serverAddr)
  },
  test: {
    include: ['test/**/*.test.ts'],
    browser: {
      enabled: true,
      provider: 'playwright',
      instances: [{browser: 'chromium'}],
      headless: true
    },
    globalSetup: './test/globalSetup.ts'
  }
})
