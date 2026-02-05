import {parseXFTPServer, type XFTPServer} from '../src/protocol/address.js'
import presets from './servers.json'

declare const __XFTP_SERVERS__: string[]

const serverAddresses: string[] = typeof __XFTP_SERVERS__ !== 'undefined'
  ? __XFTP_SERVERS__
  : [...presets.simplex, ...presets.flux]

export function getServers(): XFTPServer[] {
  return serverAddresses.map(parseXFTPServer)
}

export function pickRandomServer(servers: XFTPServer[]): XFTPServer {
  return servers[Math.floor(Math.random() * servers.length)]
}
