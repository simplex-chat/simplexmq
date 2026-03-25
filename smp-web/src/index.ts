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
  SMPClientState,
  SMPResponseHandler,
  SMPPushHandler,
  ConnectionEvent,
  ConnectionChangeHandler,
} from "./types.js"
export {SMPTransportError} from "./types.js"

// WebSocket transport implementation
export {SMPWebSocketTransport} from "./transport.js"
export type {SMPTransportConfig} from "./transport.js"

// SMP handshake encoding/decoding
export type {
  VersionRange,
  SMPServerHandshake,
  SMPClientHandshake,
  SignedKey,
} from "./handshake.js"
export {
  decodeSMPServerHandshake,
  encodeSMPClientHandshake,
  compatibleVRange,
  smpClientVersionRange,
  verifyServerIdentity,
  blockPad,
  blockUnpad,
  buildCommandBlock,
  parseResponseBlock,
} from "./handshake.js"

// SMP client with handshake and command dispatch
export type {SMPClient, SMPClientConfig} from "./client.js"
export {connectSMP, encodePING} from "./client.js"

// SMPClientAgent with connection pooling and reconnection
export type {SMPClientAgent, SMPAgentConfig} from "./agent.js"
export {newSMPAgent, calculateBackoff, serverKey} from "./agent.js"
