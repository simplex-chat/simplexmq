import {defineConfig} from '@playwright/test'

export default defineConfig({
  testDir: './test',
  testMatch: '**/*.spec.ts',
  timeout: 60_000,
  use: {
    ignoreHTTPSErrors: true,
    launchOptions: {
      // --ignore-certificate-errors makes fetch() accept self-signed certs
      args: [
        '--ignore-certificate-errors',
        '--ignore-certificate-errors-spki-list',
        '--allow-insecure-localhost',
      ]
    }
  },
  // Note: globalSetup runs AFTER webServer plugins in playwright 1.58+, so we
  // run setup from the webServer command instead
  globalTeardown: './test/globalTeardown.ts',
  webServer: {
    // Run setup script first (starts XFTP server + proxy), then build, then preview
    command: 'npx tsx test/runSetup.ts && npx vite build --mode development && npx vite preview --mode development',
    url: 'http://localhost:4173',
    reuseExistingServer: false
  },
})
