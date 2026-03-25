import {defineConfig} from "vitest/config"
import path from "path"

export default defineConfig({
  resolve: {
    alias: {
      "@simplex-chat/xftp-web/dist": path.resolve(__dirname, "../xftp-web/src"),
      // xftp-web's keys.ts imports @noble/curves/ed448 (without .js, v1 style)
      // but smp-web has @noble/curves v2 which requires .js in export map.
      // Alias both bare and .js imports to the actual files.
      "@noble/curves/ed25519": path.resolve(__dirname, "node_modules/@noble/curves/ed25519.js"),
      "@noble/curves/ed448": path.resolve(__dirname, "node_modules/@noble/curves/ed448.js"),
    },
  },
  test: {
    include: ["src/__tests__/**/*.test.ts"],
  },
})
