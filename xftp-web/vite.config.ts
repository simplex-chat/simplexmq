import {defineConfig, type Plugin, type PreviewServer} from 'vite'
import {readFileSync} from 'fs'
import {createHash} from 'crypto'
import {resolve, join} from 'path'
import {tmpdir} from 'os'
import * as http2 from 'http2'
import presets from './web/servers.json'

const PORT_FILE = join(tmpdir(), 'xftp-test-server.port')

const __dirname = import.meta.dirname

function parseHost(addr: string): string {
  const m = addr.match(/@(.+)$/)
  if (!m) throw new Error('bad server address: ' + addr)
  const host = m[1].split(',')[0]
  return host.includes(':') ? host : host + ':443'
}

function cspPlugin(servers: string[]): Plugin {
  const origins = servers.map(s => 'https://' + parseHost(s)).join(' ')
  return {
    name: 'csp-connect-src',
    transformIndexHtml: {
      order: 'pre',
      handler(html, ctx) {
        if (ctx.server) {
          return html.replace(/<meta\s[^>]*?Content-Security-Policy[\s\S]*?>/i, '')
        }
        return html.replace('__CSP_CONNECT_SRC__', origins)
      }
    }
  }
}

// Compute fingerprint from ca.crt (SHA-256 of DER)
function getFingerprint(): string {
  const pem = readFileSync('../tests/fixtures/ca.crt', 'utf-8')
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

// HTTP/2 proxy plugin for dev/test mode
// Routes /xftp-proxy to the XFTP server using HTTP/2
function xftpH2ProxyPlugin(): Plugin {
  let h2Session: http2.ClientHttp2Session | null = null
  let xftpPort: number | null = null

  function getSession(): http2.ClientHttp2Session {
    if (h2Session && !h2Session.closed && !h2Session.destroyed) {
      return h2Session
    }
    if (!xftpPort) {
      xftpPort = parseInt(readFileSync(PORT_FILE, 'utf-8').trim(), 10)
    }
    h2Session = http2.connect(`https://localhost:${xftpPort}`, {
      rejectUnauthorized: false
    })
    h2Session.on('error', (err) => {
      console.error('[h2proxy]', err.message)
    })
    return h2Session
  }

  return {
    name: 'xftp-h2-proxy',
    configurePreviewServer(server: PreviewServer) {
      console.log('[xftp-h2-proxy] Plugin registered')
      server.middlewares.use('/xftp-proxy', (req, res, next) => {
        console.log('[xftp-h2-proxy] Request:', req.method, req.url)
        // Handle CORS preflight
        if (req.method === 'OPTIONS') {
          res.writeHead(204, {
            'Access-Control-Allow-Origin': '*',
            'Access-Control-Allow-Methods': 'POST, OPTIONS',
            'Access-Control-Allow-Headers': 'Content-Type',
            'Access-Control-Max-Age': '86400'
          })
          res.end()
          return
        }
        if (req.method !== 'POST') {
          return next()
        }
        const chunks: Buffer[] = []
        req.on('data', (chunk: Buffer) => chunks.push(chunk))
        req.on('end', () => {
          const body = Buffer.concat(chunks)
          let session: http2.ClientHttp2Session
          try {
            session = getSession()
          } catch (e) {
            res.writeHead(502)
            res.end('Proxy error: failed to connect to upstream')
            return
          }
          const h2req = session.request({
            ':method': 'POST',
            ':path': '/',
            'content-type': 'application/octet-stream',
            'content-length': body.length
          })
          const resChunks: Buffer[] = []
          let statusCode = 200
          h2req.on('response', (headers) => {
            statusCode = (headers[':status'] as number) || 200
          })
          h2req.on('data', (chunk: Buffer) => resChunks.push(chunk))
          h2req.on('end', () => {
            res.writeHead(statusCode, {
              'Content-Type': 'application/octet-stream',
              'Access-Control-Allow-Origin': '*',
            })
            res.end(Buffer.concat(resChunks))
          })
          h2req.on('error', (e) => {
            res.writeHead(502)
            res.end('Proxy error: ' + e.message)
          })
          h2req.write(body)
          h2req.end()
        })
      })
    }
  }
}

// Plugin to inject proxy path for dev mode (uses /xftp-proxy endpoint)
function xftpProxyDefinePlugin(): Plugin {
  return {
    name: 'xftp-proxy-define',
    transform(code, _id) {
      if (!code.includes('__XFTP_PROXY_PORT__')) return null
      // Use relative path for proxy - vite preview handles it
      return code.replace(/__XFTP_PROXY_PORT__/g, JSON.stringify('proxy'))
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
    plugins.push(xftpProxyDefinePlugin())
    plugins.push(xftpH2ProxyPlugin())
    // For CSP plugin, use localhost placeholder (CSP stripped in dev server anyway)
    servers = ['xftp://fp@localhost:443']
  } else {
    // In production mode, use the preset servers
    servers = [...presets.simplex, ...presets.flux]
    define['__XFTP_SERVERS__'] = JSON.stringify(servers)
    define['__XFTP_PROXY_PORT__'] = JSON.stringify(null)
  }

  plugins.push(cspPlugin(servers))

  return {
    root: 'web',
    build: {outDir: resolve(__dirname, 'dist-web'), target: 'esnext'},
    preview: {host: true},
    define,
    worker: {format: 'es' as const},
    plugins,
  }
})
