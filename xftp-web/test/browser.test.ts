import {test, expect} from 'vitest'
import {encryptFileForUpload, uploadFile, downloadFile, XFTPAgent} from '../src/agent.js'
import {parseXFTPServer} from '../src/protocol/address.js'

const server = parseXFTPServer(import.meta.env.XFTP_SERVER)

test('browser upload + download round-trip', async () => {
  const agent = new XFTPAgent()
  try {
    const data = new Uint8Array(50000)
    crypto.getRandomValues(data)
    const encrypted = encryptFileForUpload(data, 'test.bin')
    const {rcvDescription} = await uploadFile(agent, server, encrypted)
    const {content} = await downloadFile(agent, rcvDescription)
    expect(content).toEqual(data)
  } finally {
    agent.close()
  }
})
