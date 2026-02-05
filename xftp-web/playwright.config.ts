import {defineConfig} from '@playwright/test'

export default defineConfig({
  testDir: './test',
  testMatch: '**/*.spec.ts',
  timeout: 60_000,
  use: {
    ignoreHTTPSErrors: true,
    launchOptions: {
      args: ['--ignore-certificate-errors']
    }
  },
  webServer: {
    command: 'npx vite build --mode development && npx vite preview',
    url: 'http://localhost:4173',
    reuseExistingServer: !process.env.CI
  },
  globalSetup: './test/globalSetup.ts'
})
