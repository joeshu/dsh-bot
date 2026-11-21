import { Worker } from 'node:worker_threads'
import { fileURLToPath } from 'node:url'
import {
  DUNDER_MEMBER,
  PORTABLE_RESERVED_WORDS,
  PtcRuntime,
  RESERVED_BINDING_GLOBALS,
  RESERVED_ERROR_MEMBERS,
} from '@deepseek-ai/dsh-ptc-runtime'
import { acquireIOSPythonWorker } from './python-worker-gate.mjs'

const PYTHON_RUNTIME_DIRECTORY = fileURLToPath(new URL('../../../python-runtime/', import.meta.url))
const MAX_PROGRAM_CHARACTERS = 16_000
const MAX_PROGRAM_BYTES = 64_000
const MAX_OUTPUT_CHARACTERS = 32_000
const MAX_BRIDGE_BYTES = 256_000
const MAX_BINDING_VALUE_BYTES = 96_000
const MAX_BINDING_CALLS = 60
const MAX_TIMEOUT_MS = 120_000
const DEFAULT_TIMEOUT_MS = 90_000
const MAX_JSON_DEPTH = 100

function isJsonValue(value, depth = 0, ancestors = new Set()) {
  if (depth > MAX_JSON_DEPTH) return false
  if (value === null || typeof value === 'string' || typeof value === 'boolean') return true
  if (typeof value === 'number') return Number.isFinite(value)
  if (typeof value !== 'object' || ancestors.has(value)) return false
  ancestors.add(value)
  let valid
  if (Array.isArray(value)) {
    valid = value.every((item) => isJsonValue(item, depth + 1, ancestors))
  } else {
    const prototype = Object.getPrototypeOf(value)
    valid = (prototype === Object.prototype || prototype === null)
      && Object.keys(value).every((key) => isJsonValue(value[key], depth + 1, ancestors))
  }
  ancestors.delete(value)
  return valid
}

function jsonByteLength(value) {
  try { return Buffer.byteLength(JSON.stringify(value), 'utf8') } catch { return Infinity }
}

function pythonBindings(bindings) {
  if (!Array.isArray(bindings) || bindings.length > 8) throw new TypeError('PTC bindings must be an array with at most eight namespaces.')
  const occupiedGlobals = new Set()
  return bindings.map((namespace) => {
    if (!namespace || typeof namespace.global !== 'string' || !/^[A-Za-z_][A-Za-z0-9_]*$/.test(namespace.global)
        || PORTABLE_RESERVED_WORDS.has(namespace.global) || RESERVED_BINDING_GLOBALS.has(namespace.global)
        || !namespace.functions || typeof namespace.functions !== 'object' || Array.isArray(namespace.functions)) {
      throw new TypeError('PTC binding namespace is invalid.')
    }
    if (occupiedGlobals.has(namespace.global)) throw new TypeError('PTC binding namespace globals must be unique.')
    occupiedGlobals.add(namespace.global)
    const names = Object.keys(namespace.functions)
    if (names.length > 512 || names.some((name) => typeof namespace.functions[name] !== 'function')) {
      throw new TypeError('PTC binding functions are invalid.')
    }
    if (namespace.errorClass !== undefined) {
      const error = namespace.errorClass
      if (!error || typeof error.name !== 'string' || !/^[A-Za-z_][A-Za-z0-9_]*$/.test(error.name)
          || PORTABLE_RESERVED_WORDS.has(error.name) || RESERVED_BINDING_GLOBALS.has(error.name)
          || typeof error.memberNameProperty !== 'string' || !error.memberNameProperty
          || RESERVED_ERROR_MEMBERS.has(error.memberNameProperty) || DUNDER_MEMBER.test(error.memberNameProperty)) {
        throw new TypeError('PTC binding error class is invalid.')
      }
      if (occupiedGlobals.has(error.name)) throw new TypeError('PTC binding error class names must be unique and separate from namespaces.')
      occupiedGlobals.add(error.name)
    }
    return {
      global: namespace.global,
      names,
      ...(namespace.errorClass ? { errorClass: { name: namespace.errorClass.name, memberNameProperty: namespace.errorClass.memberNameProperty } } : {}),
    }
  })
}

function failure(kind, message, logs = '') {
  return { logs: logs ? [logs.slice(0, MAX_OUTPUT_CHARACTERS)] : [], error: { kind, message: String(message).slice(0, 4_000) } }
}

/** Offline Python/NumPy PTC backend. It gives Python only the approved PTC binding bridge. */
export class IOSPythonPtcRuntime extends PtcRuntime {
  constructor(ctx) {
    super(ctx)
    this._jobs = new Set()
  }

