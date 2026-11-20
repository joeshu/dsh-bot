// Keep the runtime source directly executable from this package while the iOS
// staging script copies the same protocol implementation beside the bundle.
export {
  FrameDecoder,
  IPC_PROTOCOL_VERSION,
  IPCRpcEndpoint,
  MAX_FRAME_BYTES,
  encodeFrame,
} from '../src/ipc-protocol.mjs'
