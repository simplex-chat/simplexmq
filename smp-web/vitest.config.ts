import {defineConfig} from "vitest/config"
import path from "path"

export default defineConfig({
  resolve: {
    alias: {
      "@simplex-chat/xftp-web/dist": path.resolve(__dirname, "../xftp-web/src"),
    },
  },
  test: {
    include: ["src/__tests__/**/*.test.ts"],
  },
})
