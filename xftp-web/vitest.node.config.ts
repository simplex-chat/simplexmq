import {defineConfig} from 'vitest/config'

export default defineConfig({
  esbuild: {target: 'esnext'},
  test: {
    include: ['test/**/*.node.test.ts'],
    testTimeout: 30000
  }
})
