// SMP protocol client for web/browser environments.
// Re-exports encoding primitives from xftp-web for convenience.
export {
  Decoder,
  encodeBytes, decodeBytes,
  encodeLarge, decodeLarge,
  encodeWord16, decodeWord16,
  encodeBool, decodeBool,
  encodeMaybe, decodeMaybe,
  encodeList, decodeList,
  concatBytes
} from "@simplex-chat/xftp-web/dist/protocol/encoding.js"

// ChatTransport interface and SMP transport types
export type {
  ChatTransport,
  SMPServerAddress,
  TransportState,
  TransportEventHandler,
  SMPTransportErrorCode,
} from "./types.js"
export {SMPTransportError} from "./types.js"

// WebSocket transport implementation
export {SMPWebSocketTransport} from "./transport.js"
export type {SMPTransportConfig} from "./transport.js"
