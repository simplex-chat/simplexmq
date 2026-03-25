import {describe, it, expect} from "vitest"
import {
  encodeSMPClientHandshake,
  decodeSMPServerHandshake,
  compatibleVRange,
  smpClientVersionRange,
  blockPad,
  blockUnpad,
  constantTimeEqual,
} from "../handshake.js"
import type {VersionRange, SMPClientHandshake} from "../handshake.js"
import {SMPTransportError} from "../types.js"
import {SMP_BLOCK_SIZE} from "../transport.js"

describe("encodeSMPClientHandshake", () => {
  it("produces a 16384-byte block", () => {
    const ch: SMPClientHandshake = {
      smpVersion: 7,
      keyHash: new Uint8Array(32).fill(0xab),
    }
    const block = encodeSMPClientHandshake(ch)
    expect(block.length).toBe(SMP_BLOCK_SIZE)
  })

  it("encodes version and keyHash correctly", () => {
    const keyHash = new Uint8Array(32)
    keyHash[0] = 0xde
    keyHash[31] = 0xad
    const ch: SMPClientHandshake = {smpVersion: 7, keyHash}
    const block = encodeSMPClientHandshake(ch)

    // blockUnpad to get the content
    const content = blockUnpad(block)
    // Content: Word16(version=7) + shortString(keyHash)
    // Word16(7) = [0x00, 0x07]
    expect(content[0]).toBe(0x00)
    expect(content[1]).toBe(0x07)
    // shortString: [length=32] + 32 bytes
    expect(content[2]).toBe(32)
    expect(content[3]).toBe(0xde)
    expect(content[34]).toBe(0xad)
    // Total content length: 2 (version) + 1 (len prefix) + 32 (hash) = 35
    expect(content.length).toBe(35)
  })

  it("encodes version 6 correctly", () => {
    const ch: SMPClientHandshake = {
      smpVersion: 6,
      keyHash: new Uint8Array(32),
    }
    const block = encodeSMPClientHandshake(ch)
    const content = blockUnpad(block)
    // Word16(6) = [0x00, 0x06]
    expect(content[0]).toBe(0x00)
    expect(content[1]).toBe(0x06)
  })
})

describe("decodeSMPServerHandshake", () => {
  it("rejects short error blocks with HANDSHAKE error", () => {
    // Simulate server sending "HANDSHAKE" as an error response
    const errorText = new TextEncoder().encode("HANDSHAKE")
    const block = blockPad(errorText)
    expect(() => decodeSMPServerHandshake(block)).toThrow(SMPTransportError)
    try {
      decodeSMPServerHandshake(block)
    } catch (e) {
      expect(e).toBeInstanceOf(SMPTransportError)
      expect((e as SMPTransportError).code).toBe("HANDSHAKE")
      expect((e as SMPTransportError).message).toContain("HANDSHAKE")
    }
  })

  it("rejects SESSION error blocks", () => {
    const errorText = new TextEncoder().encode("SESSION")
    const block = blockPad(errorText)
    expect(() => decodeSMPServerHandshake(block)).toThrow(SMPTransportError)
    try {
      decodeSMPServerHandshake(block)
    } catch (e) {
      expect((e as SMPTransportError).code).toBe("HANDSHAKE")
      expect((e as SMPTransportError).message).toContain("SESSION")
    }
  })
})

describe("compatibleVRange", () => {
  it("negotiates SMP v6/v7 range correctly", () => {
    // Server supports v6-v7, client supports v6-v7
    const serverRange: VersionRange = {minVersion: 6, maxVersion: 7}
    const result = compatibleVRange(serverRange, smpClientVersionRange)
    expect(result).not.toBeNull()
    expect(result!.minVersion).toBe(6)
    expect(result!.maxVersion).toBe(7)
  })

  it("negotiates when server only supports v7", () => {
    const serverRange: VersionRange = {minVersion: 7, maxVersion: 7}
    const result = compatibleVRange(serverRange, smpClientVersionRange)
    expect(result).not.toBeNull()
    expect(result!.maxVersion).toBe(7)
  })

  it("negotiates when server only supports v6", () => {
    const serverRange: VersionRange = {minVersion: 6, maxVersion: 6}
    const result = compatibleVRange(serverRange, smpClientVersionRange)
    expect(result).not.toBeNull()
    expect(result!.maxVersion).toBe(6)
  })

  it("returns null for incompatible version (server min=8)", () => {
    const serverRange: VersionRange = {minVersion: 8, maxVersion: 10}
    const result = compatibleVRange(serverRange, smpClientVersionRange)
    expect(result).toBeNull()
  })

  it("returns null for incompatible version (server max=5)", () => {
    const serverRange: VersionRange = {minVersion: 3, maxVersion: 5}
    const result = compatibleVRange(serverRange, smpClientVersionRange)
    expect(result).toBeNull()
  })

  it("selects highest mutual version", () => {
    // Server supports v5-v8, client supports v6-v7
    const serverRange: VersionRange = {minVersion: 5, maxVersion: 8}
    const result = compatibleVRange(serverRange, smpClientVersionRange)
    expect(result).not.toBeNull()
    // Should select v7 (highest mutual)
    expect(result!.maxVersion).toBe(7)
  })
})

describe("blockPad/blockUnpad roundtrip", () => {
  it("pads to exactly 16384 bytes and unpads correctly", () => {
    const msg = new Uint8Array([1, 2, 3, 4, 5])
    const padded = blockPad(msg)
    expect(padded.length).toBe(SMP_BLOCK_SIZE)
    const unpadded = blockUnpad(padded)
    expect(unpadded).toEqual(msg)
  })

  it("fills padding with '#' (0x23)", () => {
    const msg = new Uint8Array([0xaa])
    const padded = blockPad(msg)
    // Content starts at byte 2 (after 2-byte length prefix)
    // Message is at byte 2, padding starts at byte 3
    expect(padded[3]).toBe(0x23)
    expect(padded[SMP_BLOCK_SIZE - 1]).toBe(0x23)
  })
})

describe("constantTimeEqual", () => {
  it("returns true for equal arrays", () => {
    const a = new Uint8Array([1, 2, 3])
    const b = new Uint8Array([1, 2, 3])
    expect(constantTimeEqual(a, b)).toBe(true)
  })

  it("returns false for different arrays", () => {
    const a = new Uint8Array([1, 2, 3])
    const b = new Uint8Array([1, 2, 4])
    expect(constantTimeEqual(a, b)).toBe(false)
  })

  it("returns false for different lengths", () => {
    const a = new Uint8Array([1, 2])
    const b = new Uint8Array([1, 2, 3])
    expect(constantTimeEqual(a, b)).toBe(false)
  })
})
