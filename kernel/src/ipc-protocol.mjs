// Canonical implementation lives in kernel/runtime/ipc-protocol.mjs so the iOS
// runtime bundle has zero dependency on kernel/src.
export {
  FrameDecoder,
  IPC_PROTOCOL_VERSION,
  IPCRpcEndpoint,
  MAX_FRAME_BYTES,
  encodeFrame,
} from '../runtime/ipc-protocol.mjs'
