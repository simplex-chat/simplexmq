import {spawn, execSync, ChildProcess} from 'child_process'
import {createHash} from 'crypto'
import {createConnection} from 'net'
import {resolve, join} from 'path'
import {readFileSync, mkdtempSync, writeFileSync, copyFileSync, existsSync, unlinkSync} from 'fs'
import {tmpdir} from 'os'

const XFTP_PORT = 7000
const LOCK_FILE = join(tmpdir(), 'xftp-test-server.pid')

let server: ChildProcess | null = null
let isOwner = false

// Kill any process listening on the given port (cross-platform)
function killProcessOnPort(port: number): void {
  try {
    // Try lsof first (common on Mac/Linux)
    execSync(`lsof -ti :${port} | xargs kill -9 2>/dev/null`, {stdio: 'ignore'})
    return
  } catch (_) {}
  try {
    // Fallback: use netstat + awk (works on most systems)
    const cmd = process.platform === 'darwin'
      ? `netstat -anv -p tcp | awk '$4 ~ /:${port}$/ && $6 == "LISTEN" {print $9}' | xargs kill -9 2>/dev/null`
      : `ss -tlnp 'sport = :${port}' | awk 'NR>1 {match($0, /pid=([0-9]+)/, a); print a[1]}' | xargs kill -9 2>/dev/null`
    execSync(cmd, {stdio: 'ignore'})
  } catch (_) {}
}

// Check if port is currently in use
function isPortInUse(port: number): Promise<boolean> {
  return new Promise((resolve) => {
    const sock = createConnection({port, host: 'localhost'}, () => {
      sock.destroy()
      resolve(true)
    })
    sock.on('error', () => {
      sock.destroy()
      resolve(false)
    })
  })
}

export async function setup() {
  // Always check if port is in use first, regardless of lock file state
  if (await isPortInUse(XFTP_PORT)) {
    // Check if we have a valid lock file owner
    if (existsSync(LOCK_FILE)) {
      const pid = parseInt(readFileSync(LOCK_FILE, 'utf-8').trim(), 10)
      try {
        process.kill(pid, 0) // check if process exists
        // Lock owner is alive and port is in use — likely a valid running server
        await waitForPort(XFTP_PORT)
        return
      } catch (_) {
        // Lock owner is dead but port is in use — orphaned process
      }
    }
    // Port in use but no valid lock owner — kill the orphaned process
    console.log('[globalSetup] Port in use without valid lock, killing orphaned process...')
    killProcessOnPort(XFTP_PORT)
    await new Promise(r => setTimeout(r, 500))
    // Verify port is now free
    if (await isPortInUse(XFTP_PORT)) {
      throw new Error(`Port ${XFTP_PORT} still in use after cleanup attempt`)
    }
  }

  // Clean up stale lock file if it exists
  if (existsSync(LOCK_FILE)) {
    const pid = parseInt(readFileSync(LOCK_FILE, 'utf-8').trim(), 10)
    try {
      process.kill(pid, 0)
      // Process exists and port wasn't in use — wait for it
      await waitForPort(XFTP_PORT)
      return
    } catch (_) {
      unlinkSync(LOCK_FILE)
    }
  }

  writeFileSync(LOCK_FILE, String(process.pid))
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
port: ${XFTP_PORT}

[FILES]
path: ${filesDir}

[WEB]
cert: ${join(fixtures, 'web.crt')}
key: ${join(fixtures, 'web.key')}
`
  writeFileSync(join(cfgDir, 'file-server.ini'), iniContent)

  // Resolve binary path once (avoids cabal rebuild check on every run)
  const serverBin = execSync('cabal -v0 list-bin xftp-server', {encoding: 'utf-8'}).trim()

  // Spawn xftp-server directly
  server = spawn(serverBin, ['start'], {
    env: {
      ...process.env,
      XFTP_SERVER_CFG_PATH: cfgDir,
      XFTP_SERVER_LOG_PATH: logDir
    },
    stdio: ['ignore', 'pipe', 'pipe']
  })

  server.stderr?.on('data', (data: Buffer) => {
    console.error('[xftp-server]', data.toString())
  })

  // Poll-connect until the server is actually listening
  await waitForServerReady(server, XFTP_PORT)
}

export async function teardown() {
  if (isOwner) {
    try { unlinkSync(LOCK_FILE) } catch (_) {}
    if (server) {
      server.kill('SIGTERM')
      await new Promise<void>(resolve => {
        server!.on('exit', () => resolve())
        setTimeout(resolve, 3000)
      })
    }
  }
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
