import {parseXFTPServer, type XFTPServer} from '../src/protocol/address.js'

// __XFTP_SERVERS__ is injected at build time by vite.config.ts
// In development mode: test server from globalSetup
// In production mode: preset servers from servers.json
declare const __XFTP_SERVERS__: string[]

const serverAddresses: string[] = __XFTP_SERVERS__

export function getServers(): XFTPServer[] {
  const addrs = (window as any).__XFTP_SERVERS__ ?? serverAddresses
  return addrs.map(parseXFTPServer)
}
