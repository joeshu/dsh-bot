import { Worker } from 'node:worker_threads'
import { fileURLToPath } from 'node:url'
import { acquireIOSPythonWorker } from './python-worker-gate.mjs'

const MAX_CODE_CHARACTERS = 16_000
const MAX_CODE_BYTES = 64_000
const MAX_OUTPUT_CHARACTERS = 32_000
const EXECUTION_TIMEOUT_MS = 45_000
const PYTHON_RUNTIME_DIRECTORY = fileURLToPath(new URL('../../../python-runtime/', import.meta.url))
const executions = new Map()

function executionKey(botId, turnId) {
  return `${botId}\u0000${turnId}`
}

export async function executeIOSPython({ code, botId, turnId, signal }) {
  if (typeof code !== 'string' || !code.trim() || code.length > MAX_CODE_CHARACTERS
      || Buffer.byteLength(code, 'utf8') > MAX_CODE_BYTES || code.includes('\u0000')) {
    throw new TypeError('Python code must be non-empty, contain no NUL, and fit within 16,000 characters.')
  }
  if (typeof botId !== 'string' || !botId || typeof turnId !== 'string' || !turnId) {
    throw new TypeError('Python execution requires an active Bot turn.')
  }
  if (signal?.aborted) {
    throw new Error('Local Python execution was aborted.')
  }

  const key = executionKey(botId, turnId)
  const releaseWorkerSlot = await acquireIOSPythonWorker({ timeoutMs: 30_000 })
  if (!releaseWorkerSlot) throw new Error('The local Python runtime is busy with another isolated execution.')
  if (signal?.aborted) {
    releaseWorkerSlot()
    throw new Error('Local Python execution was aborted.')
  }
  if (executions.has(key)) {
    releaseWorkerSlot()
    throw new Error('This Bot turn already has an active Python execution.')
  }

  return new Promise((resolve, reject) => {
    let worker
    try {
      worker = new Worker(new URL('./python-worker.mjs', import.meta.url), {
        workerData: { code, runtimeDirectory: PYTHON_RUNTIME_DIRECTORY },
        resourceLimits: { maxOldGenerationSizeMb: 128, maxYoungGenerationSizeMb: 32, stackSizeMb: 4 },
      })
    } catch (error) {
      releaseWorkerSlot()
      reject(error)
      return
    }

    let settled = false
    let timeout
    const job = {
      stop(error) { settle(error) },
    }
    const onAbort = () => settle(new Error('Local Python execution was aborted.'))
    const settle = (error, output) => {
      if (settled) return
      settled = true
      clearTimeout(timeout)
      signal?.removeEventListener?.('abort', onAbort)
      void worker.terminate().catch(() => {}).then(() => {
        releaseWorkerSlot()
        if (executions.get(key) === job) executions.delete(key)
        if (error) reject(error)
        else resolve({ output: String(output ?? '') })
      })
    }

    executions.set(key, job)
    signal?.addEventListener?.('abort', onAbort, { once: true })
    worker.on('message', (message) => {
      if (message?.type !== 'completed') return
      settle(undefined, message.output)
    })
    worker.once('error', (error) => settle(error))
    worker.once('exit', (code) => {
      if (!settled) settle(new Error(`Local Python worker exited unexpectedly (${code}).`))
    })
    timeout = setTimeout(() => settle(new Error('Local Python exceeded its 45-second execution limit.')), EXECUTION_TIMEOUT_MS)
    timeout.unref?.()
  })
}

export function cancelIOSPythonExecution({ botId, turnId }) {
  const key = executionKey(String(botId ?? ''), String(turnId ?? ''))
  const job = executions.get(key)
  if (!job) return false
  job.stop(new Error('Local Python execution was cancelled.'))
  return true
}

export function cancelAllIOSPythonExecutions() {
  for (const job of executions.values()) job.stop(new Error('Local Python runtime stopped.'))
}
