import {defineConfig, type Plugin} from 'vite'
import {readFileSync} from 'fs'
import {createHash} from 'crypto'
import presets from './web/servers.json'
import {PORT_FILE} from './test/globalSetup'

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

export default defineConfig(({mode}) => {
  const define: Record<string, string> = {}
  let servers: string[]

  if (mode === 'development') {
    const pem = readFileSync('../tests/fixtures/ca.crt', 'utf-8')
    const der = Buffer.from(pem.replace(/-----[^-]+-----/g, '').replace(/\s/g, ''), 'base64')
    const fp = createHash('sha256').update(der).digest('base64')
      .replace(/\+/g, '-').replace(/\//g, '_')
    // PORT_FILE is written by globalSetup before vite build runs
    const port = readFileSync(PORT_FILE, 'utf-8').trim()
    servers = [`xftp://${fp}@localhost:${port}`]
    define['__XFTP_SERVERS__'] = JSON.stringify(servers)
  } else {
    servers = [...presets.simplex, ...presets.flux]
  }

  return {
    root: 'web',
    build: {outDir: '../dist-web', target: 'esnext'},
    define,
    worker: {format: 'es' as const},
    plugins: [cspPlugin(servers)],
  }
})
