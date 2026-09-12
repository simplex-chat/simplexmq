import {expect, test} from 'vitest'
import {formatXFTPServer, parseXFTPServer, serverOrigin} from '../src/protocol/address.js'

const keyHash = 'LcJUMfVhwD8yxjAiSaDzzGF3-kLG4Uh0Fl_ZIjrRwjI='

test('parseXFTPServer supports bracketed IPv6 hosts with ports', () => {
  const server = parseXFTPServer(`xftp://${keyHash}@[2001:db8::1]:8443,example.com`)

  expect(server.host).toBe('[2001:db8::1]')
  expect(server.port).toBe('8443')
  expect(serverOrigin(server)).toBe('https://[2001:db8::1]:8443')
  expect(formatXFTPServer(server)).toBe(`xftp://${keyHash}@[2001:db8::1]:8443`)
})

test('parseXFTPServer uses the default port for bracketed IPv6 hosts', () => {
  const server = parseXFTPServer(`xftp://${keyHash}@[2001:db8::1]`)

  expect(server.host).toBe('[2001:db8::1]')
  expect(server.port).toBe('443')
  expect(serverOrigin(server)).toBe('https://[2001:db8::1]')
})

test('parseXFTPServer preserves a list-level port with IPv6 first', () => {
  const server = parseXFTPServer(`xftp://${keyHash}@[2001:db8::1],example.com:5223`)

  expect(server.host).toBe('[2001:db8::1]')
  expect(server.port).toBe('5223')
  expect(formatXFTPServer(server)).toBe(`xftp://${keyHash}@[2001:db8::1]:5223`)
})

test('parseXFTPServer preserves a list-level port with IPv6 last', () => {
  const server = parseXFTPServer(`xftp://${keyHash}@example.com,[2001:db8::1]:5223`)

  expect(server.host).toBe('example.com')
  expect(server.port).toBe('5223')
  expect(formatXFTPServer(server)).toBe(`xftp://${keyHash}@example.com:5223`)
})
