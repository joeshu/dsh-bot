// iOS Native Capability Bridge Clients exposed inside the BareKit worklet.
// Each shim delegates OS-level I/O (SQLite, URLSession HTTP+SSE, Keychain, Sandbox FS)
// over Bare.IPC JSON-RPC 2.0 to the SwiftUI native shell.

import { isAbsolute, normalize, relative, resolve } from 'node:path'
import { validateCredentialName } from './legacy-session-guard.mjs'

/**
 * Confines all file operations strictly inside the iOS App Sandbox `DSH_HOME` root.
 * Prevents path traversal outside `Documents/dsh-home/`.
 */
export class SandboxFSGuard {
  #root

  /** @param {string} dshHomeRoot */
  constructor(dshHomeRoot) {
    if (!dshHomeRoot || !isAbsolute(dshHomeRoot)) {
      throw new Error(`SandboxFSGuard requires an absolute root path, got: ${dshHomeRoot}`)
    }
    this.#root = normalize(dshHomeRoot)
  }

  get root() {
    return this.#root
  }

  /**
   * Resolve a relative or sandboxed path and assert it remains within `this.#root`.
   * @param {string} targetPath
   * @returns {string}
   */
  assertInside(targetPath) {
    const resolved = isAbsolute(targetPath)
      ? normalize(targetPath)
      : resolve(this.#root, targetPath)
    const rel = relative(this.#root, resolved)
    if (rel.startsWith('..') || isAbsolute(rel)) {
      const err = new Error(`Sandbox path escape blocked: ${targetPath}`)
      err.code = 'EACCES'
      throw err
    }
    return resolved
  }
}

/**
 * Bridges parameterized SQLite queries over Bare.IPC to iOS native `libsqlite3` (`SQLiteBridge.swift`).
 * Mirrors the essential API surface expected by `dsh-session-query-sqlite`.
 */
export class SQLiteBridgeClient {
  #rpc
  #dbPath

  /**
   * @param {import('../ipc-protocol.mjs').IPCRpcEndpoint} rpc
   * @param {string} dbPath
   */
  constructor(rpc, dbPath) {
    this.#rpc = rpc
    this.#dbPath = dbPath
  }

  async open() {
    return this.#rpc.request('bridge.sqlite.open', { path: this.#dbPath })
  }

  async exec(sql) {
    return this.#rpc.request('bridge.sqlite.exec', { path: this.#dbPath, sql })
  }

  async query(sql, params = []) {
    return this.#rpc.request('bridge.sqlite.query', { path: this.#dbPath, sql, params })
  }

  async run(sql, params = []) {
    return this.#rpc.request('bridge.sqlite.run', { path: this.#dbPath, sql, params })
  }

  async close() {
    return this.#rpc.request('bridge.sqlite.close', { path: this.#dbPath })
  }
}

/**
 * Bridges HTTP / SSE requests over Bare.IPC to iOS native `URLSession` (`NetworkBridge.swift`).
 * Avoids JIT/WASM dependencies of undici in iOS `--jitless` mode and respects iOS system proxies.
 */
export class URLSessionFetchShim {
  #rpc

  /** @param {import('../ipc-protocol.mjs').IPCRpcEndpoint} rpc */
  constructor(rpc) {
    this.#rpc = rpc
  }

  /**
   * Perform a standard HTTP request via native URLSession.
   * @param {string} url
   * @param {{ method?: string, headers?: Record<string, string>, body?: string, timeoutMs?: number }} [init]
   */
  async fetch(url, init = {}) {
    const res = await this.#rpc.request('bridge.net.request', {
      url: String(url),
      method: (init.method || 'GET').toUpperCase(),
      headers: init.headers || {},
      body: init.body ?? null,
    }, init.timeoutMs ?? 60_000)

    return {
      ok: res.status >= 200 && res.status < 300,
      status: res.status,
      headers: res.headers || {},
      text: async () => res.body ?? '',
      json: async () => JSON.parse(res.body ?? 'null'),
    }
  }

  /**
   * Open a server-sent events (SSE) stream over native URLSession with AbortSignal & idle timeout.
   * @param {string} url
   * @param {{ method?: string, headers?: Record<string, string>, body?: string, signal?: AbortSignal, idleTimeoutMs?: number }} init
   * @param {(chunk: string) => void} onChunk
   */
  async streamSSE(url, init = {}, onChunk) {
    const signal = init?.signal
    if (signal?.aborted) {
      const err = new Error('SSE stream aborted before start')
      err.name = 'AbortError'
      throw err
    }

    const idleTimeoutMs = init?.idleTimeoutMs ?? 45_000
    const { streamId } = await this.#rpc.request('bridge.net.sseStart', {
      url: String(url),
      method: (init?.method || 'POST').toUpperCase(),
      headers: init?.headers || {},
      body: init?.body ?? null,
    })

    return new Promise((resolve, reject) => {
      let settled = false
      let idleTimer

      const cleanup = () => {
        if (idleTimer) clearTimeout(idleTimer)
        unsubscribe()
        if (signal) signal.removeEventListener('abort', onAbort)
      }

      const fail = (err) => {
        if (settled) return
        settled = true
        cleanup()
        reject(err)
      }

      const succeed = (value) => {
        if (settled) return
        settled = true
        cleanup()
        resolve(value)
      }

      const resetIdleTimer = () => {
        if (idleTimer) clearTimeout(idleTimer)
        idleTimer = setTimeout(() => {
          void this.#rpc.request('bridge.net.sseCancel', { streamId }).catch(() => {})
          fail(new Error(`SSE stream idle timeout (${idleTimeoutMs}ms)`))
        }, idleTimeoutMs)
      }

      const onAbort = () => {
        void this.#rpc.request('bridge.net.sseCancel', { streamId }).catch(() => {})
        const err = new Error('SSE stream aborted')
        err.name = 'AbortError'
        fail(err)
      }

      if (signal) signal.addEventListener('abort', onAbort, { once: true })

      const unsubscribe = this.#rpc.onNotification((method, params) => {
        if (params?.streamId !== streamId) return
        if (method === 'bridge.net.sseChunk') {
          resetIdleTimer()
          try {
            onChunk(params.data)
          } catch (cbErr) {
            void this.#rpc.request('bridge.net.sseCancel', { streamId }).catch(() => {})
            fail(cbErr)
          }
        } else if (method === 'bridge.net.sseEnd') {
          succeed({ streamId, status: params.status ?? 200 })
        } else if (method === 'bridge.net.sseError') {
          fail(new Error(params.message || 'SSE stream error'))
        }
      })

      resetIdleTimer()
    })
  }
}

/**
 * Bridges encrypted credential storage to iOS Keychain + Face ID (`KeychainBridge.swift`).
 */
export class KeychainVaultClient {
  #rpc

  /** @param {import('../ipc-protocol.mjs').IPCRpcEndpoint} rpc */
  constructor(rpc) {
    this.#rpc = rpc
  }

  async getSecret(account, { requireBiometrics = false } = {}) {
    const safeAccount = validateCredentialName(account)
    const res = await this.#rpc.request('bridge.keychain.get', { account: safeAccount, requireBiometrics })
    return res?.value ?? null
  }

  async setSecret(account, value) {
    const safeAccount = validateCredentialName(account)
    await this.#rpc.request('bridge.keychain.set', { account: safeAccount, value })
  }

  async deleteSecret(account) {
    const safeAccount = validateCredentialName(account)
    await this.#rpc.request('bridge.keychain.delete', { account: safeAccount })
  }
}
