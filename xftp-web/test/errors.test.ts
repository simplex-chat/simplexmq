import {test, expect} from 'vitest'
import {
  XFTPRetriableError, XFTPPermanentError,
  isRetriable, categorizeError, humanReadableMessage
} from '../src/client.js'

// T1: isRetriable classifies errors correctly
test('isRetriable classifies errors correctly', () => {
  // Retriable:
  expect(isRetriable(new XFTPRetriableError("SESSION"))).toBe(true)
  expect(isRetriable(new XFTPRetriableError("HANDSHAKE"))).toBe(true)
  expect(isRetriable(new TypeError("fetch failed"))).toBe(true)
  expect(isRetriable(Object.assign(new Error(), {name: "AbortError"}))).toBe(true)
  // Not retriable:
  expect(isRetriable(new XFTPPermanentError("AUTH", "..."))).toBe(false)
  expect(isRetriable(new XFTPPermanentError("NO_FILE", "..."))).toBe(false)
  expect(isRetriable(new XFTPPermanentError("INTERNAL", "..."))).toBe(false)
  // Unknown errors are not retriable
  expect(isRetriable(new Error("random"))).toBe(false)
})

// T2: categorizeError produces human-readable messages
test('categorizeError produces human-readable messages', () => {
  const e = categorizeError(new XFTPPermanentError("AUTH", "File is invalid, expired, or has been removed"))
  expect(e.message).toContain("expired")
  // Verify every permanent error type maps to a non-empty human-readable message
  for (const errType of ["AUTH", "NO_FILE", "SIZE", "QUOTA", "BLOCKED", "DIGEST", "INTERNAL"]) {
    expect(humanReadableMessage(errType).length).toBeGreaterThan(0)
  }
  // Retriable errors also get human-readable messages
  const re = categorizeError(new XFTPRetriableError("SESSION"))
  expect(re.message).toContain("expired")
})

