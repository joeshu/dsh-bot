// Length-prefixed JSON-RPC 2.0 protocol over Bare.IPC duplex byte stream.
// Frame layout: [4-byte big-endian uint32 byteLength][UTF-8 JSON payload]

export const IPC_PROTOCOL_VERSION = '1.0.0'
export const MAX_FRAME_BYTES = 16 * 1024 * 1024 // 16 MB hard cap

/**
 * Encode a JSON-RPC message into a length-prefixed Uint8Array frame.
 * @param {object} message
 * @returns {Uint8Array}
 */
export function encodeFrame(message) {
  const json = JSON.stringify(message)
  const payload = Buffer.from(json, 'utf8')
  if (payload.byteLength > MAX_FRAME_BYTES) {
    throw new RangeError(`IPC frame exceeds max size (${payload.byteLength} > ${MAX_FRAME_BYTES})`)
  }
  const frame = Buffer.allocUnsafe(4 + payload.byteLength)
  frame.writeUInt32BE(payload.byteLength, 0)
  payload.copy(frame, 4)
  return frame
}

/**
 * Incremental streaming frame decoder resilient to arbitrary TCP/IPC chunk boundaries.
 */
export class FrameDecoder {
  #buffer = Buffer.alloc(0)

  /**
   * Push an incoming byte chunk and return zero or more decoded JSON objects.
   * @param {Uint8Array | Buffer} chunk
   * @returns {object[]}
   */
  push(chunk) {
    const incoming = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk)
    this.#buffer = this.#buffer.length === 0 ? incoming : Buffer.concat([this.#buffer, incoming])
    const messages = []

    while (this.#buffer.length >= 4) {
      const length = this.#buffer.readUInt32BE(0)
      if (length === 0 || length > MAX_FRAME_BYTES) {
        this.#buffer = Buffer.alloc(0)
        throw new RangeError(`Invalid IPC frame length: ${length}`)
      }
      if (this.#buffer.length < 4 + length) break
      const slice = this.#buffer.subarray(4, 4 + length)
      this.#buffer = this.#buffer.subarray(4 + length)
      messages.push(JSON.parse(slice.toString('utf8')))
    }

    return messages
  }

  get pendingBytes() {
    return this.#buffer.length
  }
}

/**
 * Bidirectional JSON-RPC 2.0 endpoint bound to any duplex transport
 * with `write(Uint8Array)` and `on('data', cb)` (such as `Bare.IPC`).
 */
export class IPCRpcEndpoint {
  #transport
  #decoder = new FrameDecoder()
  #nextId = 1
  #pending = new Map()
  #handlers = new Map()
  #notificationListeners = new Set()
  #closed = false

  /**
   * @param {{ write: (buf: Uint8Array) => void, on: (event: string, fn: Function) => void }} transport
   */
  constructor(transport) {
    this.#transport = transport
    transport.on('data', (chunk) => this.#onData(chunk))
    transport.on('close', () => this.close(new Error('IPC transport closed')))
  }

  /**
   * Register a handler for incoming JSON-RPC requests (`method`).
   * @param {string} method
   * @param {(params: any) => Promise<any> | any} handler
   */
  handle(method, handler) {
    this.#handlers.set(method, handler)
  }

  /**
   * Subscribe to incoming JSON-RPC notifications (messages without `id`).
   * @param {(method: string, params: any) => void} listener
   * @returns {() => void}
   */
  onNotification(listener) {
    this.#notificationListeners.add(listener)
    return () => this.#notificationListeners.delete(listener)
  }

  /**
   * Send a JSON-RPC request and await the remote result.
   * @param {string} method
   * @param {any} [params]
   * @param {number} [timeoutMs=30000]
   * @returns {Promise<any>}
   */
  request(method, params = {}, timeoutMs = 30_000, signal) {
    if (this.#closed) return Promise.reject(new Error('IPC endpoint is closed'))
    if (signal?.aborted) return Promise.reject(signal.reason ?? new Error('IPC request aborted'))
    const id = this.#nextId++
    return new Promise((resolve, reject) => {
      const abort = () => {
        const entry = this.#pending.get(id)
        if (!entry) return
        clearTimeout(entry.timer)
        signal?.removeEventListener('abort', abort)
        this.#pending.delete(id)
        reject(signal?.reason ?? new Error('IPC request aborted'))
      }
      const timer = setTimeout(() => {
        signal?.removeEventListener('abort', abort)
        this.#pending.delete(id)
        reject(new Error(`IPC request timeout (${timeoutMs}ms): ${method}`))
      }, timeoutMs)
      this.#pending.set(id, { resolve, reject, timer, signal, abort })
      signal?.addEventListener('abort', abort, { once: true })
      this.#send({ jsonrpc: '2.0', id, method, params })
    })
  }

  /**
   * Send a one-way JSON-RPC notification.
   * @param {string} method
   * @param {any} [params]
   */
  notify(method, params = {}) {
    if (this.#closed) return
    this.#send({ jsonrpc: '2.0', method, params })
  }

  close(reason = new Error('IPC endpoint closed')) {
    if (this.#closed) return
    this.#closed = true
    for (const { reject, timer, signal, abort } of this.#pending.values()) {
      clearTimeout(timer)
      signal?.removeEventListener('abort', abort)
      reject(reason)
    }
    this.#pending.clear()
  }

  #send(message) {
    this.#transport.write(encodeFrame(message))
  }

  #onData(chunk) {
    let frames
    try {
      frames = this.#decoder.push(chunk)
    } catch (error) {
      this.close(error)
      return
    }
    for (const msg of frames) {
      void this.#dispatch(msg)
    }
  }

  async #dispatch(msg) {
    // Response to an outbound request
    if (msg.id !== undefined && msg.method === undefined) {
      const entry = this.#pending.get(msg.id)
      if (!entry) return
      clearTimeout(entry.timer)
      entry.signal?.removeEventListener('abort', entry.abort)
      this.#pending.delete(msg.id)
      if (msg.error) {
        const err = new Error(msg.error.message || 'IPC remote error')
        err.code = msg.error.code
        err.data = msg.error.data
        entry.reject(err)
      } else {
        entry.resolve(msg.result)
      }
      return
    }

    // Inbound notification
    if (msg.id === undefined && typeof msg.method === 'string') {
      for (const listener of this.#notificationListeners) {
        try { listener(msg.method, msg.params) } catch {}
      }
      return
    }

    // Inbound request
    if (msg.id !== undefined && typeof msg.method === 'string') {
      const handler = this.#handlers.get(msg.method)
      if (!handler) {
        this.#send({
          jsonrpc: '2.0',
          id: msg.id,
          error: { code: -32601, message: `Method not found: ${msg.method}` },
        })
        return
      }
      try {
        const result = await handler(msg.params ?? {})
        this.#send({ jsonrpc: '2.0', id: msg.id, result: result ?? null })
      } catch (error) {
        this.#send({
          jsonrpc: '2.0',
          id: msg.id,
          error: {
            code: typeof error?.code === 'number' ? error.code : -32000,
            message: error instanceof Error ? error.message : String(error),
          },
        })
      }
    }
  }
}