  get language() { return 'python' }
  get isolation() { return 'worker-thread' }
  get programFormat() { return 'function-body' }
  get retainsState() { return false }
  get sandboxMode() { return undefined }
  get timeout() { return { defaultMs: DEFAULT_TIMEOUT_MS, maxMs: MAX_TIMEOUT_MS } }
  get executionInstructions() {
    return 'Write the body of an async Python function: top-level `await` and `return` are supported. `asyncio` is available; use `await asyncio.gather(...)` only for independent reads. Print or return a concise result. Each run starts a fresh offline Python 3.13.2 interpreter with NumPy 2.2.5. Python has no app-file, process, network, or MCP binding; call only the declared `tools[...]` bindings. Each call requires approval and its nested tools keep their own permissions. The Worker is limited to 120 seconds, 256 MiB WebAssembly memory, 16,000 source characters, 32,000 output characters, 60 nested tool calls, and 256 KiB total binding traffic. Interpreter variables are cleared after every run.'
  }

  resolve(request) {
    if (typeof request?.program !== 'string' || !request.program.trim()
        || request.program.length > MAX_PROGRAM_CHARACTERS
        || Buffer.byteLength(request.program, 'utf8') > MAX_PROGRAM_BYTES
        || request.program.includes('\u0000')) {
      throw new TypeError('PTC Python source must be non-empty, contain no NUL, and fit within 16,000 characters.')
    }
    if (request.sandboxPolicy !== undefined) throw new TypeError('This PTC runtime has no direct host-file sandbox or escalation policy.')
    if (request.cwd !== undefined && typeof request.cwd !== 'string') throw new TypeError('PTC working directory must be a string.')
    const requestedTimeout = request.timeoutMs
    if (requestedTimeout !== undefined && requestedTimeout !== null
        && (!Number.isFinite(requestedTimeout) || requestedTimeout <= 0)) {
      throw new TypeError('PTC timeoutMs must be a positive finite number.')
    }
    const timeoutMs = requestedTimeout === null ? MAX_TIMEOUT_MS
      : Math.min(requestedTimeout ?? DEFAULT_TIMEOUT_MS, MAX_TIMEOUT_MS)
    pythonBindings(request.bindings)
    return {
      program: request.program,
      bindings: request.bindings,
      cwd: request.cwd ?? '/',
      timeoutMs,
      ...(request.signal ? { signal: request.signal } : {}),
    }
  }

