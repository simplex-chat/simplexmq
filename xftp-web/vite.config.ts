import {defineConfig, type Plugin} from 'vite'
import {readFileSync} from 'fs'
import {createHash} from 'crypto'
import {resolve, join} from 'path'
import {tmpdir} from 'os'
import presets from './web/servers.json'

const PORT_FILE = join(tmpdir(), 'xftp-test-server.port')
const FIXTURES = resolve(import.meta.dirname, '../tests/fixtures')

const __dirname = import.meta.dirname

function parseHost(addr: string): string {
  const m = addr.match(/@(.+)$/)
  if (!m) throw new Error('bad server address: ' + addr)
  const host = m[1].split(',')[0]
  return host.includes(':') ? host : host + ':443'
}

function cspPlugin(servers: string[], isDev: boolean): Plugin {
  const origins = servers.map(s => 'https://' + parseHost(s)).join(' ')
  return {
    name: 'csp-connect-src',
    transformIndexHtml: {
      order: 'pre',
      handler(html) {
        if (isDev) {
          return html.replace(/<meta\s[^>]*?Content-Security-Policy[\s\S]*?>/i, '')
        }
        return html.replace('__CSP_CONNECT_SRC__', origins)
      }
    }
  }
}

// Compute fingerprint from ca.crt (SHA-256 of DER)
function getFingerprint(): string {
  const pem = readFileSync(join(FIXTURES, 'ca.crt'), 'utf-8')
  const der = Buffer.from(pem.replace(/-----[^-]+-----/g, '').replace(/\s/g, ''), 'base64')
  return createHash('sha256').update(der).digest('base64')
    .replace(/\+/g, '-').replace(/\//g, '_')
}

// Plugin to inject __XFTP_SERVERS__ lazily (reads PORT_FILE written by test/runSetup.ts)
function xftpServersPlugin(): Plugin {
  let serverAddr: string | null = null
  const fp = getFingerprint()
  return {
    name: 'xftp-servers-define',
    transform(code, _id) {
      if (!code.includes('__XFTP_SERVERS__')) return null
      if (!serverAddr) {
        const port = readFileSync(PORT_FILE, 'utf-8').trim()
        serverAddr = `xftp://${fp}@localhost:${port}`
      }
      return code.replace(/__XFTP_SERVERS__/g, JSON.stringify([serverAddr]))
    }
  }
}

export default defineConfig(({mode}) => {
  const define: Record<string, string> = {}
  let servers: string[]
  const plugins: Plugin[] = []

  if (mode === 'development') {
    // In development mode, use the test server (port from globalSetup)
    plugins.push(xftpServersPlugin())
    define['__XFTP_PROXY_PORT__'] = JSON.stringify(null)
    // For CSP plugin, use localhost placeholder (CSP stripped in dev server anyway)
    servers = ['xftp://fp@localhost:443']
  } else {
    // In production mode, use the preset servers
    servers = [...presets.simplex, ...presets.flux]
    define['__XFTP_SERVERS__'] = JSON.stringify(servers)
    define['__XFTP_PROXY_PORT__'] = JSON.stringify(null)
  }

  plugins.push(cspPlugin(servers, mode === 'development'))

  const httpsConfig = mode === 'development' ? {
    key: readFileSync(join(FIXTURES, 'web.key')),
    cert: readFileSync(join(FIXTURES, 'web.crt')),
  } : undefined

  return {
    root: 'web',
    build: {outDir: resolve(__dirname, 'dist-web'), target: 'esnext'},
    server: httpsConfig ? {https: httpsConfig} : {},
    preview: {host: true, https: false},
    define,
    worker: {format: 'es' as const},
    plugins,
  }
})
