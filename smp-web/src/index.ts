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
