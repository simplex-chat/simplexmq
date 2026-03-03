// Helper script to run globalSetup synchronously before vite build
import setup from './globalSetup.js'

await setup()
console.log('[runSetup] Setup complete')
