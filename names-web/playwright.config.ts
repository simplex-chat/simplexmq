import {defineConfig} from "@playwright/test"

const ensContractsDir = process.env.ENS_CONTRACTS_DIR

export default defineConfig({
  testDir: "./test",
  use: {baseURL: "http://localhost:4173"},
  webServer: [
    {
      command: "npx vite build && npx vite preview",
      url: "http://localhost:4173",
    },
    ...(ensContractsDir ? [{command: "npx hardhat node --port 8645", cwd: ensContractsDir, port: 8645}] : []),
  ],
})
