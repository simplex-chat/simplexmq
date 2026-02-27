import {spawn, ChildProcess} from 'child_process'
import {createHash} from 'crypto'
import {createConnection, createServer} from 'net'
import {resolve, join, dirname} from 'path'
import {fileURLToPath} from 'url'
import {readFileSync, mkdtempSync, writeFileSync, copyFileSync, existsSync, unlinkSync, openSync} from 'fs'
import {tmpdir} from 'os'

const __filename = fileURLToPath(import.meta.url)
const __dirname = dirname(__filename)

const LOCK_FILE = join(tmpdir(), 'xftp-test-server.lock')
const SERVER_PID_FILE = join(tmpdir(), 'xftp-test-server.pid')
export const PORT_FILE = join(tmpdir(), 'xftp-test-server.port')

// Find a free port by binding to port 0
function findFreePort(): Promise<number> {
  return new Promise((resolve, reject) => {
    const srv = createServer()
    srv.listen(0, '127.0.0.1', () => {
      const addr = srv.address()
      if (addr && typeof addr === 'object') {
        const port = addr.port
        srv.close(() => resolve(port))
      } else {
        srv.close(() => reject(new Error('Could not get port')))
      }
    })
    srv.on('error', reject)
  })
}

let server: ChildProcess | null = null
let isOwner = false

async function setup() {
  // Kill any stale server from a previous run (negative PID kills process group)
  if (existsSync(SERVER_PID_FILE)) {
    try {
      const serverPid = parseInt(readFileSync(SERVER_PID_FILE, 'utf-8').trim(), 10)
      process.kill(-serverPid, 'SIGTERM')
      await new Promise(r => setTimeout(r, 500))
    } catch (_) {}
    try { unlinkSync(LOCK_FILE) } catch (_) {}
    try { unlinkSync(SERVER_PID_FILE) } catch (_) {}
    try { unlinkSync(PORT_FILE) } catch (_) {}
  }

  // Find a free port dynamically
  const xftpPort = await findFreePort()

  writeFileSync(LOCK_FILE, String(process.pid))
  writeFileSync(PORT_FILE, String(xftpPort))
  isOwner = true

  const fixtures = resolve(__dirname, '../../tests/fixtures')

  // Create temp directories
  const cfgDir = mkdtempSync(join(tmpdir(), 'xftp-cfg-'))
  const logDir = mkdtempSync(join(tmpdir(), 'xftp-log-'))
  const filesDir = mkdtempSync(join(tmpdir(), 'xftp-files-'))

  // Copy certificates to cfgDir (xftp-server expects ca.crt, server.key, server.crt there)
  copyFileSync(join(fixtures, 'ca.crt'), join(cfgDir, 'ca.crt'))
  copyFileSync(join(fixtures, 'server.key'), join(cfgDir, 'server.key'))
  copyFileSync(join(fixtures, 'server.crt'), join(cfgDir, 'server.crt'))

  // Write fingerprint file (checkSavedFingerprint reads this on startup)
  // Fingerprint = SHA-256 of DER-encoded certificate (not PEM)
  const pem = readFileSync(join(fixtures, 'ca.crt'), 'utf-8')
  const der = Buffer.from(pem.replace(/-----[^-]+-----/g, '').replace(/\s/g, ''), 'base64')
  const fp = createHash('sha256').update(der).digest('base64').replace(/\+/g, '-').replace(/\//g, '_')
  writeFileSync(join(cfgDir, 'fingerprint'), fp + '\n')

  // Write INI config file
  const iniContent = `[STORE_LOG]
enable: off

[TRANSPORT]
host: localhost
port: ${xftpPort}

[FILES]
path: ${filesDir}

[WEB]
cert: ${join(fixtures, 'web.crt')}
key: ${join(fixtures, 'web.key')}
`
  writeFileSync(join(cfgDir, 'file-server.ini'), iniContent)

  // Redirect server stderr to file so logs survive after setup exits
  const serverLogPath = join(tmpdir(), 'xftp-test-server.log')
  const stderrFd = openSync(serverLogPath, 'w')
  console.log('[runSetup] Server log:', serverLogPath)

  // Spawn via cabal run to always use freshly built code
  server = spawn('cabal', ['run', 'xftp-server', '--', 'start'], {
    env: {
      ...process.env,
      XFTP_SERVER_CFG_PATH: cfgDir,
      XFTP_SERVER_LOG_PATH: logDir
    },
    stdio: ['ignore', 'ignore', stderrFd],
    detached: true
  })

  // Poll-connect until the server is actually listening
  await waitForServerReady(server, xftpPort)

  // Store server PID for teardown
  writeFileSync(SERVER_PID_FILE, String(server.pid))

  server.unref()
}

export async function teardown() {
  // Kill the xftp-server process group if it's running
  if (existsSync(SERVER_PID_FILE)) {
    try {
      const serverPid = parseInt(readFileSync(SERVER_PID_FILE, 'utf-8').trim(), 10)
      process.kill(-serverPid, 'SIGTERM')
      // Wait a bit for graceful shutdown
      await new Promise(r => setTimeout(r, 500))
    } catch (_) {
      // Server already dead
    }
  }
  // Clean up files
  try { unlinkSync(LOCK_FILE) } catch (_) {}
  try { unlinkSync(SERVER_PID_FILE) } catch (_) {}
  try { unlinkSync(PORT_FILE) } catch (_) {}
}

function waitForServerReady(proc: ChildProcess, port: number): Promise<void> {
  return new Promise((resolve, reject) => {
    let settled = false
    const timeout = setTimeout(() => {
      settled = true
      reject(new Error('Server start timeout'))
    }, 15000)
    const settle = (fn: () => void) => { if (!settled) { settled = true; clearTimeout(timeout); fn() } }
    proc.on('error', (e) => settle(() => reject(e)))
    proc.on('exit', (code) => {
      if (code !== 0) settle(() => reject(new Error(`Server exited with code ${code}`)))
    })
    // printXFTPConfig prints "Listening on port" BEFORE bind, so poll-connect
    const poll = () => {
      if (settled) return
      const sock = createConnection({port, host: 'localhost'}, () => {
        sock.destroy()
        settle(() => resolve())
      })
      sock.on('error', () => {
        sock.destroy()
        setTimeout(poll, 100)
      })
    }
    setTimeout(poll, 200)
  })
}

function waitForPort(port: number): Promise<void> {
  return new Promise((resolve, reject) => {
    const deadline = Date.now() + 15000
    const poll = () => {
      if (Date.now() > deadline) return reject(new Error('Timed out waiting for server'))
      const sock = createConnection({port, host: 'localhost'}, () => {
        sock.destroy()
        resolve()
      })
      sock.on('error', () => {
        sock.destroy()
        setTimeout(poll, 100)
      })
    }
    poll()
  })
}

export default setup