  async run(spec) {
    if (spec.signal?.aborted) return failure('abort', String(spec.signal.reason ?? 'PTC run cancelled.'))
    const releaseSlot = await acquireIOSPythonWorker({ signal: spec.signal, timeoutMs: 30_000 })
    if (!releaseSlot) {
      if (spec.signal?.aborted) return failure('abort', String(spec.signal.reason ?? 'PTC run cancelled.'))
      return failure('exception', 'The local Python runtime is busy with another isolated execution; retry after it finishes.')
    }

    let safeBindings
    try { safeBindings = pythonBindings(spec.bindings) } catch (error) {
      releaseSlot()
      return failure('protocol', error instanceof Error ? error.message : String(error))
    }

    const jobs = this._jobs ?? (this._jobs = new Set())

    return new Promise((resolve) => {
      let worker
      let settled = false
      let timer
      let bindingCalls = 0
      let bridgeBytes = 0
      let logs = ''
      let logsTruncated = false
      const job = { stop: (message) => settle(failure('abort', message, logs)) }
      const cleanup = async () => {
        clearTimeout(timer)
        spec.signal?.removeEventListener('abort', onAbort)
        try { await worker?.terminate() } catch { /* worker teardown must not mask its PTC outcome */ }
        jobs.delete(job)
        releaseSlot()
      }
      const settle = (result) => {
        if (settled) return
        settled = true
        void cleanup().then(() => resolve(result))
      }
      const onAbort = () => settle(failure('abort', String(spec.signal?.reason ?? 'PTC run cancelled.'), logs))

      try {
        worker = new Worker(new URL('./ios-ptc-python-worker.mjs', import.meta.url), {
          workerData: { program: spec.program, bindings: safeBindings, runtimeDirectory: PYTHON_RUNTIME_DIRECTORY },
          resourceLimits: { maxOldGenerationSizeMb: 128, maxYoungGenerationSizeMb: 32, stackSizeMb: 4 },
        })
        jobs.add(job)
        worker.on('message', (message) => {
          if (message?.type === 'stdout') {
            const text = String(message.text ?? '')
            const remaining = MAX_OUTPUT_CHARACTERS - logs.length
            if (remaining > 0) logs += text.slice(0, remaining)
            if (text.length > remaining) logsTruncated = true
            return
          }
          if (message?.type === 'completed') {
            const combined = logsTruncated || message.outputTruncated === true
              ? `${logs.slice(0, Math.max(0, MAX_OUTPUT_CHARACTERS - 28))}\n[输出已截断至 32,000 字符]`
              : logs
            if (message.error) settle(failure(message.error.kind === 'protocol' ? 'protocol' : 'exception', message.error.message, combined))
            else if (message.hasValue && !isJsonValue(message.value)) settle(failure('invalid-output', 'PTC Python returned a value outside the lossless JSON contract.', combined))
            else if (message.hasValue && jsonByteLength(message.value) > MAX_BINDING_VALUE_BYTES) settle(failure('output-limit', 'PTC Python return value exceeds the 96 KiB result limit.', combined))
            else settle({ logs: combined ? [combined] : [], ...(message.hasValue ? { value: message.value } : {}) })
            return
          }
          if (message?.type !== 'binding.call') return
          bindingCalls += 1
          if (bindingCalls > MAX_BINDING_CALLS) {
            worker.postMessage({ type: 'binding.error', id: message.id, message: 'run_code exceeded the iOS limit of 60 nested tool calls.' })
            return
          }
          void (async () => {
            try {
              const namespace = spec.bindings.find((candidate) => candidate.global === message.global)
              const binding = namespace && Object.hasOwn(namespace.functions, message.name) ? namespace.functions[message.name] : undefined
              if (typeof binding !== 'function') throw new Error('This tool binding is not available to the current PTC run.')
              if (typeof message.argsJSON !== 'string' || Buffer.byteLength(message.argsJSON, 'utf8') > MAX_BINDING_VALUE_BYTES) {
                throw new Error('PTC tool arguments must be JSON under the 96 KiB per-call limit.')
              }
              const args = JSON.parse(message.argsJSON)
              if (!isJsonValue(args)) throw new Error('PTC tool arguments must be lossless JSON.')
              const argumentBytes = Buffer.byteLength(message.argsJSON, 'utf8')
              bridgeBytes += argumentBytes
              if (!Number.isFinite(argumentBytes) || bridgeBytes > MAX_BRIDGE_BYTES) throw new Error('PTC tool calls exceeded the 256 KiB total binding traffic limit.')
              const value = await binding(args)
              if (!isJsonValue(value)) throw new Error('PTC tool returned a value outside the lossless JSON contract.')
              const valueJSON = JSON.stringify(value)
              const valueBytes = Buffer.byteLength(valueJSON, 'utf8')
              bridgeBytes += valueBytes
              if (!Number.isFinite(valueBytes) || valueBytes > MAX_BINDING_VALUE_BYTES || bridgeBytes > MAX_BRIDGE_BYTES) {
                throw new Error('PTC tool result exceeded the iOS per-call or total binding traffic limit. Use a narrower search or read smaller files.')
              }
              try { worker.postMessage({ type: 'binding.result', id: message.id, valueJSON }) } catch { /* run is already settling */ }
            } catch (error) {
              const text = error instanceof Error ? error.message : String(error)
              try { worker.postMessage({ type: 'binding.error', id: message.id, message: text.slice(0, 4_000) }) } catch { /* run is already settling */ }
            }
          })()
        })
        worker.once('error', (error) => settle(failure('worker-exit', error.message, logs)))
        worker.once('exit', (code) => {
          if (!settled) settle(failure('worker-exit', `Local PTC Python worker exited unexpectedly (${code}).`, logs))
        })
        timer = setTimeout(() => settle(failure('timeout', `PTC Python exceeded its ${spec.timeoutMs / 1_000}-second execution limit.`, logs)), spec.timeoutMs)
        timer.unref?.()
        spec.signal?.addEventListener('abort', onAbort, { once: true })
        if (spec.signal?.aborted) onAbort()
      } catch (error) {
        settle(failure('worker-exit', error instanceof Error ? error.message : String(error), logs))
      }
    })
  }

  async release(_owner) {
    // This provider is intentionally stateless; each run owns a fresh Worker.
  }

  async dispose() {
    const jobs = this._jobs ?? new Set()
    for (const job of [...jobs]) job.stop('PTC Python runtime stopped.')
    while (jobs.size) await new Promise((resolve) => setTimeout(resolve, 0))
  }
}

export const name = 'dsbot-ios-python-ptc-runtime'
export const inject = []

export function apply(ctx) {
  const runtime = new IOSPythonPtcRuntime(ctx)
  ctx.effect(() => async () => runtime.dispose(), 'dsbot-ios.python-ptc-runtime')
}

export default { name, inject, apply }
